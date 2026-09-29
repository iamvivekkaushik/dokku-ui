// SSH connection pool. One ssh2 Client per host, multiplexing channels for
// each command. Host keys are pinned on first use and verified afterwards.
import { Client, type ClientChannel, type ConnectConfig } from 'ssh2';
import crypto from 'node:crypto';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import type { ConnStatus, ExecResult } from '../shared/types';
import { type HostRecord, pinHostKey } from './hosts';
import { redactArgs } from '../shared/redact';
import { isPrivileged, shq } from './quote';

const MAX_CHANNELS = 8;

export function fingerprint(key: Buffer): string {
  return 'SHA256:' + crypto.createHash('sha256').update(key).digest('base64').replace(/=+$/, '');
}

export class HostKeyMismatch extends Error {
  constructor(public expected: string, public actual: string) {
    super(`Host key mismatch: expected ${expected}, server presented ${actual}. The server may have been reinstalled, or the connection is being intercepted.`);
  }
}

async function connectConfig(h: HostRecord, onKey: (fp: string) => boolean): Promise<ConnectConfig> {
  const cfg: ConnectConfig = {
    host: h.host.replace(/^\[|\]$/g, ''),
    port: h.port,
    username: h.username,
    readyTimeout: 15_000,
    keepaliveInterval: 15_000,
    keepaliveCountMax: 3,
    hostVerifier: (key: Buffer) => onKey(fingerprint(key)),
  };
  if (h.auth === 'password') cfg.password = h.password;
  else if (h.auth === 'agent') cfg.agent = process.env.SSH_AUTH_SOCK;
  else {
    cfg.privateKey = h.privateKey ?? (h.keyPath ? await fs.readFile(h.keyPath.replace(/^~/, os.homedir())) : undefined);
    cfg.passphrase = h.passphrase;
    if (!cfg.privateKey) throw new Error('No private key configured for this host.');
  }
  return cfg;
}

/** Opens a fresh connection. Resolves with the client and the presented host key. */
export function openClient(h: HostRecord): Promise<{ client: Client; hostKey: string }> {
  return new Promise((resolve, reject) => {
    const client = new Client();
    let hostKey = '';
    let mismatch: HostKeyMismatch | null = null;
    const onKey = (fp: string) => {
      hostKey = fp;
      if (h.hostKey && h.hostKey !== fp) { mismatch = new HostKeyMismatch(h.hostKey, fp); return false; }
      return true;
    };
    client.once('ready', () => resolve({ client, hostKey }));
    client.once('error', (err) => reject(mismatch ?? err));
    connectConfig(h, onKey).then((cfg) => client.connect(cfg), reject);
  });
}

class Semaphore {
  private queue: (() => void)[] = [];
  constructor(private free: number) {}
  async acquire(): Promise<() => void> {
    if (this.free > 0) this.free--;
    else await new Promise<void>((r) => this.queue.push(r));
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const next = this.queue.shift();
      if (next) next(); else this.free++;
    };
  }
}

interface PoolEntry {
  client: Client | null;
  connecting: Promise<Client> | null;
  status: ConnStatus;
  sem: Semaphore;
  record: HostRecord;
}

// Short commands and long-lived streams (log tails, terminals, deploys) use
// separate connections, so a page full of open streams can never starve the
// queries that render the UI.
type Lane = 'cmd' | 'stream';
const pool = new Map<string, PoolEntry>();

function entry(h: HostRecord, lane: Lane = 'cmd'): PoolEntry {
  const key = `${h.id}:${lane}`;
  let e = pool.get(key);
  if (!e) {
    e = { client: null, connecting: null, status: { state: 'idle' }, sem: new Semaphore(MAX_CHANNELS), record: h };
    pool.set(key, e);
  }
  e.record = h;
  return e;
}

export function dropConnection(id: string): void {
  for (const lane of ['cmd', 'stream'] as const) {
    const e = pool.get(`${id}:${lane}`);
    if (e?.client) e.client.end();
    pool.delete(`${id}:${lane}`);
  }
}

async function getClient(h: HostRecord, lane: Lane): Promise<Client> {
  const e = entry(h, lane);
  if (e.client) return e.client;
  if (e.connecting) return e.connecting;
  e.status = { ...e.status, state: 'connecting' };
  e.connecting = openClient(h).then(
    ({ client, hostKey }) => {
      if (!h.hostKey) pinHostKey(h.id, hostKey).catch(() => {});
      e.client = client;
      e.connecting = null;
      e.status = { state: 'connected', since: new Date().toISOString() };
      const lost = (err?: Error) => {
        if (e.client !== client) return;
        e.client = null;
        e.status = { state: 'disconnected', error: err?.message ?? 'connection closed', since: new Date().toISOString() };
      };
      client.on('error', lost);
      client.on('close', () => lost());
      return client;
    },
    (err: Error) => {
      e.connecting = null;
      e.status = { state: 'disconnected', error: err.message, since: new Date().toISOString() };
      throw err;
    },
  );
  return e.connecting;
}

export function connStatus(id: string): ConnStatus {
  return pool.get(`${id}:cmd`)?.status ?? { state: 'idle' };
}

/** Builds the remote command line for a dokku invocation on this host. */
export function dokkuCommand(h: HostRecord, args: string[]): string {
  const quoted = args.map(shq).join(' ');
  if (h.username === 'dokku') return quoted; // sshcommand forwards SSH_ORIGINAL_COMMAND to dokku
  const sudo = h.sudo || (isPrivileged(args) && h.username !== 'root');
  // Run from / so the dokku user, which cannot read the login user's home, does not print cwd warnings.
  return `cd / && ${sudo ? 'sudo -n ' : ''}dokku ${quoted}`;
}

/** Human-readable equivalent shown in the UI. */
export function displayCommand(_h: HostRecord, args: string[]): string {
  return `dokku ${redactArgs(args).map(shq).join(' ')}`;
}

async function openChannel(h: HostRecord, cmd: string, lane: Lane, pty?: { cols: number; rows: number }): Promise<{ ch: ClientChannel; release: () => void }> {
  const e = entry(h, lane);
  const release = await e.sem.acquire();
  try {
    let client = await getClient(h, lane);
    const exec = (c: Client) => new Promise<ClientChannel>((resolve, reject) => {
      const opts = pty ? { pty: { term: 'xterm-256color', cols: pty.cols, rows: pty.rows } } : {};
      c.exec(cmd, opts, (err, ch) => (err ? reject(err) : resolve(ch)));
    });
    let ch: ClientChannel;
    try {
      ch = await exec(client);
    } catch (err) {
      // Stale connection: reconnect once.
      if (e.client === client) { client.end(); e.client = null; }
      client = await getClient(h, lane);
      ch = await exec(client);
    }
    ch.once('close', release);
    return { ch, release };
  } catch (err) {
    release();
    throw err;
  }
}

export async function execRaw(h: HostRecord, cmd: string, opts: { stdin?: string | Buffer; timeoutMs?: number; display?: string } = {}): Promise<ExecResult> {
  const started = Date.now();
  const { ch, release } = await openChannel(h, cmd, 'cmd');
  return new Promise((resolve) => {
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let code: number | null = null;
    let signal: string | null = null;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      release();
      resolve({ code, signal, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8'), durationMs: Date.now() - started, command: opts.display ?? cmd });
    };
    // sshd only confirms the close once the remote process exits, so a timeout must not wait for it.
    const timer = opts.timeoutMs ? setTimeout(() => {
      signal = 'TIMEOUT';
      err.push(Buffer.from(`\nTimed out after ${Math.round(opts.timeoutMs! / 1000)}s.\n`));
      try { ch.close(); } catch { /* already closed */ }
      finish();
    }, opts.timeoutMs) : null;
    ch.on('data', (d: Buffer) => out.push(d));
    ch.stderr.on('data', (d: Buffer) => err.push(d));
    ch.on('exit', (c: number | null, s?: string) => { code = c; if (s) signal = s; });
    ch.on('close', finish);
    if (opts.stdin !== undefined) ch.end(opts.stdin);
    else ch.end();
  });
}

export async function execDokku(h: HostRecord, args: string[], opts: { stdin?: string | Buffer; timeoutMs?: number } = {}): Promise<ExecResult> {
  return execRaw(h, dokkuCommand(h, args), { ...opts, display: displayCommand(h, args) });
}

export interface StreamHandle {
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void;
}

export async function stream(
  h: HostRecord,
  cmd: string,
  opts: { pty?: { cols: number; rows: number }; stdin?: string },
  on: { data: (stream: 'stdout' | 'stderr', chunk: string) => void; exit: (code: number | null, signal: string | null, durationMs: number) => void },
): Promise<StreamHandle> {
  const started = Date.now();
  const { ch, release } = await openChannel(h, cmd, 'stream', opts.pty);
  let code: number | null = null;
  let signal: string | null = null;
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    release();
    on.exit(code, signal, Date.now() - started);
  };
  ch.setEncoding('utf8');
  ch.stderr.setEncoding('utf8');
  ch.on('data', (d: string) => { if (!done) on.data('stdout', d); });
  ch.stderr.on('data', (d: string) => { if (!done) on.data('stderr', d); });
  ch.on('exit', (c: number | null, s?: string) => { code = c; if (s) signal = s; });
  ch.on('close', finish);
  if (opts.stdin !== undefined) ch.end(opts.stdin);
  else if (!opts.pty) ch.end();
  return {
    write: (data) => { if (!done && ch.writable) ch.write(data); },
    resize: (cols, rows) => { if (!done) ch.setWindow(rows, cols, 0, 0); },
    kill: () => {
      if (done) return;
      signal = signal ?? 'KILLED';
      // With a PTY, Ctrl-C reaches the foreground process and closing the
      // channel then hangs up the session. Without one, sshd keeps the
      // process until it next writes, so we stop waiting for it right away.
      if (opts.pty && ch.writable) ch.write('\x03');
      try { ch.signal('INT'); } catch { /* not supported by every server */ }
      setTimeout(() => {
        try { ch.close(); } catch { /* already closed */ }
        finish();
      }, opts.pty ? 150 : 0);
    },
  };
}

/** Round-trip probe for the connection indicator. */
export async function ping(h: HostRecord): Promise<ConnStatus> {
  try {
    const cmd = h.username === 'dokku' ? 'version' : 'true';
    const r = await execRaw(h, cmd, { timeoutMs: 10_000 });
    const st = entry(h, 'cmd').status;
    st.rttMs = r.durationMs;
    return st;
  } catch (err) {
    return { state: 'disconnected', error: (err as Error).message };
  }
}
