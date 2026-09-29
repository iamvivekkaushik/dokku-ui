import * as Popover from '@radix-ui/react-popover';
import * as Menu from '@radix-ui/react-dropdown-menu';
import { useQuery } from '@tanstack/react-query';
import { Activity, ArrowUp, Bell, Box, Check, ChevronDown, ChevronsUpDown, Database, Globe, KeyRound, LayoutDashboard, LogOut, Menu as Menu2, Network, PanelLeft, Plus, Search, Server, Settings2, Terminal, TriangleAlert, X } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import { api } from '../lib/api';
import { useApps } from '../lib/dokku';
import { ago, ms } from '../lib/format';
import { useHost } from '../lib/host';
import { navigate, type Route } from '../lib/router';
import { Btn, cx, IconBtn, Kbd, TONE } from './ui';

export function lastApp(): string | null {
  try { return localStorage.getItem('dkc.lastApp'); } catch { return null; }
}

type NavId = 'dash' | 'apps' | 'data' | 'domains' | 'env' | 'net' | 'monitor' | 'server';
const NAV: { id: NavId; label: string; icon: ReactNode }[] = [
  { id: 'dash', label: 'Dashboard', icon: <LayoutDashboard size={15} strokeWidth={1.5} /> },
  { id: 'apps', label: 'Apps', icon: <Box size={15} strokeWidth={1.5} /> },
  { id: 'data', label: 'Datastores', icon: <Database size={15} strokeWidth={1.5} /> },
  { id: 'domains', label: 'Domains & SSL', icon: <Globe size={15} strokeWidth={1.5} /> },
  { id: 'env', label: 'Environment', icon: <KeyRound size={15} strokeWidth={1.5} /> },
  { id: 'net', label: 'Networking & proxy', icon: <Network size={15} strokeWidth={1.5} /> },
  { id: 'monitor', label: 'Logs & monitoring', icon: <Activity size={15} strokeWidth={1.5} /> },
  { id: 'server', label: 'Server & SSH', icon: <Server size={15} strokeWidth={1.5} /> },
];

function activeNav(r: Route): NavId {
  if (r.view === 'app') {
    if (r.tab === 'env') return 'env';
    if (r.tab === 'domains') return 'domains';
    if (r.tab === 'storage') return 'net';
    return 'apps';
  }
  if (r.view === 'install') return 'server';
  return r.view as NavId;
}

export function Sidebar({ route, open, onToggle, mobileOpen, onMobileClose }: { route: Route; open: boolean; onToggle: () => void; mobileOpen: boolean; onMobileClose: () => void }) {
  const { host } = useHost();
  const apps = useApps();
  const active = activeNav(route);
  const go = (id: NavId) => {
    const names = apps.data?.apps.map((a) => a.name) ?? [];
    const target = (route.view === 'app' ? route.app : null) ?? (lastApp() && names.includes(lastApp()!) ? lastApp() : names[0]);
    if (id === 'domains' || id === 'env' || id === 'net') {
      if (target) navigate({ view: 'app', app: target, tab: id === 'env' ? 'env' : id === 'domains' ? 'domains' : 'storage' });
      else navigate({ view: 'apps' });
    } else navigate({ view: id } as Route);
    onMobileClose();
  };
  // Below the md breakpoint the sidebar becomes a drawer opened from the top bar.
  const expanded = open || mobileOpen;
  return (
    <>
    {mobileOpen && <div className="fixed inset-0 z-40 bg-bg/60 md:hidden" onClick={onMobileClose} />}
    <aside className={cx('flex flex-none flex-col overflow-hidden border-r border-white/8 bg-[linear-gradient(180deg,#0e0e10,#0a0a0b)] transition-[width] duration-[180ms] ease-[cubic-bezier(.22,1,.36,1)]', mobileOpen ? 'max-md:fixed max-md:inset-y-0 max-md:left-0 max-md:z-50 max-md:shadow-[20px_0_60px_rgba(0,0,0,.5)]' : 'max-md:hidden')} style={{ width: expanded ? 232 : 56 }}>
      <div className="flex h-[52px] flex-none items-center gap-2.5 border-b border-white/8 px-3.5">
        <div className="grid size-[26px] flex-none place-items-center rounded-[7px] bg-fg font-mono text-xs font-medium text-bg">dk</div>
        {expanded && <div className="whitespace-nowrap text-[13.5px] font-semibold tracking-[-.01em]">Dokku Console</div>}
      </div>
      <nav className="flex flex-1 flex-col gap-0.5 px-2 py-2.5" aria-label="Main">
        {NAV.map((n) => {
          const on = active === n.id;
          const disabled = !host && n.id !== 'server';
          return (
            <button key={n.id} type="button" title={n.label} disabled={disabled} onClick={() => go(n.id)} aria-current={on ? 'page' : undefined}
              className={cx('relative flex h-[34px] items-center gap-2.5 whitespace-nowrap rounded-lg border-0 px-2.5 text-left text-[12.5px] font-medium transition-colors disabled:opacity-40',
                on ? 'bg-white/[.085] text-fg shadow-[inset_0_0_0_1px_rgba(255,255,255,.09)]' : 'bg-transparent text-white/64 hover:bg-white/6 hover:text-fg')}>
              <span className="absolute -left-2 bottom-2 top-2 w-0.5 rounded-sm" style={{ background: on ? '#ededef' : 'transparent' }} />
              <span className="flex-none">{n.icon}</span>
              {expanded && <span className="flex-1">{n.label}</span>}
              {expanded && n.id === 'apps' && apps.data && <span className="rounded-full bg-white/6 px-1.5 py-px font-mono text-[10.5px] text-muted">{apps.data.apps.length}</span>}
            </button>
          );
        })}
      </nav>
      <div className="border-t border-white/8 px-2 py-2.5 max-md:hidden">
        <button type="button" onClick={onToggle} className="flex h-8 w-full items-center gap-2.5 whitespace-nowrap rounded-lg border-0 bg-transparent px-2.5 text-xs text-white/55 hover:bg-white/6 hover:text-fg">
          <PanelLeft size={15} strokeWidth={1.5} className="flex-none" />
          {open && <><span>Collapse</span><span className="ml-auto"><Kbd>[</Kbd></span></>}
        </button>
      </div>
    </aside>
    </>
  );
}

function connColor(state: string) {
  return state === 'connected' ? TONE.ok : state === 'connecting' ? TONE.warn : state === 'disconnected' ? TONE.bad : TONE.mute;
}

export function ConnDot({ state }: { state: string }) {
  const c = connColor(state);
  return (
    <span className="relative size-2 flex-none">
      <span className="absolute inset-0 animate-pulse-dot rounded-full" style={{ background: c }} />
      {state !== 'idle' && <span className="absolute inset-0 animate-ring rounded-full border" style={{ borderColor: c }} />}
    </span>
  );
}

function HostSwitcher({ onAdd, onEdit }: { onAdd: () => void; onEdit: (id: string) => void }) {
  const { hosts, host, setHostId, status } = useHost();
  const [open, setOpen] = useState(false);
  if (!host) {
    return <Btn variant="outline" size="md" onClick={onAdd}><Plus size={13} />Connect a host</Btn>;
  }
  const label = status.state === 'connected' ? (status.rttMs != null ? ms(status.rttMs) : 'connected') : status.state === 'connecting' ? 'reconnecting…' : status.state === 'disconnected' ? 'offline' : 'idle';
  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button type="button" className="flex h-[34px] flex-none items-center gap-2.5 whitespace-nowrap rounded-lg border border-white/10 bg-card pl-2 pr-2.5 text-fg hover:bg-elev">
          <ConnDot state={status.state} />
          <span className="text-[12.5px] font-semibold">{host.name}</span>
          <span className="font-mono text-[11px] text-muted max-lg:hidden">{host.host}</span>
          <span className="h-3.5 w-px bg-white/10 max-sm:hidden" />
          <span className="font-mono text-[10.5px] tabular-nums max-sm:hidden" style={{ color: connColor(status.state) }}>{label}</span>
          <ChevronsUpDown size={12} className="text-muted" />
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content align="start" sideOffset={6} className="z-40 w-[320px] animate-pop overflow-hidden rounded-xl border border-white/10 bg-card shadow-[0_20px_60px_rgba(0,0,0,.5)]">
          <div className="px-3 pb-1 pt-2.5 text-[10.5px] font-semibold uppercase tracking-[.05em] text-muted">Hosts</div>
          <div className="max-h-[320px] overflow-auto p-1">
            {hosts.map((h) => (
              <div key={h.id} className={cx('group flex items-center gap-2.5 rounded-lg px-2.5 py-2', h.id === host.id ? 'bg-white/6' : 'hover:bg-white/4')}>
                <button type="button" className="flex min-w-0 flex-1 items-center gap-2.5 border-0 bg-transparent p-0 text-left text-fg" onClick={() => { setHostId(h.id); setOpen(false); }}>
                  <span className="size-1.5 flex-none rounded-full" style={{ background: connColor(h.id === host.id ? status.state : h.status.state) }} />
                  <span className="min-w-0 flex-1">
                    <span className="block text-[12.5px] font-medium">{h.name}</span>
                    <span className="block truncate font-mono text-[10.5px] text-muted">{h.username}@{h.host}:{h.port} · {h.mode === 'dokku' ? 'dokku user' : 'shell'}</span>
                  </span>
                  {h.id === host.id && <Check size={13} className="text-ok" />}
                </button>
                <IconBtn title="Edit connection" onClick={() => { setOpen(false); onEdit(h.id); }}><Settings2 size={13} strokeWidth={1.6} /></IconBtn>
              </div>
            ))}
          </div>
          <div className="border-t border-white/8 p-1">
            <button type="button" onClick={() => { setOpen(false); onAdd(); }} className="flex w-full items-center gap-2 rounded-lg border-0 bg-transparent px-2.5 py-2 text-left text-[12.5px] text-fg hover:bg-white/4"><Plus size={13} />Add host</button>
          </div>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}

export function TopBar({ onMenu, onSearch, onTerminal, onDeploy, onDrawer, onAddHost, onEditHost, authRequired, unread }: {
  onMenu: () => void; onSearch: () => void; onTerminal: () => void; onDeploy: () => void; onDrawer: () => void; onAddHost: () => void; onEditHost: (id: string) => void; authRequired: boolean; unread: 'none' | 'ok' | 'fail';
}) {
  const { host } = useHost();
  return (
    <header className="flex h-[52px] min-w-0 flex-none items-center gap-2.5 overflow-hidden whitespace-nowrap border-b border-white/8 bg-bg px-4">
      <button type="button" onClick={onMenu} aria-label="Open navigation" className="grid size-8 flex-none place-items-center rounded-lg border border-white/10 bg-card text-fg hover:bg-elev md:hidden"><Menu2 size={15} strokeWidth={1.6} /></button>
      <HostSwitcher onAdd={onAddHost} onEdit={onEditHost} />
      <button type="button" onClick={onSearch} disabled={!host} className="flex h-[34px] min-w-[120px] flex-[0_1_260px] max-sm:hidden items-center gap-2 overflow-hidden rounded-lg border border-white/8 bg-field px-2.5 text-left text-[12.5px] text-dim hover:border-white/14">
        <Search size={13} strokeWidth={1.6} />
        <span className="min-w-0 flex-1 truncate">Search apps, services, domains…</span>
        <Kbd>⌘K</Kbd>
      </button>
      <div className="min-w-0 flex-1" />
      <Btn variant="outline" size="md" onClick={onTerminal} disabled={!host} title="SSH terminal"><Terminal size={13} strokeWidth={1.6} /><span className="max-lg:hidden">SSH terminal</span></Btn>
      <Btn variant="primary" size="md" onClick={onDeploy} disabled={!host} title="Deploy app"><ArrowUp size={13} strokeWidth={2} /><span className="max-lg:hidden">Deploy app</span></Btn>
      <button type="button" onClick={onDrawer} aria-label="Activity" className="relative grid size-8 flex-none place-items-center rounded-lg border border-white/10 bg-card text-fg hover:bg-elev">
        <Bell size={14} strokeWidth={1.6} />
        {unread !== 'none' && <span className="absolute right-1.5 top-1.5 size-1.5 rounded-full" style={{ background: unread === 'fail' ? TONE.bad : TONE.warn }} />}
      </button>
      <Menu.Root>
        <Menu.Trigger asChild>
          <button type="button" aria-label="Account" className="flex h-8 flex-none items-center gap-2 rounded-lg border border-white/10 bg-card px-1 text-fg hover:bg-elev">
            <span className="grid size-[22px] place-items-center rounded-md bg-info text-[10.5px] font-semibold text-white">{(host?.username ?? 'dk').slice(0, 2).toUpperCase()}</span>
            <ChevronDown size={12} className="mr-1 text-muted" />
          </button>
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Content align="end" sideOffset={6} className="z-40 min-w-[200px] animate-pop rounded-xl border border-white/10 bg-card p-1 shadow-[0_20px_60px_rgba(0,0,0,.5)]">
            {host && <div className="px-2.5 py-2 font-mono text-[10.5px] text-muted">{host.username}@{host.host}</div>}
            <MenuItem onSelect={() => navigate({ view: 'server' })}><KeyRound size={13} />SSH keys & plugins</MenuItem>
            <MenuItem onSelect={() => host && onEditHost(host.id)}><Settings2 size={13} />Edit connection</MenuItem>
            <MenuItem onSelect={onAddHost}><Plus size={13} />Add host</MenuItem>
            {authRequired && <>
              <Menu.Separator className="my-1 h-px bg-white/8" />
              <MenuItem onSelect={() => api.logout().then(() => location.reload())}><LogOut size={13} />Sign out</MenuItem>
            </>}
          </Menu.Content>
        </Menu.Portal>
      </Menu.Root>
    </header>
  );
}

function MenuItem({ children, onSelect }: { children: ReactNode; onSelect: () => void }) {
  return <Menu.Item onSelect={onSelect} className="flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-2 text-[12.5px] text-fg outline-none data-[highlighted]:bg-white/6">{children}</Menu.Item>;
}

export function ConnectionAlert() {
  const { host, status, reconnect } = useHost();
  if (!host || status.state === 'connected' || status.state === 'idle') return null;
  const connecting = status.state === 'connecting';
  const title = connecting ? 'Connecting…' : 'Host unreachable.';
  const body = connecting ? `Opening an SSH session to ${host.username}@${host.host}:${host.port}.` : status.error ?? `Could not reach ${host.host}:${host.port}.`;
  return (
    <div className="flex flex-none animate-rise items-center gap-3 border-b px-4 py-2.5" style={{ background: 'rgba(245,158,11,.12)', borderColor: 'rgba(245,158,11,.26)', color: TONE.warn }}>
      <TriangleAlert size={15} strokeWidth={1.7} />
      <div className="min-w-0 flex-1 truncate"><span className="font-semibold">{title}</span> <span style={{ color: 'rgba(245,158,11,.8)' }}>{body}</span></div>
      {!connecting && <button type="button" onClick={reconnect} className="h-[26px] rounded-[7px] border border-warn/40 bg-transparent px-2.5 text-xs font-medium text-warn hover:bg-warn/12">Retry now</button>}
    </div>
  );
}

export function ActivityDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { host } = useHost();
  const q = useQuery({ queryKey: ['activity', host?.id], queryFn: () => api.activity(host!.id), enabled: !!host && open, refetchInterval: open ? 10_000 : false });
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);
  if (!open) return null;
  return (
    <>
      <div className="fixed inset-0 z-40 bg-bg/40" onClick={onClose} />
      <aside className="fixed bottom-0 right-0 top-0 z-[41] flex w-[360px] max-w-full animate-rise flex-col border-l border-white/10 bg-field shadow-[-20px_0_60px_rgba(0,0,0,.4)]" aria-label="Activity">
        <div className="flex items-center justify-between border-b border-white/8 px-4 py-3.5">
          <span className="text-[13.5px] font-semibold">Activity</span>
          <IconBtn title="Close" onClick={onClose}><X size={13} strokeWidth={1.8} /></IconBtn>
        </div>
        <div className="flex-1 overflow-auto">
          {q.data?.length === 0 && <div className="p-6 text-center text-xs text-muted">No changes made from this console yet. Commands you run here appear in this list.</div>}
          {q.data?.map((a) => (
            <div key={a.id} className="flex gap-3 border-b border-white/6 px-4 py-3">
              <span className="mt-1.5 size-1.5 flex-none rounded-full" style={{ background: a.ok ? TONE.ok : TONE.bad }} />
              <div className="min-w-0 flex-1">
                <div className="break-words font-mono text-[11.5px] leading-[1.45]">{a.command}</div>
                {!a.ok && a.stderr && <div className="mt-1 line-clamp-2 font-mono text-[10.5px] text-bad/90">{a.stderr.trim().split('\n').pop()}</div>}
                <div className="mt-[3px] font-mono text-[10.5px] text-muted">{ago(a.ts)} · {a.ok ? 'ok' : `exit ${a.code}`} · {ms(a.durationMs)}</div>
              </div>
            </div>
          ))}
        </div>
      </aside>
    </>
  );
}
