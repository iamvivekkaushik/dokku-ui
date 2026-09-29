import { useQuery } from '@tanstack/react-query';
import { ExternalLink } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { Card, CardHead, Dot, Empty, KV, Skeleton, Sparkbars, TONE } from '../../components/ui';
import { api } from '../../lib/api';
import { useDokku, useReport } from '../../lib/dokku';
import { ago, bytes, ms } from '../../lib/format';
import { useCurrentHost } from '../../lib/host';
import { parseLines, procStatuses } from '../../lib/parse';
import { useMetrics } from '../Dashboard';

/** Samples container CPU/memory for this app from host metrics (shell users only). */
function useAppSamples(app: string) {
  const host = useCurrentHost();
  const metrics = useMetrics(host.mode === 'shell');
  const [samples, setSamples] = useState<{ cpu: number; mem: number; limit: number }[]>([]);
  const last = useRef(0);
  useEffect(() => {
    const m = metrics.data;
    if (!m || m.at === last.current) return;
    last.current = m.at;
    const cs = m.containers.filter((c) => c.name.startsWith(`${app}.`) && c.state === 'running');
    if (!cs.length) return;
    const cpu = cs.reduce((s, c) => s + (c.cpuPct ?? 0), 0);
    const mem = cs.reduce((s, c) => s + (c.memBytes ?? 0), 0);
    const limit = Math.max(...cs.map((c) => c.memLimit ?? 0));
    setSamples((s) => [...s.slice(-29), { cpu, mem, limit }]);
  }, [metrics.data, app]);
  return { samples, metrics, cores: metrics.data?.cores ?? null };
}

export function OverviewTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const ps = useReport('ps', app, { refetchInterval: 15_000 });
  const git = useReport('git', app);
  const appR = useReport('apps', app);
  const builder = useReport('builder', app);
  const urls = useDokku(['urls', app], (r) => parseLines(r.stdout).filter((l) => /^https?:\/\//.test(l)), { allowFail: true });
  const activity = useQuery({ queryKey: ['activity', host.id], queryFn: () => api.activity(host.id) });
  const { samples, metrics, cores } = useAppSamples(app);
  const cur = samples[samples.length - 1];
  const procs = ps.data ? procStatuses(ps.data) : [];
  const appActivity = (activity.data ?? []).filter((a) => a.command.split(' ').includes(app)).slice(0, 6);
  const noMetrics = host.mode === 'dokku' ? 'connect as a shell user for container metrics' : metrics.error ? 'docker stats unavailable' : samples.length === 0 ? (procs.some((p) => p.state === 'running') ? 'sampling…' : 'no running containers') : undefined;

  return (
    <>
      <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(260px,1fr))]">
        <Card className="flex flex-col gap-3.5 p-4">
          <div className="flex justify-between"><span className="text-[13.5px] font-semibold">CPU</span><span className="font-mono text-[10.5px] text-muted">last {samples.length ? `${samples.length * 10}s` : '5 min'}</span></div>
          <div className="flex items-baseline gap-1.5"><span className="font-mono text-[27px] font-medium tracking-[-.03em]">{cur ? cur.cpu.toFixed(1) : '—'}</span><span className="text-[11.5px] text-muted">% {cores ? `of ${cores} vCPU` : ''}</span></div>
          <Sparkbars values={samples.map((s) => s.cpu)} max={Math.max(10, ...samples.map((s) => s.cpu))} empty={noMetrics} />
        </Card>
        <Card className="flex flex-col gap-3.5 p-4">
          <div className="flex justify-between"><span className="text-[13.5px] font-semibold">Memory</span><span className="font-mono text-[10.5px] text-muted">{cur?.limit ? `limit ${bytes(cur.limit, 0)}` : ''}</span></div>
          <div className="flex items-baseline gap-1.5"><span className="font-mono text-[27px] font-medium tracking-[-.03em]">{cur ? (cur.mem / 1024 ** 2).toFixed(0) : '—'}</span><span className="text-[11.5px] text-muted">MiB</span></div>
          <Sparkbars values={samples.map((s) => s.mem)} max={Math.max(cur?.limit || 0, ...samples.map((s) => s.mem)) || 1} opacity={0.45} empty={noMetrics} />
        </Card>
        <Card className="flex flex-col gap-2.5 p-4">
          <div className="text-[13.5px] font-semibold">Release</div>
          {!git.data ? <Skeleton className="h-24 w-full" /> : (
            <div>
              <KV k="Commit" v={`${git.data['git sha'] && git.data['git sha'] !== 'HEAD' ? git.data['git sha'].slice(0, 12) : '—'} · ${git.data['git deploy branch'] || git.data['git global deploy branch'] || 'master'}`} />
              {git.data['git source image'] && <KV k="Image" v={git.data['git source image']} />}
              <KV k="Builder" v={builder.data?.['builder computed selected'] || builder.data?.['builder selected'] || 'auto'} />
              <KV k="Deployed" v={git.data['git last updated at'] ? ago(Number(git.data['git last updated at'])) : ps.data?.deployed === 'true' ? 'yes' : 'never'} />
              <KV k="Restart policy" v={ps.data?.['ps computed restart policy'] || ps.data?.['ps restart policy'] || '—'} />
              {appR.data?.['app deploy source'] && <KV k="Source" v={appR.data['app deploy source']} />}
            </div>
          )}
        </Card>
      </div>
      <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,360px),1fr))]">
        <Card>
          <CardHead title="Containers" right={<span className="font-mono">{ps.data?.processes ?? '—'} processes</span>} />
          {ps.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {ps.data && procs.length === 0 && <Empty>{ps.data.deployed === 'true' ? 'No containers running.' : 'Not deployed yet. Use Deploy app to push code or an image.'}</Empty>}
          {procs.map((p) => (
            <div key={`${p.type}.${p.index}`} className="flex items-center gap-2.5 border-t border-white/6 px-4 py-[11px]">
              <span className="size-1.5 rounded-full" style={{ background: p.state === 'running' ? TONE.ok : TONE.mute }} />
              <span className="flex-1 font-mono text-xs">{p.type}.{p.index}</span>
              <span className="font-mono text-[10.5px] text-muted">{p.cid ? p.cid.slice(0, 12) : '—'}</span>
              <span className="text-[11.5px]" style={{ color: p.state === 'running' ? TONE.ok : TONE.mute }}>{p.state}</span>
            </div>
          ))}
          {urls.data && urls.data.length > 0 && (
            <div className="flex flex-col gap-1 border-t border-white/8 px-4 py-3">
              {urls.data.map((u) => <a key={u} href={u} target="_blank" rel="noreferrer noopener" className="flex items-center gap-1.5 font-mono text-[11.5px]">{u}<ExternalLink size={11} /></a>)}
            </div>
          )}
        </Card>
        <Card>
          <CardHead title="Recent changes" right="from this console" />
          {appActivity.length === 0 && <Empty>No changes to {app} made from this console yet.</Empty>}
          {appActivity.map((a) => (
            <div key={a.id} className="flex items-center gap-3 border-t border-white/6 px-4 py-[11px]">
              <Dot tone={a.ok ? 'ok' : 'bad'} />
              <span className="min-w-0 flex-1 truncate font-mono text-[11.5px]">{a.command}</span>
              <span className="font-mono text-[10.5px] text-muted">{ms(a.durationMs)}</span>
              <span className="font-mono text-[10.5px] text-muted">{ago(a.ts)}</span>
            </div>
          ))}
        </Card>
      </div>
    </>
  );
}
