import { useState } from 'react';
import { Badge, Btn, Card, CardHead, Cmd, Dot, Empty, Input, Page, PageHead, Skeleton, TONE } from '../components/ui';
import { notSupported, useApps, useDokku, useDokkuBatch } from '../lib/dokku';
import { useCurrentHost } from '../lib/host';
import { isKeyEvent, parseEvent, parseReports, procStatuses, stripAnsi } from '../lib/parse';
import { navigate, useTitle } from '../lib/router';
import { useAction } from '../lib/runner';
import { useLogStream } from './app/Logs';

export function Monitoring() {
  const host = useCurrentHost();
  useTitle('Logs & monitoring');
  const apps = useApps();
  const { busy, act } = useAction();
  const [q, setQ] = useState('');
  const [all, setAll] = useState(false);
  const eventsOn = useDokku(['events:list'], (r) => !/logger disabled/i.test(r.stdout + r.stderr), { allowFail: true });
  const { lines, state, error } = useLogStream(host.id, eventsOn.data ? ['events', '-t'] : null, (l) => { const e = parseEvent(l); return e ? { ts: e.ts, proc: e.kind, msg: `${e.text}${e.user ? `  by ${e.user}` : ''}`, level: /fail|error/i.test(e.kind) ? 'error' : 'info' } : null; }, [eventsOn.data]);
  const relevant = all ? lines : lines.filter((l) => isKeyEvent(l.proc));
  const shown = (q ? relevant.filter((l) => `${l.proc} ${l.msg}`.toLowerCase().includes(q.toLowerCase())) : relevant).slice(-300).reverse();

  const failed = useDokku(['logs:failed', '--all'], (r) => {
    if (notSupported(r)) return null;
    const out: { app: string; lines: string[] }[] = [];
    let cur: { app: string; lines: string[] } | null = null;
    for (const raw of stripAnsi(r.stdout + r.stderr).split('\n')) {
      const h = /^=====>\s+(\S+) failed deploy logs/.exec(raw);
      if (h) { cur = { app: h[1], lines: [] }; out.push(cur); continue; }
      if (/^----->/.test(raw) || !raw.trim()) continue;
      if (cur && !/No failed containers found/.test(raw)) cur.lines.push(raw.replace(/^\s+!\s+/, ''));
    }
    return out.filter((a) => a.lines.length);
  }, { allowFail: true, staleTime: 30_000 });

  const names = apps.data?.apps.map((a) => a.name) ?? [];
  const checks = useDokkuBatch('checks-all', names.length ? [['checks:report'], ['ps:report']] : null, ([c, p]) => ({ checks: parseReports(c.stdout), ps: parseReports(p.stdout) }));
  const eventColor = (kind: string) => (/post-deploy|success|renew/i.test(kind) ? TONE.ok : /fail|error/i.test(kind) ? TONE.bad : /pre-deploy|build|receive/i.test(kind) ? TONE.info : '#c9c9cc');

  return (
    <Page>
      <PageHead eyebrow={host.name} title="Logs & monitoring" right={<div className="flex flex-wrap gap-1.5">{names.slice(0, 8).map((n) => <Btn key={n} className="font-mono text-[11px]" onClick={() => navigate({ view: 'app', app: n, tab: 'logs' })}>{n} logs</Btn>)}</div>} />
      <div className="grid items-start gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,380px),1fr))]">
        <Card>
          <CardHead title="Platform events" right={<>
            <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="filter" className="h-7 w-[140px]" />
            <Btn className={all ? 'bg-elev2' : undefined} title="Include every internal plugin trigger" onClick={() => setAll(!all)}>{all ? 'All triggers' : 'Changes only'}</Btn>
            {eventsOn.data === false
              ? <Btn loading={busy === 'evon'} onClick={() => act('evon', ['events:on'])}>Enable logger</Btn>
              : state === 'live' ? <Badge tone="ok" mono pulse>events -t</Badge> : <Badge tone="mute" mono>{state}</Badge>}
          </>} />
          {eventsOn.data === false && <div className="border-b border-white/6 px-4 py-2.5 text-[11.5px] text-muted">The events logger is off. Turn it on to record deploys, config changes and plugin actions to <span className="font-mono">/var/log/dokku/events.log</span>.</div>}
          <div className="max-h-[560px] overflow-auto">
            {shown.length === 0 && <Empty>{state === 'error' ? error : q ? 'No events match.' : all ? 'No events yet.' : `No deploys or config changes in the last ${lines.length} logged triggers.`}</Empty>}
            {shown.map((e, i) => (
              <div key={i} className="grid gap-3 border-t border-white/6 px-4 py-2 font-mono text-[11.5px] leading-normal" style={{ gridTemplateColumns: '70px minmax(0,1fr)' }}>
                <span className="text-dim tabular-nums">{e.ts}</span>
                <span className="[overflow-wrap:anywhere]"><span style={{ color: eventColor(e.proc) }}>{e.proc}</span> <span className="text-soft">{e.msg}</span></span>
              </div>
            ))}
          </div>
          <Cmd>$ dokku events -t  ·  events:list  ·  events:on / events:off</Cmd>
        </Card>

        <div className="flex min-w-0 flex-col gap-4">
          <Card>
            <CardHead title="Failed deploys" right={<span className="font-mono text-[10.5px]">logs:failed --all</span>} />
            {failed.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
            {failed.data === null && <Empty>This Dokku version has no <span className="font-mono">logs:failed --all</span>; open an app’s Logs tab and pick logs:failed.</Empty>}
            {failed.data && failed.data.length === 0 && <Empty>No crashed deploy containers.</Empty>}
            {failed.data?.map((f) => (
              <button key={f.app} type="button" onClick={() => navigate({ view: 'app', app: f.app, tab: 'logs' })} className="grid w-full items-center gap-3 border-0 border-t border-white/6 bg-transparent px-4 py-[11px] text-left text-fg hover:bg-white/4" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
                <div className="min-w-0"><div className="text-[12.5px] font-medium">{f.app}</div><div className="mt-[3px] truncate font-mono text-[10.5px] text-bad">{f.lines.find((l) => /error|fail|exit/i.test(l)) ?? f.lines[f.lines.length - 1]}</div></div>
                <span className="font-mono text-[10.5px] text-muted">{f.lines.length} lines</span>
              </button>
            ))}
            {failed.error && <Empty>{failed.error.message}</Empty>}
          </Card>
          <Card>
            <CardHead title="Health checks" right={<span className="font-mono text-[10.5px]">checks:report · ps:report</span>} />
            {checks.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
            {names.length === 0 && apps.data && <Empty>No apps.</Empty>}
            {names.map((n) => {
              const ps = checks.data?.ps[n];
              const c = checks.data?.checks[n];
              const procs = ps ? procStatuses(ps) : [];
              const hasWeb = procs.some((p) => p.type === 'web') || (ps?.deployed === 'true' && procs.length === 0);
              const up = procs.filter((p) => p.state === 'running').length;
              const disabled = c?.['checks disabled list'] && c['checks disabled list'] !== 'none';
              const tone = ps?.deployed !== 'true' ? 'mute' : up === 0 ? 'bad' : up < procs.length ? 'warn' : 'ok';
              const label = ps?.deployed !== 'true' ? 'not deployed' : up === 0 ? 'down' : up < procs.length ? 'degraded' : disabled ? 'up · checks off' : 'passing';
              return (
                <button key={n} type="button" onClick={() => navigate({ view: 'app', app: n, tab: 'scale' })} className="grid w-full items-center gap-3 border-0 border-t border-white/6 bg-transparent px-4 py-2 text-left text-fg hover:bg-white/4" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
                  <span className="text-[12.5px]">{n}</span>
                  <span className="font-mono text-[10.5px] text-muted">{hasWeb ? `${up}/${procs.length} up` : 'no web'}{c?.['checks skipped list'] && c['checks skipped list'] !== 'none' ? ' · skipped' : ''}</span>
                  <Dot tone={tone} className="min-w-[70px] justify-end">{label}</Dot>
                </button>
              );
            })}
          </Card>
        </div>
      </div>
    </Page>
  );
}
