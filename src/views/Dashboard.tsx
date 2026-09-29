import { useQuery } from '@tanstack/react-query';
import { GitCommitHorizontal } from 'lucide-react';
import type { ReactNode } from 'react';
import { Badge, Card, CardHead, cx, Empty, Page, PageHead, Skeleton, THead, TickMeter, TONE, type Tone } from '../components/ui';
import { api } from '../lib/api';
import { useDatastores } from '../lib/datastores';
import { HEALTH_TONE, useApps, useDokku } from '../lib/dokku';
import { ago, bytes, duration } from '../lib/format';
import { useCurrentHost } from '../lib/host';
import { parseReports, procStatuses } from '../lib/parse';
import { navigate, useTitle } from '../lib/router';

export function useSystem() {
  const host = useCurrentHost();
  return useQuery({ queryKey: ['dokku', host.id, 'system'], queryFn: () => api.system(host.id), staleTime: 5 * 60_000 });
}

export function useMetrics(enabled = true) {
  const host = useCurrentHost();
  return useQuery({
    queryKey: ['metrics', host.id], queryFn: () => api.metrics(host.id), enabled: enabled && host.mode === 'shell',
    refetchInterval: 10_000, retry: false, staleTime: 5_000,
  });
}

interface Stat { label: string; value: ReactNode; unit: string; delta?: string; deltaTone?: Tone; sub: string; pct: number; color: string }

function StatCard({ s }: { s: Stat }) {
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-white/8 bg-card p-4 shadow-[0_1px_2px_rgba(0,0,0,.3)]">
      <div className="flex items-center justify-between">
        <span className="text-[13.5px] font-semibold tracking-[-.01em]">{s.label}</span>
        {s.delta && <span className="font-mono text-[10.5px]" style={{ color: s.deltaTone ? TONE[s.deltaTone] : '#8a8a90' }}>{s.delta}</span>}
      </div>
      <div className="flex items-baseline gap-1.5">
        <span className="font-mono text-[27px] font-medium tabular-nums tracking-[-.03em]">{s.value}</span>
        <span className="text-[11.5px] text-muted">{s.unit}</span>
      </div>
      <TickMeter pct={s.pct} color={s.color} />
      <div className="truncate font-mono text-[10.5px] text-muted">{s.sub}</div>
    </div>
  );
}

function StatSkeleton() {
  return (
    <div className="flex h-[118px] flex-col gap-3 rounded-xl border border-white/8 bg-card p-4">
      <Skeleton className="h-2.5 w-2/5" /><Skeleton className="h-[26px] w-[55%] rounded-md" /><Skeleton className="h-1.5 w-full" />
    </div>
  );
}

export function Dashboard() {
  const host = useCurrentHost();
  useTitle(host.name);
  const apps = useApps();
  const sys = useSystem();
  const ds = useDatastores();
  const metrics = useMetrics();
  const git = useDokku(['git:report'], (r) => parseReports(r.stdout), { staleTime: 30_000 });
  const m = metrics.data;
  const appList = apps.data?.apps ?? [];
  const procs = appList.flatMap((a) => procStatuses(a.ps).map((p) => ({ ...p, app: a.name })));
  const running = procs.filter((p) => p.state === 'running').length;

  let stats: Stat[] | null = null;
  if (host.mode === 'shell' && m) {
    const memUsed = m.mem.total - m.mem.available;
    const memPct = m.mem.total ? (memUsed / m.mem.total) * 100 : 0;
    const diskPct = m.disk.total ? (m.disk.used / m.disk.total) * 100 : 0;
    const up = m.containers.filter((c) => c.state === 'running').length;
    stats = [
      { label: 'CPU', value: m.cpuPct != null ? Math.round(m.cpuPct) : '—', unit: `% · ${m.cores ?? '?'} vCPU`, delta: `load ${m.load[0]?.toFixed(2)}`, sub: `load ${m.load.map((l) => l.toFixed(2)).join(' ')}`, pct: m.cpuPct ?? 0, color: (m.cpuPct ?? 0) > 85 ? TONE.bad : '#ededef' },
      { label: 'Memory', value: bytes(memUsed).split(' ')[0], unit: `${bytes(memUsed).split(' ')[1]} / ${bytes(m.mem.total)}`, delta: `${Math.round(memPct)}%`, deltaTone: memPct > 85 ? 'bad' : memPct > 70 ? 'warn' : 'ok', sub: `swap ${bytes(m.swap.total - m.swap.free)} / ${bytes(m.swap.total)}`, pct: memPct, color: memPct > 85 ? TONE.bad : memPct > 70 ? TONE.warn : '#ededef' },
      { label: 'Disk', value: bytes(m.disk.used).split(' ')[0], unit: `${bytes(m.disk.used).split(' ')[1]} / ${bytes(m.disk.total)}`, delta: `${bytes(m.disk.avail)} free`, deltaTone: diskPct > 90 ? 'bad' : undefined, sub: `${m.disk.device} · ${Math.round(diskPct)}%`, pct: diskPct, color: diskPct > 90 ? TONE.bad : diskPct > 80 ? TONE.warn : '#ededef' },
      { label: 'Containers', value: m.dockerAvailable ? up : running, unit: 'running', delta: m.dockerAvailable ? `${m.containers.length - up} stopped` : 'docker n/a', sub: `${appList.length} apps · ${ds.data?.services.length ?? 0} services`, pct: m.containers.length ? (up / m.containers.length) * 100 : 0, color: TONE.ok },
    ];
  } else if (host.mode === 'dokku' && apps.data) {
    const deployed = appList.filter((a) => a.health !== 'undeployed').length;
    const domains = appList.reduce((n, a) => n + a.domains.length, 0);
    const degraded = appList.filter((a) => a.health === 'degraded' || a.health === 'stopped').length;
    stats = [
      { label: 'Apps', value: appList.length, unit: 'provisioned', delta: `${deployed} deployed`, sub: `${degraded} stopped or degraded`, pct: appList.length ? (deployed / appList.length) * 100 : 0, color: '#ededef' },
      { label: 'Processes', value: running, unit: `/ ${procs.length} running`, delta: procs.length - running ? `${procs.length - running} down` : 'all up', deltaTone: procs.length - running ? 'warn' : 'ok', sub: 'from ps:report', pct: procs.length ? (running / procs.length) * 100 : 0, color: TONE.ok },
      { label: 'Services', value: ds.data?.services.length ?? '—', unit: 'datastores', sub: `${ds.data ? [...ds.data.installed].filter((p) => ['postgres', 'redis', 'mysql', 'mariadb', 'mongo', 'elasticsearch', 'rabbitmq', 'meilisearch'].includes(p)).length : 0} plugins installed`, pct: Math.min(100, (ds.data?.services.length ?? 0) * 10), color: TONE.info },
      { label: 'Domains', value: domains, unit: 'bound', sub: `global: ${apps.data.globalVhosts.join(' ') || 'none'}`, pct: Math.min(100, domains * 8), color: '#ededef' },
    ];
  }

  const containers = host.mode === 'shell' && m?.dockerAvailable
    ? m.containers.filter((c) => !c.name.startsWith('dokku.') || true).map((c) => {
      const parts = c.name.split('.');
      const app = c.name.startsWith('dokku.') ? `${parts[1]}:${parts.slice(2).join('.')}` : parts[0];
      return { name: c.name, app, isApp: !c.name.startsWith('dokku.') && appList.some((a) => a.name === parts[0]), cpu: c.cpuPct != null ? `${c.cpuPct.toFixed(1)}%` : '—', mem: c.memBytes != null ? bytes(c.memBytes, 0) : '—', state: c.state };
    }).sort((a, b) => Number(b.state === 'running') - Number(a.state === 'running') || a.name.localeCompare(b.name))
    : procs.map((p) => ({ name: `${p.app}.${p.type}.${p.index}`, app: p.app, isApp: true, cpu: '—', mem: '—', state: p.state }));

  const deploys = Object.entries(git.data ?? {})
    .map(([app, r]) => ({ app, sha: r['git sha'], at: Number(r['git last updated at']) || 0, image: r['git source image'], health: appList.find((a) => a.name === app)?.health ?? 'stopped' }))
    .filter((d) => d.at || (d.sha && d.sha !== 'HEAD') || d.image)
    .sort((a, b) => b.at - a.at)
    .slice(0, 8);

  const loading = !stats && (metrics.isLoading || apps.isLoading);
  return (
    <Page>
      <PageHead eyebrow="Server overview" title={host.name}
        right={
          <div className="flex flex-wrap gap-4 font-mono text-[11.5px] text-muted">
            <span>dokku <span className="text-fg">{sys.data?.dokku ?? '…'}</span></span>
            {sys.data?.docker && <span>docker <span className="text-fg">{sys.data.docker}</span></span>}
            {sys.data?.os && <span className="max-sm:hidden"><span className="text-fg">{sys.data.os}</span></span>}
            {(m?.uptimeSec ?? sys.data?.uptime) && <span>uptime <span className="text-fg">{duration(m?.uptimeSec ?? Number(String(sys.data?.uptime).split(' ')[0]))}</span></span>}
          </div>
        } />

      <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(220px,1fr))]">
        {loading && [1, 2, 3, 4].map((i) => <StatSkeleton key={i} />)}
        {stats?.map((s) => <StatCard key={s.label} s={s} />)}
      </div>
      {host.mode === 'shell' && metrics.error && <div className="text-xs text-warn">Host metrics unavailable: {metrics.error.message}</div>}

      <div className="grid gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr))]">
        <Card className="flex flex-col">
          <CardHead title="Running containers" right={host.mode === 'shell' ? <Badge tone="ok" mono pulse>live · 10s</Badge> : <Badge tone="mute" mono>ps:report</Badge>} />
          <div className="overflow-x-auto">
            <div className="min-w-[520px]">
              <THead cols="1.4fr 1fr 70px 100px 90px"><span>container</span><span>app</span><span className="text-right">cpu</span><span className="text-right">memory</span><span className="text-right">state</span></THead>
              {apps.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
              {!apps.isLoading && containers.length === 0 && <Empty>No containers yet. Deploy an app to see its processes here.</Empty>}
              {containers.map((c) => (
                <button key={c.name} type="button" onClick={() => c.isApp && navigate({ view: 'app', app: c.app, tab: 'overview' })}
                  className={cx('grid w-full items-center gap-2 border-0 border-t border-white/6 bg-transparent px-4 py-2.5 text-left text-fg', c.isApp ? 'hover:bg-white/4' : 'cursor-default')}
                  style={{ gridTemplateColumns: '1.4fr 1fr 70px 100px 90px' }}>
                  <span className="truncate font-mono text-[11.5px]">{c.name}</span>
                  <span className="truncate text-[12.5px] text-soft">{c.app}</span>
                  <span className="text-right font-mono text-[11.5px] tabular-nums">{c.cpu}</span>
                  <span className="text-right font-mono text-[11.5px] tabular-nums">{c.mem}</span>
                  <span className="flex items-center justify-end gap-1.5 text-[11.5px]" style={{ color: c.state === 'running' ? TONE.ok : TONE.mute }}>
                    <span className="size-1.5 rounded-full" style={{ background: c.state === 'running' ? TONE.ok : TONE.mute }} />{c.state}
                  </span>
                </button>
              ))}
            </div>
          </div>
        </Card>

        <Card className="flex flex-col">
          <CardHead title="Recent deployments" right={<a href="#/apps">View all</a>} />
          {git.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {!git.isLoading && deploys.length === 0 && <Empty>No deploys recorded yet.</Empty>}
          {deploys.map((d) => {
            const tone = HEALTH_TONE[d.health];
            return (
              <button key={d.app} type="button" onClick={() => navigate({ view: 'app', app: d.app, tab: 'deploys' })} className="flex items-start gap-3 border-0 border-t border-white/6 bg-transparent px-4 py-[11px] text-left text-fg hover:bg-white/4">
                <GitCommitHorizontal size={14} strokeWidth={1.6} className="mt-0.5 flex-none" style={{ color: TONE[tone] }} />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[12.5px]">{d.app}{d.image && <span className="text-muted"> · image {d.image}</span>}</div>
                  <div className="mt-[3px] flex gap-2 font-mono text-[10.5px] text-muted">
                    <span className="text-soft">{d.sha && d.sha !== 'HEAD' ? d.sha.slice(0, 7) : 'image'}</span>
                    <span>{d.at ? ago(d.at) : '—'}</span>
                  </div>
                </div>
                <Badge tone={tone} mono dot={false}>{d.health === 'running' ? 'deployed' : d.health}</Badge>
              </button>
            );
          })}
        </Card>
      </div>
    </Page>
  );
}
