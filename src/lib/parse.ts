// Parsers for Dokku's human-readable CLI output.

// eslint-disable-next-line no-control-regex
// Also drops carriage returns: PTY streams end lines with CRLF.
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r/g;
export const stripAnsi = (s: string) => s.replace(ANSI, '');

export type Report = Record<string, string>;

/**
 * Parses `=====> <name> <plugin> information` sections with `Key:   value` rows.
 * Keys are lower-cased. Returns a map of section name → key/value map.
 */
export function parseReports(text: string): Record<string, Report> {
  const out: Record<string, Report> = {};
  let cur: Report | null = null;
  for (const raw of stripAnsi(text).split('\n')) {
    const h = /^=====>\s+(\S+)\s/.exec(raw);
    if (h) { cur = out[h[1]] ??= {}; continue; }
    if (!cur) continue;
    const m = /^\s+([^:]+?):\s*(.*?)\s*$/.exec(raw);
    if (m) cur[m[1].trim().toLowerCase()] = m[2];
  }
  return out;
}

export function parseReport(text: string): Report {
  return Object.values(parseReports(text))[0] ?? {};
}

export const bool = (v: string | undefined) => v === 'true';

/** Plain list output: drops `=====>`/`----->` headers and warnings. */
export function parseLines(text: string): string[] {
  return stripAnsi(text).split('\n').map((l) => l.trim()).filter((l) => l && !/^(=====>|----->|!\s)/.test(l));
}

export const words = (v: string | undefined) => (v ?? '').split(/\s+/).filter(Boolean);

/** `ps:scale <app>` without args. */
export function parseScale(text: string): Record<string, number> {
  const out: Record<string, number> = {};
  for (const l of stripAnsi(text).split('\n')) {
    const m = /^\s*([\w-]+):\s+(\d+)\s*$/.exec(l);
    if (m && m[1] !== 'proctype') out[m[1]] = Number(m[2]);
  }
  return out;
}

export interface ProcStatus { type: string; index: number; state: string; cid: string }

/** "Status web 1: running (CID: 03ea8977f37)" rows from ps:report. */
export function procStatuses(r: Report): ProcStatus[] {
  const out: ProcStatus[] = [];
  for (const [k, v] of Object.entries(r)) {
    const m = /^status (\S+) (\d+)$/.exec(k);
    if (!m) continue;
    const s = /^(\S+)(?:\s+\(CID:\s*(\w+)\))?/.exec(v);
    out.push({ type: m[1], index: Number(m[2]), state: s?.[1] ?? v, cid: s?.[2] ?? '' });
  }
  return out.sort((a, b) => a.type.localeCompare(b.type) || a.index - b.index);
}

export type AppHealth = 'running' | 'degraded' | 'stopped' | 'undeployed';
export function appHealth(ps: Report | undefined): AppHealth {
  if (!ps) return 'stopped';
  if (ps.deployed !== 'true') return 'undeployed';
  const procs = procStatuses(ps);
  const up = procs.filter((p) => p.state === 'running').length;
  if (procs.length === 0) return ps.running === 'true' ? 'running' : 'stopped';
  if (up === 0) return 'stopped';
  return up < procs.length ? 'degraded' : 'running';
}

/** `docker-options:report` joins all options with spaces; split on option boundaries. */
export function splitDockerOptions(v: string | undefined): string[] {
  const s = (v ?? '').trim();
  if (!s) return [];
  return s.split(/\s+(?=-{1,2}[A-Za-z])/).map((x) => x.trim()).filter(Boolean);
}

export interface Mount { host: string; container: string; options: string }
export function parseStorage(text: string): Mount[] {
  const t = text.trim();
  if (t.startsWith('[')) {
    try {
      return (JSON.parse(t) as { host_path: string; container_path: string; volume_options?: string }[])
        .map((m) => ({ host: m.host_path, container: m.container_path, options: m.volume_options ?? '' }));
    } catch { /* fall through */ }
  }
  return parseLines(text).filter((l) => l.includes(':')).map((l) => {
    const [host, container, options = ''] = l.split(':');
    return { host, container, options };
  });
}

export interface SshKey { fingerprint: string; name: string; allowed: string; publicKey?: string }
export function parseSshKeys(text: string): SshKey[] {
  const t = text.trim();
  if (t.startsWith('[')) {
    try {
      return (JSON.parse(t) as Record<string, string>[]).map((k) => ({ fingerprint: k.fingerprint, name: k.name, allowed: k.SSHCOMMAND_ALLOWED_KEYS ?? '', publicKey: k['public-key'] }));
    } catch { /* fall through */ }
  }
  return parseLines(text).map((l) => {
    const fp = l.split(/\s+/)[0];
    return { fingerprint: fp, name: /NAME="([^"]*)"/.exec(l)?.[1] ?? '', allowed: /SSHCOMMAND_ALLOWED_KEYS="([^"]*)"/.exec(l)?.[1] ?? '' };
  }).filter((k) => k.fingerprint.startsWith('SHA256:') || k.fingerprint.includes(':'));
}

export interface PluginInfo { name: string; version: string; enabled: boolean; description: string; core: boolean }
export function parsePlugins(text: string): PluginInfo[] {
  return stripAnsi(text).split('\n').map((l) => /^\s*(\S+)\s+(\S+)\s+(enabled|disabled)\s+(.*)$/.exec(l)).filter(Boolean).map((m) => ({
    name: m![1], version: m![2], enabled: m![3] === 'enabled', description: m![4].trim(), core: /^dokku core /.test(m![4].trim()),
  }));
}

export interface CronTask { id: string; schedule: string; command: string }
export function parseCron(text: string): CronTask[] {
  const t = text.trim();
  if (t.startsWith('[')) {
    try {
      return (JSON.parse(t) as Record<string, string>[]).map((c) => ({ id: c.id ?? c.ID, schedule: c.schedule ?? c.Schedule, command: c.command ?? c.Command }));
    } catch { /* fall through */ }
  }
  const out: CronTask[] = [];
  for (const l of parseLines(text)) {
    if (/^ID\s+Schedule/i.test(l)) continue;
    const m = /^(\S+)\s+((?:\S+\s+){4}\S+|@\S+)\s+(.*)$/.exec(l);
    if (m) out.push({ id: m[1], schedule: m[2], command: m[3] });
  }
  return out;
}

export interface LogLine { ts: string; proc: string; msg: string; level: 'info' | 'warn' | 'error' }
const LOG_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s+(?:[\w.-]+)\[([\w.-]+)\]:\s?(.*)$/;
export function levelOf(msg: string): LogLine['level'] {
  if (/\b(error|err|fatal|panic|exception|failed|failure)\b|^\s*!/i.test(msg)) return 'error';
  if (/\b(warn|warning|deprecated|retry|retrying)\b|\s(4\d\d)\s/i.test(msg)) return 'warn';
  return 'info';
}
export function parseLogLine(line: string): LogLine {
  const clean = stripAnsi(line);
  const m = LOG_RE.exec(clean);
  if (m) {
    const d = new Date(m[1]);
    return { ts: isNaN(d.getTime()) ? m[1].slice(11, 19) : d.toTimeString().slice(0, 8), proc: m[2], msg: m[3], level: levelOf(m[3]) };
  }
  return { ts: '', proc: '', msg: clean, level: levelOf(clean) };
}

export interface EventLine { ts: string; date: Date | null; kind: string; text: string; user: string }
export function parseEvent(line: string): EventLine | null {
  const l = stripAnsi(line).trim();
  if (!l) return null;
  // 2026-09-29T11:05:45.678873+00:00 host dokku-event[25606]: INVOKED: proxy-type( demo-app ) NAME=tester FINGERPRINT=...
  const m = /^(\S+(?:\s+\d+\s+[\d:]+)?)\s+\S+\s+dokku(?:-event)?\[\d+\]:\s*(?:INVOKED:\s*)?([\w:-]+)\(\s*(.*?)\s*\)\s*(.*)$/.exec(l);
  if (!m) return { ts: '', date: null, kind: 'event', text: l, user: '' };
  const d = new Date(m[1]);
  return { ts: isNaN(d.getTime()) ? m[1] : d.toTimeString().slice(0, 8), date: isNaN(d.getTime()) ? null : d, kind: m[2], text: m[3], user: /NAME=(\S+)/.exec(m[4])?.[1] ?? '' };
}

/**
 * Dokku logs every plugin trigger, including the read-only lookups this
 * console makes. These are the ones that record an actual change.
 */
const KEY_EVENT = /^(receive-app|receive-branch|deploy-source-set|(pre|post)-(deploy|delete|create|stop|start|restart|build\w*|release\w*|extract)|post-(config-update|domains-update|certs-update|certs-remove|app-clone\w*|app-rename\w*|proxy-ports-update|registry-login|container-create)|storage-(mount|unmount)\w*|scheduler-(deploy|stop|run)|network-(create|destroy)\w*)$/;
export const isKeyEvent = (kind: string) => KEY_EVENT.test(kind);

/** Datastore `<svc>:info` output. */
export function parseServiceInfo(text: string): Report {
  return parseReport(text);
}

/** `<svc>:list` table: NAME VERSION STATUS EXPOSED PORTS LINKS. Used only for names. */
export function parseServiceNames(text: string): string[] {
  return parseLines(text).filter((l) => !/^NAME\s+VERSION/i.test(l)).map((l) => l.split(/\s+/)[0]).filter((n) => /^[\w.-]+$/.test(n));
}

export function parseResource(r: Report): Record<string, Record<string, string>> {
  // keys like "_default_ limit cpu", "web reserve memory"
  const out: Record<string, Record<string, string>> = {};
  for (const [k, v] of Object.entries(r)) {
    const m = /^(\S+) (limit|reserve) (\S+)$/.exec(k);
    if (!m) continue;
    (out[m[1]] ??= {})[`${m[2]}-${m[3]}`] = v;
  }
  return out;
}

export function parseEnvFile(text: string): [string, string][] {
  const out: [string, string][] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/^\s*export\s+/, '');
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/.exec(line);
    if (!m) continue;
    let v = m[2];
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      const dq = v.startsWith('"');
      v = v.slice(1, -1);
      if (dq) v = v.replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    } else {
      v = v.replace(/\s+#.*$/, '');
    }
    out.push([m[1], v]);
  }
  return out;
}

export const b64 = (s: string) => btoa(String.fromCharCode(...new TextEncoder().encode(s)));

export function isSecretKey(k: string): boolean {
  return /(SECRET|TOKEN|PASSWORD|PASSWD|PASS\b|_KEY|KEY_|PRIVATE|CREDENTIAL|_URL$|DSN|AUTH|SALT|COOKIE)/i.test(k) && !/^(DOKKU_PROXY_PORT|PORT)$/.test(k);
}

export function cronHuman(expr: string): string {
  const p = expr.trim().split(/\s+/);
  if (expr.startsWith('@')) return expr.slice(1);
  if (p.length !== 5) return expr;
  const [m, h, dom, mon, dow] = p;
  const every = /^\*\/(\d+)$/;
  if (every.test(m) && h === '*' && dom === '*' && mon === '*' && dow === '*') return `every ${every.exec(m)![1]} min`;
  if (m === '0' && every.test(h) && dom === '*' && mon === '*' && dow === '*') return `every ${every.exec(h)![1]} h`;
  if (/^\d+$/.test(m) && h === '*' && dom === '*') return `hourly at :${m.padStart(2, '0')}`;
  if (/^\d+$/.test(m) && /^\d+$/.test(h) && dom === '*' && mon === '*') {
    const t = `${h.padStart(2, '0')}:${m.padStart(2, '0')}`;
    if (dow === '*') return `daily at ${t}`;
    return `weekly (${dow}) at ${t}`;
  }
  return expr;
}
