import { Globe } from 'lucide-react';
import { useState } from 'react';
import { Badge, Btn, CopyBtn, cx, Empty, Input, Page, PageHead, Seg, Skeleton, THead, TONE } from '../components/ui';
import { HEALTH_TONE, useApps, type AppSummary } from '../lib/dokku';
import { useCurrentHost } from '../lib/host';
import { procStatuses } from '../lib/parse';
import { navigate, useTitle } from '../lib/router';
import { useAction } from '../lib/runner';
import { useUi } from '../lib/uictx';

export function gitRemote(host: { host: string; port: number }, app: string) {
  return host.port === 22 ? `dokku@${host.host}:${app}` : `ssh://dokku@${host.host}:${host.port}/${app}`;
}

function AppCard({ a }: { a: AppSummary }) {
  const host = useCurrentHost();
  const { busy, act } = useAction();
  const procs = procStatuses(a.ps);
  const remote = gitRemote(host, a.name);
  const stopped = a.health === 'stopped';
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-white/8 bg-card p-4 shadow-[0_1px_2px_rgba(0,0,0,.3)] transition-colors hover:border-white/18">
      <div className="flex items-start justify-between gap-2">
        <button type="button" onClick={() => navigate({ view: 'app', app: a.name, tab: 'overview' })} className="border-0 bg-transparent p-0 text-left text-sm font-semibold tracking-[-.01em] text-fg hover:underline">{a.name}</button>
        <Badge tone={HEALTH_TONE[a.health]}>{a.health}</Badge>
      </div>
      <div className="flex items-center gap-1.5 overflow-hidden rounded-md border border-white/6 bg-white/4 py-0.5 pl-2 pr-0.5 font-mono text-[11px] text-muted">
        <span className="min-w-0 flex-1 truncate">{remote}</span>
        <CopyBtn text={remote} />
      </div>
      <div className="flex flex-wrap gap-1.5">
        {procs.length === 0 && <span className="font-mono text-[10.5px] text-dim">{a.health === 'undeployed' ? 'not deployed' : 'no processes'}</span>}
        {procs.map((p) => (
          <span key={`${p.type}.${p.index}`} className="inline-flex items-center gap-1.5 rounded-[5px] border border-white/8 px-[7px] py-0.5 font-mono text-[10.5px] text-soft">
            <span className="size-[5px] rounded-full" style={{ background: p.state === 'running' ? TONE.ok : TONE.mute }} />{p.type}.{p.index}: {p.state}
          </span>
        ))}
      </div>
      <div className="flex min-h-[18px] flex-col gap-[3px] text-xs text-muted">
        {a.domains.slice(0, 3).map((d) => <span key={d} className="flex items-center gap-1.5 truncate"><Globe size={11} strokeWidth={1.6} className="flex-none" />{d}</span>)}
        {a.domains.length > 3 && <span className="text-dim">+{a.domains.length - 3} more</span>}
        {a.domains.length === 0 && <span className="text-dim">No domains bound</span>}
      </div>
      <div className="flex gap-1.5 border-t border-white/6 pt-3">
        <Btn className="flex-1" loading={busy === 'restart'} disabled={a.health === 'undeployed'} onClick={() => act('restart', ['ps:restart', a.name])}>Restart</Btn>
        <Btn className="flex-1" loading={busy === 'rebuild'} disabled={a.health === 'undeployed'} onClick={() => act('rebuild', ['ps:rebuild', a.name])}>Rebuild</Btn>
        {stopped
          ? <Btn className="flex-1" loading={busy === 'start'} onClick={() => act('start', ['ps:start', a.name])}>Start</Btn>
          : <Btn className="flex-1" loading={busy === 'stop'} disabled={a.health === 'undeployed'} onClick={() => act('stop', ['ps:stop', a.name], { confirm: { title: `Stop ${a.name}?`, body: 'All processes stop and the app stops serving traffic until started again.', confirmLabel: 'Stop app', danger: true } })}>Stop</Btn>}
        <Btn className="flex-1" onClick={() => navigate({ view: 'app', app: a.name, tab: 'logs' })}>Logs</Btn>
      </div>
    </div>
  );
}

export function AppsView() {
  const host = useCurrentHost();
  useTitle('Apps');
  const apps = useApps();
  const ui = useUi();
  const [query, setQuery] = useState('');
  const [layout, setLayout] = useState<'grid' | 'list'>(() => { try { return (localStorage.getItem('dkc.appsLayout') as 'grid' | 'list') || 'grid'; } catch { return 'grid'; } });
  const setL = (l: 'grid' | 'list') => { setLayout(l); try { localStorage.setItem('dkc.appsLayout', l); } catch { /* ignore */ } };
  const list = (apps.data?.apps ?? []).filter((a) => a.name.includes(query.toLowerCase().trim()) || a.domains.some((d) => d.includes(query.toLowerCase().trim())));

  return (
    <Page>
      <PageHead eyebrow={host.name} title="Apps"
        right={<>
          <Input h="md" mono={false} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Filter apps" className="w-[220px] max-sm:w-full" />
          <Seg value={layout} onChange={setL} options={[{ value: 'grid', label: 'Grid' }, { value: 'list', label: 'List' }]} />
          <Btn variant="primary" size="md" onClick={ui.openCreateApp}>+ Create app</Btn>
        </>} />

      {apps.error && <Empty>Could not list apps: {apps.error.message}</Empty>}
      {apps.isLoading && <div className="grid gap-4 [grid-template-columns:repeat(auto-fill,minmax(300px,1fr))]">{[1, 2, 3].map((i) => <div key={i} className="flex h-[210px] flex-col gap-3 rounded-xl border border-white/8 bg-card p-4"><Skeleton className="h-4 w-1/2" /><Skeleton className="h-6 w-full" /><Skeleton className="h-3 w-2/3" /></div>)}</div>}
      {apps.data && list.length === 0 && (
        <div className="rounded-xl border border-dashed border-white/14 bg-white/2 p-10 text-center text-xs text-muted">
          {query ? <>No apps match “{query}”. </> : <>No apps on this host yet. </>}
          <span className="font-mono">dokku apps:create &lt;name&gt;</span> to add one, or use <button type="button" onClick={ui.openCreateApp} className="border-0 bg-transparent p-0 text-info hover:underline">Create app</button>.
        </div>
      )}

      {layout === 'grid' && list.length > 0 && (
        <div className="grid gap-4 [grid-template-columns:repeat(auto-fill,minmax(300px,1fr))]">{list.map((a) => <AppCard key={a.name} a={a} />)}</div>
      )}
      {layout === 'list' && list.length > 0 && (
        <div className="overflow-x-auto rounded-xl border border-white/8 bg-card">
          <div className="min-w-[720px]">
            <THead cols="1.2fr 1.6fr 1.4fr 1.2fr 110px"><span>app</span><span>git remote</span><span>processes</span><span>domains</span><span className="text-right">status</span></THead>
            {list.map((a) => (
              <button key={a.name} type="button" onClick={() => navigate({ view: 'app', app: a.name, tab: 'overview' })}
                className={cx('grid w-full items-center gap-3 border-0 border-t border-white/6 bg-transparent px-4 py-[11px] text-left text-fg hover:bg-white/4')} style={{ gridTemplateColumns: '1.2fr 1.6fr 1.4fr 1.2fr 110px' }}>
                <span className="text-[13px] font-semibold">{a.name}</span>
                <span className="truncate font-mono text-[11px] text-muted">{gitRemote(host, a.name)}</span>
                <span className="truncate font-mono text-[11px] text-soft">{procStatuses(a.ps).map((p) => `${p.type}.${p.index}:${p.state === 'running' ? 'up' : 'down'}`).join(' ') || '—'}</span>
                <span className="truncate text-xs text-muted">{a.domains.join(', ') || '—'}</span>
                <span className="flex items-center justify-end gap-1.5 text-[11.5px]" style={{ color: TONE[HEALTH_TONE[a.health]] }}><span className="size-1.5 rounded-full" style={{ background: TONE[HEALTH_TONE[a.health]] }} />{a.health}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </Page>
  );
}
