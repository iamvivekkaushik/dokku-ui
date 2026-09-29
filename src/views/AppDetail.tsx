import { useEffect } from 'react';
import { Badge, Btn, cx, Empty, Page } from '../components/ui';
import { HEALTH_TONE, useApps, useReport } from '../lib/dokku';
import { useCurrentHost } from '../lib/host';
import { appHealth } from '../lib/parse';
import { APP_TABS, navigate, useTitle, type AppTab } from '../lib/router';
import { useAction } from '../lib/runner';
import { gitRemote } from './Apps';
import { OverviewTab } from './app/Overview';
import { DeploysTab } from './app/Deploys';
import { BuildTab } from './app/Build';
import { ProcessesTab } from './app/Processes';
import { EnvTab } from './app/Env';
import { RoutingTab } from './app/Routing';
import { StorageTab } from './app/Storage';
import { LogsTab } from './app/Logs';
import { SettingsTab } from './app/Settings';

const LABELS: Record<AppTab, string> = { overview: 'Overview', deploys: 'Deploys', build: 'Build', scale: 'Processes', env: 'Environment', domains: 'Routing', storage: 'Storage & network', logs: 'Logs', settings: 'Settings' };

export function AppDetail({ app, tab }: { app: string; tab: AppTab }) {
  const host = useCurrentHost();
  useTitle(app);
  const apps = useApps();
  const ps = useReport('ps', app, { refetchInterval: 15_000 });
  const git = useReport('git', app);
  const builder = useReport('builder', app);
  const { busy, act } = useAction();
  useEffect(() => { try { localStorage.setItem('dkc.lastApp', app); } catch { /* ignore */ } }, [app]);

  const missing = apps.data && !apps.data.apps.some((a) => a.name === app);
  if (missing) {
    return (
      <Page>
        <Crumb app={app} />
        <Empty>App <span className="font-mono text-soft">{app}</span> does not exist on {host.name}. <a href="#/apps">Back to apps</a></Empty>
      </Page>
    );
  }

  const health = ps.data ? appHealth(ps.data) : null;
  const sha = git.data?.['git sha'];
  const builderName = builder.data?.['builder computed selected'] || builder.data?.['builder selected'] || builder.data?.['builder detected'] || 'auto-detect';
  const undeployed = health === 'undeployed';
  const stopped = health === 'stopped';
  return (
    <Page>
      <Crumb app={app} />
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="flex min-w-0 flex-col gap-2">
          <div className="flex items-center gap-2.5">
            <h1 className="m-0 truncate text-[26px] font-semibold leading-[1.15] tracking-[-.024em]">{app}</h1>
            {health && <Badge tone={HEALTH_TONE[health]}>{health}</Badge>}
          </div>
          <div className="flex flex-wrap gap-3.5 font-mono text-[11px] text-muted">
            <span>{gitRemote(host, app)}</span>
            <span>{builderName}</span>
            {sha && sha !== 'HEAD' && <span>rev <span className="text-soft">{sha.slice(0, 7)}</span></span>}
            {git.data?.['git source image'] && <span>image <span className="text-soft">{git.data['git source image']}</span></span>}
          </div>
        </div>
        <div className="flex gap-2">
          <Btn variant="outline" size="md" disabled={undeployed} loading={busy === 'restart'} onClick={() => act('restart', ['ps:restart', app])}>Restart</Btn>
          <Btn variant="outline" size="md" disabled={undeployed} loading={busy === 'rebuild'} onClick={() => act('rebuild', ['ps:rebuild', app])}>Rebuild</Btn>
          {stopped
            ? <Btn variant="outline" size="md" loading={busy === 'start'} onClick={() => act('start', ['ps:start', app])}>Start</Btn>
            : <Btn variant="danger" size="md" disabled={undeployed} loading={busy === 'stop'} onClick={() => act('stop', ['ps:stop', app], { confirm: { title: `Stop ${app}?`, body: 'All processes stop and the app stops serving traffic until started again.', confirmLabel: 'Stop app', danger: true } })}>Stop</Btn>}
        </div>
      </div>

      <div className="no-scrollbar flex flex-nowrap gap-1 overflow-x-auto border-b border-white/8" role="tablist">
        {APP_TABS.map((t) => (
          <button key={t} type="button" role="tab" aria-selected={t === tab} onClick={() => navigate({ view: 'app', app, tab: t })}
            className={cx('-mb-px h-9 flex-none whitespace-nowrap border-0 border-b-2 bg-transparent px-3 text-[12.5px] font-medium transition-colors hover:text-fg', t === tab ? 'border-fg text-fg' : 'border-transparent text-muted')}>
            {LABELS[t]}
          </button>
        ))}
      </div>

      {tab === 'overview' && <OverviewTab app={app} />}
      {tab === 'deploys' && <DeploysTab app={app} />}
      {tab === 'build' && <BuildTab app={app} />}
      {tab === 'scale' && <ProcessesTab app={app} />}
      {tab === 'env' && <EnvTab app={app} />}
      {tab === 'domains' && <RoutingTab app={app} />}
      {tab === 'storage' && <StorageTab app={app} />}
      {tab === 'logs' && <LogsTab app={app} />}
      {tab === 'settings' && <SettingsTab app={app} />}
    </Page>
  );
}

function Crumb({ app }: { app: string }) {
  return (
    <div className="flex items-center gap-1.5 text-xs text-muted">
      <button type="button" onClick={() => navigate({ view: 'apps' })} className="border-0 bg-transparent p-0 text-muted hover:text-fg">Apps</button>
      <span>/</span><span className="font-medium text-fg">{app}</span>
    </div>
  );
}
