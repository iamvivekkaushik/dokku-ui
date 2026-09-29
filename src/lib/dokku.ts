import { useQuery, type UseQueryOptions } from '@tanstack/react-query';
import type { ExecResult } from '../../shared/types';
import { api } from './api';
import { useHost } from './host';
import { appHealth, parseLines, parseReport, parseReports, stripAnsi, words, type AppHealth, type Report } from './parse';

export const notSupported = (r: ExecResult) => /is not a dokku command|Invalid flag passed|unknown flag/i.test(r.stdout + r.stderr);
export const output = (r: ExecResult) => stripAnsi(r.stdout + (r.stderr ? `\n${r.stderr}` : '')).trim();

export class DokkuError extends Error {
  constructor(public result: ExecResult) { super(output(result) || `exit ${result.code}`); }
}

type Opts<T> = Omit<UseQueryOptions<ExecResult, Error, T>, 'queryKey' | 'queryFn' | 'select'> & { allowFail?: boolean };

/**
 * Runs one read-only dokku command. The raw result is what gets cached, and
 * `select` parses it per caller, so two views can read the same command with
 * different parsers without clobbering each other.
 */
export function useDokku<T = ExecResult>(args: string[] | null, select: (r: ExecResult) => T, opts: Opts<T> = {}) {
  const { host } = useHost();
  const { allowFail, ...rest } = opts;
  return useQuery<ExecResult, Error, T>({
    queryKey: ['dokku', host?.id, ...(args ?? []), allowFail ? '#lenient' : '#strict'],
    queryFn: async () => {
      const r = await api.exec(host!.id, args!, { timeoutMs: 60_000 });
      if (r.code !== 0 && !allowFail) throw new DokkuError(r);
      return r;
    },
    select,
    staleTime: 10_000,
    retry: 1,
    ...rest,
    enabled: !!host && !!args && (rest.enabled ?? true),
  });
}

/** Runs several read-only commands in one round trip. */
export function useDokkuBatch<T>(key: string, cmds: string[][] | null, select: (rs: ExecResult[]) => T, opts: Omit<UseQueryOptions<ExecResult[], Error, T>, 'queryKey' | 'queryFn' | 'select'> = {}) {
  const { host } = useHost();
  return useQuery<ExecResult[], Error, T>({
    queryKey: ['dokku', host?.id, key, ...(cmds ?? []).flat()],
    queryFn: () => api.batch(host!.id, cmds!),
    select,
    staleTime: 10_000,
    retry: 1,
    ...opts,
    enabled: !!host && !!cmds && (opts.enabled ?? true),
  });
}

export const useReport = (plugin: string, app: string | null, opts: Opts<Report> = {}) =>
  useDokku(app ? [`${plugin}:report`, app] : null, (r) => parseReport(r.stdout), opts);

export interface AppSummary {
  name: string;
  health: AppHealth;
  ps: Report;
  domains: string[];
}

export function useApps() {
  return useDokkuBatch('apps', [['--quiet', 'apps:list'], ['ps:report'], ['domains:report']], ([list, ps, dom]) => {
    if (list.code !== 0 && !/haven't deployed|no apps/i.test(list.stdout + list.stderr)) throw new DokkuError(list);
    const names = parseLines(list.stdout).filter((n) => /^[a-z0-9][a-z0-9-]*$/.test(n));
    const psR = parseReports(ps.stdout);
    const domR = parseReports(dom.stdout);
    const globalVhosts = words(Object.values(domR)[0]?.['domains global vhosts']);
    const apps: AppSummary[] = names.map((name) => ({
      name,
      ps: psR[name] ?? {},
      health: appHealth(psR[name]),
      domains: words(domR[name]?.['domains app vhosts']),
    }));
    return { apps, globalVhosts };
  }, { refetchInterval: 30_000 });
}

export const HEALTH_TONE = { running: 'ok', degraded: 'warn', stopped: 'mute', undeployed: 'mute' } as const;
