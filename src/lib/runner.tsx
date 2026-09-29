import { useQueryClient } from '@tanstack/react-query';
import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react';
import type { ExecResult } from '../../shared/types';
import { redactArgs } from '../../shared/redact';
import { api, runStreamed } from './api';
import { useHost } from './host';

export interface Job {
  id: number;
  title: string;
  command: string;
  args: string[];
  output: { text: string; stream: 'stdout' | 'stderr' }[];
  status: 'running' | 'ok' | 'fail';
  code: number | null;
  durationMs: number;
  startedAt: number;
  hostLabel: string;
  kill?: () => void;
  retry: () => void;
}

export interface ConfirmSpec {
  title: string;
  body?: ReactNode;
  confirmLabel?: string;
  danger?: boolean;
  typeToConfirm?: string;
}

export interface RunOptions {
  title?: string;
  stdin?: string;
  /** Files sent as a tar archive on stdin (e.g. certs:add). */
  stdinFiles?: Record<string, string>;
  confirm?: ConfirmSpec;
  /** Don't open the error dialog on failure. */
  quietFail?: boolean;
  timeoutMs?: number;
}

interface RunnerCtx {
  jobs: Job[];
  run: (args: string[], opts?: RunOptions) => Promise<ExecResult | null>;
  confirm: (spec: ConfirmSpec) => Promise<boolean>;
  dismiss: (id: number) => void;
  failed: Job | null;
  setFailed: (j: Job | null) => void;
  pendingConfirm: (ConfirmSpec & { resolve: (v: boolean) => void }) | null;
}

const Ctx = createContext<RunnerCtx | null>(null);
let jobSeq = 0;

export function RunnerProvider({ children }: { children: ReactNode }) {
  const { host } = useHost();
  const qc = useQueryClient();
  const [jobs, setJobs] = useState<Job[]>([]);
  const [failed, setFailed] = useState<Job | null>(null);
  const [pendingConfirm, setPendingConfirm] = useState<RunnerCtx['pendingConfirm']>(null);
  const hostRef = useRef(host);
  hostRef.current = host;

  const update = useCallback((id: number, patch: Partial<Job> | ((j: Job) => Partial<Job>)) => {
    setJobs((js) => js.map((j) => (j.id === id ? { ...j, ...(typeof patch === 'function' ? patch(j) : patch) } : j)));
  }, []);

  const dismiss = useCallback((id: number) => setJobs((js) => js.filter((j) => j.id !== id)), []);

  const confirm = useCallback((spec: ConfirmSpec) => new Promise<boolean>((resolve) => {
    setPendingConfirm({ ...spec, resolve: (v) => { setPendingConfirm(null); resolve(v); } });
  }), []);

  const run = useCallback(async (args: string[], opts: RunOptions = {}): Promise<ExecResult | null> => {
    const h = hostRef.current;
    if (!h) return null;
    if (opts.confirm && !(await confirm(opts.confirm))) return null;
    const id = ++jobSeq;
    const display = `dokku ${redactArgs(args).join(' ')}`;
    const job: Job = {
      id, title: opts.title ?? args.find((a) => !a.startsWith('--')) ?? 'command', command: display, args, output: [], status: 'running', code: null, durationMs: 0,
      startedAt: Date.now(), hostLabel: `${h.username}@${h.host}`,
      retry: () => { dismiss(id); setFailed(null); void run(args, { ...opts, confirm: undefined }); },
    };
    setJobs((js) => [...js.slice(-5), job]);

    const output: Job['output'] = [];
    let result: ExecResult;
    if (opts.stdinFiles) {
      try {
        result = await api.exec(h.id, args, { stdinFiles: opts.stdinFiles, timeoutMs: opts.timeoutMs });
      } catch (err) {
        result = { code: -1, stdout: '', stderr: (err as Error).message, durationMs: 0, command: display };
      }
      output.push({ text: result.stdout, stream: 'stdout' }, { text: result.stderr, stream: 'stderr' });
      update(id, { output: [...output] });
    } else {
      const { handle, done } = runStreamed({ hostId: h.id, kind: 'dokku', args, stdin: opts.stdin }, (text, stream) => {
        output.push({ text, stream });
        update(id, { output: [...output] });
      });
      update(id, { kill: handle.kill });
      result = await done;
    }
    const ok = result.code === 0;
    update(id, { status: ok ? 'ok' : 'fail', code: result.code, durationMs: result.durationMs, command: result.command || display, kill: undefined });
    qc.invalidateQueries({ queryKey: ['dokku', h.id] });
    qc.invalidateQueries({ queryKey: ['activity', h.id] });
    if (ok) setTimeout(() => setJobs((js) => js.filter((j) => j.id !== id || j.status !== 'ok')), 6000);
    else if (!opts.quietFail) {
      if (!output.length && result.stderr) output.push({ text: result.stderr, stream: 'stderr' });
      setFailed({ ...job, output, status: 'fail', code: result.code, durationMs: result.durationMs, command: result.command || display });
    }
    return result;
  }, [confirm, dismiss, qc, update]);

  return <Ctx.Provider value={{ jobs, run, confirm, dismiss, failed, setFailed, pendingConfirm }}>{children}</Ctx.Provider>;
}

export function useRunner(): RunnerCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error('useRunner outside RunnerProvider');
  return c;
}

/** Tracks a single in-flight command so buttons can show a spinner. */
export function useAction() {
  const { run } = useRunner();
  const [busy, setBusy] = useState<string | null>(null);
  const act = useCallback(async (key: string, args: string[], opts?: RunOptions) => {
    setBusy(key);
    try { return await run(args, opts); } finally { setBusy(null); }
  }, [run]);
  /** Marks `key` busy while an arbitrary async sequence (several commands) runs. */
  const wrap = useCallback(async <T,>(key: string, fn: () => Promise<T>) => {
    setBusy(key);
    try { return await fn(); } finally { setBusy(null); }
  }, []);
  return { busy, act, wrap, run };
}

export function remediation(out: string): string {
  if (/could not resolve host|temporary failure in name resolution|network is unreachable/i.test(out))
    return 'The server could not reach the internet (DNS or network failure). Check its resolver and outbound firewall, then retry.';
  if (/must be run as root|requires root|sudo: a password is required|a terminal is required|docker\.sock.*permission denied/i.test(out))
    return 'This command needs root. Edit the connection to use root (or a sudo user with "Use sudo" on and passwordless sudo), then retry.';
  if (/deploy lock|is locked|currently being deployed/i.test(out)) return 'A deploy lock is held. Unlock deploys in the app Settings tab, or wait for the running deploy to finish.';
  if (/is not a dokku command/i.test(out)) return "This Dokku version doesn't have that command. Upgrade Dokku from Server & SSH, or install the plugin that provides it.";
  if (/not deployed/i.test(out)) return 'The app has not been deployed yet. Push code, sync from a repository, or deploy an image first.';
  if (/does not exist|not found/i.test(out)) return 'The resource does not exist (it may have been removed elsewhere). Refresh the view and try again.';
  if (/pull access denied|unauthorized|no basic auth credentials/i.test(out)) return 'The image registry rejected the request. Log in with registry:login on the Server page.';
  if (/timed? ?out|TIMEOUT|ETIMEDOUT/i.test(out)) return 'The command timed out. The host may be busy or the SSH connection dropped; retry once the connection indicator is green.';
  if (/build failed|failure during|failed to solve/i.test(out)) return 'The build failed. Read the output above; crashed deploy containers are also available under Logs → logs:failed.';
  if (/still linked|is linked/i.test(out)) return 'Unlink the service from every app before destroying it.';
  return 'Dokku returned a non-zero exit status. The full output is above.';
}
