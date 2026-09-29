import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { ActivityDrawer, ConnectionAlert, Sidebar, TopBar } from './components/Shell';
import { CommandErrorDialog, ConfirmDialog, ConnectHostDialog, JobDock } from './components/Dialogs';
import { CommandPalette, CreateAppDialog, DeployDialog, ProvisionDialog } from './components/ActionDialogs';
import { Console, TerminalModal, type TerminalSpec } from './components/Terminal';
import { ErrorBoundary } from './components/ErrorBoundary';
import { Btn, IconBtn, Input, Modal } from './components/ui';
import { api } from './lib/api';
import { HostProvider, useHost } from './lib/host';
import { useRoute } from './lib/router';
import { RunnerProvider } from './lib/runner';
import { UiCtx, type UiActions } from './lib/uictx';
import { Dashboard } from './views/Dashboard';
import { AppsView } from './views/Apps';
import { AppDetail } from './views/AppDetail';
import { Datastores } from './views/Datastores';
import { Monitoring } from './views/Monitoring';
import { ServerView } from './views/Server';
import { InstallWizard } from './views/Install';
import { X } from 'lucide-react';

export default function App() {
  // Keeps polling while the console server is unreachable so the UI recovers on its own.
  const session = useQuery({ queryKey: ['session'], queryFn: api.session, retry: 2, retryDelay: 800, refetchInterval: (q) => (q.state.status === 'error' ? 3000 : false) });
  const qc = useQueryClient();
  useEffect(() => {
    const on = () => qc.invalidateQueries({ queryKey: ['session'] });
    window.addEventListener('dkc:unauthorized', on);
    return () => window.removeEventListener('dkc:unauthorized', on);
  }, [qc]);
  if (session.isLoading) return <div className="h-screen bg-bg" />;
  if (session.error && !session.data) {
    return (
      <div className="grid h-screen place-items-center bg-bg p-6">
        <div className="flex max-w-[420px] flex-col items-center gap-3 text-center">
          <div className="text-[15px] font-semibold">Cannot reach the console server</div>
          <div className="text-xs leading-relaxed text-muted">{session.error.message}. Make sure the Dokku Console server process is running; this page reconnects automatically.</div>
          <Btn variant="outline" size="md" loading={session.isFetching} onClick={() => session.refetch()}>Retry now</Btn>
        </div>
      </div>
    );
  }
  if (session.data && !session.data.authenticated) return <Login />;
  return (
    <HostProvider>
      <RunnerProvider>
        <Shell authRequired={!!session.data?.authRequired} />
      </RunnerProvider>
    </HostProvider>
  );
}

function Login() {
  const qc = useQueryClient();
  const [pw, setPw] = useState('');
  const [err, setErr] = useState('');
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    try { await api.login(pw); qc.invalidateQueries(); } catch (x) { setErr((x as Error).message); }
  };
  return (
    <div className="grid h-screen place-items-center bg-bg p-6">
      <form onSubmit={submit} className="flex w-[340px] animate-pop flex-col gap-3.5 rounded-[14px] border border-white/10 bg-card p-6">
        <div className="flex items-center gap-2.5">
          <div className="grid size-[26px] place-items-center rounded-[7px] bg-fg font-mono text-xs font-medium text-bg">dk</div>
          <div className="text-[15px] font-semibold">Dokku Console</div>
        </div>
        <Input h="md" type="password" autoFocus value={pw} onChange={(e) => setPw(e.target.value)} placeholder="Console password" mono={false} />
        {err && <div className="text-xs text-bad">{err}</div>}
        <Btn variant="primary" size="md" type="submit">Sign in</Btn>
      </form>
    </div>
  );
}

function Shell({ authRequired }: { authRequired: boolean }) {
  const route = useRoute();
  const { host, hosts, loading } = useHost();
  const [sidebar, setSidebar] = useState(() => { try { return localStorage.getItem('dkc.sidebar') !== '0'; } catch { return true; } });
  const [drawer, setDrawer] = useState(false);
  const [mobileNav, setMobileNav] = useState(false);
  const [palette, setPalette] = useState(false);
  const [connect, setConnect] = useState<{ open: boolean; edit: string | null }>({ open: false, edit: null });
  const [terminal, setTerminal] = useState<{ spec: TerminalSpec; title: string } | null>(null);
  const [consoleOpen, setConsoleOpen] = useState(false);
  const [deploy, setDeploy] = useState<{ open: boolean; app?: string }>({ open: false });
  const [createApp, setCreateApp] = useState(false);
  const [provision, setProvision] = useState<{ open: boolean; type?: string }>({ open: false });

  const toggleSidebar = useCallback(() => setSidebar((s) => { try { localStorage.setItem('dkc.sidebar', s ? '0' : '1'); } catch { /* ignore */ } return !s; }), []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      const typing = t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable || t.closest('.xterm');
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); if (host) setPalette(true); }
      else if (e.key === '[' && !typing && !e.metaKey && !e.ctrlKey) toggleSidebar();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [host, toggleSidebar]);

  const ui: UiActions = useMemo(() => ({
    openTerminal: (spec, title) => setTerminal({ spec, title: title ?? (spec.kind === 'shell' ? 'SSH terminal' : `dokku ${spec.args.join(' ')}`) }),
    openConsole: () => setConsoleOpen(true),
    openDeploy: (app) => setDeploy({ open: true, app }),
    openCreateApp: () => setCreateApp(true),
    openProvision: (type) => setProvision({ open: true, type }),
    openConnect: (edit) => setConnect({ open: true, edit: edit ?? null }),
  }), []);

  const onTerminal = () => {
    if (!host) return;
    if (host.mode === 'shell') ui.openTerminal({ kind: 'shell' }, `SSH terminal · ${host.name}`);
    else ui.openConsole();
  };

  const activity = useQuery({ queryKey: ['activity', host?.id], queryFn: () => api.activity(host!.id), enabled: !!host, refetchInterval: 30_000 });
  const [seen, setSeen] = useState(0);
  const newest = activity.data?.[0];
  const unread = newest && newest.id > seen ? (activity.data!.some((a) => a.id > seen && !a.ok) ? 'fail' : 'ok') : 'none';

  let view;
  if (loading) view = null;
  else if (route.view === 'install') view = <InstallWizard />;
  else if (!host) view = <Welcome onConnect={() => ui.openConnect()} hasHosts={hosts.length > 0} />;
  else if (route.view === 'apps') view = <AppsView />;
  else if (route.view === 'app') view = <AppDetail key={`${host.id}:${route.app}`} app={route.app} tab={route.tab} />;
  else if (route.view === 'data') view = <Datastores />;
  else if (route.view === 'monitor') view = <Monitoring />;
  else if (route.view === 'server') view = <ServerView />;
  else view = <Dashboard />;

  return (
    <UiCtx.Provider value={ui}>
      <div className="flex h-screen min-h-[600px] overflow-hidden bg-bg text-fg">
        <Sidebar route={route} open={sidebar} onToggle={toggleSidebar} mobileOpen={mobileNav} onMobileClose={() => setMobileNav(false)} />
        <div className="flex min-w-0 flex-1 flex-col">
          <TopBar onMenu={() => setMobileNav(true)} onSearch={() => setPalette(true)} onTerminal={onTerminal} onDeploy={() => ui.openDeploy(route.view === 'app' ? route.app : undefined)}
            onDrawer={() => { setDrawer(true); if (newest) setSeen(newest.id); }} onAddHost={() => ui.openConnect()} onEditHost={(id) => ui.openConnect(id)} authRequired={authRequired} unread={unread} />
          <ConnectionAlert />
          <main className="flex-1 overflow-auto px-6 pb-10 pt-6 max-sm:px-4"><ErrorBoundary resetKey={`${host?.id}:${location.hash}`}>{view}</ErrorBoundary></main>
        </div>
      </div>
      <ActivityDrawer open={drawer} onClose={() => setDrawer(false)} />
      <ConnectHostDialog open={connect.open} editId={connect.edit} onClose={() => setConnect({ open: false, edit: null })} />
      {host && <>
        <CommandPalette open={palette} onClose={() => setPalette(false)} />
        <DeployDialog open={deploy.open} initialApp={deploy.app} onClose={() => setDeploy({ open: false })} />
        <CreateAppDialog open={createApp} onClose={() => setCreateApp(false)} />
        <ProvisionDialog open={provision.open} initialType={provision.type} onClose={() => setProvision({ open: false })} />
        <Modal open={consoleOpen} onOpenChange={setConsoleOpen} width={900} title="Console"
          header={<div className="flex items-center justify-between border-b border-white/8 px-4 py-3"><span className="text-[13.5px] font-semibold">Dokku console · {host.name}</span><IconBtn title="Close" onClick={() => setConsoleOpen(false)}><X size={13} /></IconBtn></div>}>
          <Console className="h-[60vh]" onInteractive={(args) => { setConsoleOpen(false); ui.openTerminal({ kind: 'dokku', args }); }} />
        </Modal>
      </>}
      {terminal && <TerminalModal spec={terminal.spec} title={terminal.title} onClose={() => setTerminal(null)} />}
      <CommandErrorDialog />
      <ConfirmDialog />
      <JobDock />
    </UiCtx.Provider>
  );
}

function Welcome({ onConnect, hasHosts }: { onConnect: () => void; hasHosts: boolean }) {
  return (
    <div className="mx-auto mt-[10vh] flex max-w-[520px] animate-rise flex-col items-center gap-4 text-center">
      <div className="grid size-12 place-items-center rounded-xl bg-fg font-mono text-lg font-medium text-bg">dk</div>
      <h1 className="m-0 text-[26px] font-semibold tracking-[-.024em]">{hasHosts ? 'Select a host' : 'Connect your first Dokku host'}</h1>
      <p className="m-0 text-[13px] leading-relaxed text-muted">
        The console talks to Dokku over SSH. Connect as the <span className="font-mono text-soft">dokku</span> user for app management, or as root / a sudo user to also manage plugins, SSH keys and see host metrics.
      </p>
      <div className="flex gap-2">
        <Btn variant="primary" size="md" onClick={onConnect}><Plus size={13} />Connect a host</Btn>
        <Btn variant="outline" size="md" onClick={() => { location.hash = '#/install'; }}>Install Dokku on a server</Btn>
      </div>
    </div>
  );
}
