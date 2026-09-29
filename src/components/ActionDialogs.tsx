import * as Dialog from '@radix-ui/react-dialog';
import { Box, Database, Globe, Search, Terminal } from 'lucide-react';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { DATASTORES, defOf, useDatastores } from '../lib/datastores';
import { useApps, useReport } from '../lib/dokku';
import { useCurrentHost } from '../lib/host';
import { APP_TABS, navigate, type AppTab, type Route } from '../lib/router';
import { useRunner } from '../lib/runner';
import { useUi } from '../lib/uictx';
import { Btn, Checkbox, CopyBtn, cx, Field, Input, Kbd, Modal, Pre, Seg, Select } from './ui';

export const APP_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;

export function CreateAppDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { run } = useRunner();
  const apps = useApps();
  const [name, setName] = useState('');
  const [cloneFrom, setCloneFrom] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (open) { setName(''); setCloneFrom(''); } }, [open]);
  const valid = APP_NAME.test(name);
  const exists = apps.data?.apps.some((a) => a.name === name);
  const args = cloneFrom ? ['apps:clone', cloneFrom, name] : ['apps:create', name];
  const submit = async () => {
    if (!valid || exists) return;
    setBusy(true);
    const r = await run(args, { title: `Create ${name}` });
    setBusy(false);
    if (r?.code === 0) { onClose(); navigate({ view: 'app', app: name, tab: 'deploys' }); }
  };
  return (
    <Modal open={open} onOpenChange={(v) => !v && onClose()} title="Create app" width={440}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" disabled={!valid || exists} loading={busy} onClick={submit}>Create app</Btn></>}>
      <Field label="App name" hint={exists ? <span className="text-bad">An app with this name already exists.</span> : 'Lowercase letters, digits and dashes. Becomes the git remote and default subdomain.'}>
        <Input h="md" autoFocus value={name} onChange={(e) => setName(e.target.value.toLowerCase())} onKeyDown={(e) => e.key === 'Enter' && submit()} placeholder="api-gateway" />
      </Field>
      <Field label="Clone settings from (optional)" hint="Copies config, domains, ports and other settings with apps:clone.">
        <Select value={cloneFrom} onChange={(e) => setCloneFrom(e.target.value)}>
          <option value="">— start empty —</option>
          {apps.data?.apps.map((a) => <option key={a.name} value={a.name}>{a.name}</option>)}
        </Select>
      </Field>
      <Pre>$ dokku {args.join(' ') || 'apps:create <name>'}</Pre>
    </Modal>
  );
}

type DeployMode = 'push' | 'sync' | 'image';

export function DeployDialog({ open, onClose, initialApp }: { open: boolean; onClose: () => void; initialApp?: string }) {
  const host = useCurrentHost();
  const apps = useApps();
  const { run } = useRunner();
  const [app, setApp] = useState('');
  const [mode, setMode] = useState<DeployMode>('push');
  const [repo, setRepo] = useState('');
  const [ref, setRef] = useState('');
  const [build, setBuild] = useState(true);
  const [image, setImage] = useState('');
  const [branch, setBranch] = useState('main');
  useEffect(() => { if (open) setApp(initialApp ?? apps.data?.apps[0]?.name ?? ''); }, [open, initialApp, apps.data]);

  const git = useReport('git', open && app ? app : null);
  const deployBranch = git.data?.['git deploy branch'] || git.data?.['git computed deploy branch'] || git.data?.['git global deploy branch'] || 'master';
  const remote = host.port === 22 ? `dokku@${host.host}:${app || '<app>'}` : `ssh://dokku@${host.host}:${host.port}/${app || '<app>'}`;
  const syncArgs = ['git:sync', ...(build ? ['--build'] : []), app, repo.trim(), ...(ref.trim() ? [ref.trim()] : [])];
  const imageArgs = ['git:from-image', app, image.trim()];
  const go = async (args: string[]) => {
    onClose();
    const r = await run(args, { title: `Deploy ${app}`, timeoutMs: 30 * 60_000 });
    if (r?.code === 0) navigate({ view: 'app', app, tab: 'overview' });
  };
  return (
    <Modal open={open} onOpenChange={(v) => !v && onClose()} title="Deploy app" subtitle="Push with git, sync from a remote repository, or deploy a pre-built image." width={540}
      footer={<>
        <Btn size="md" onClick={onClose}>Close</Btn>
        {mode === 'sync' && <Btn variant="primary" size="md" disabled={!app || !/^(https?:\/\/|git@|ssh:\/\/)\S+$/.test(repo.trim())} onClick={() => go(syncArgs)}>Sync & deploy</Btn>}
        {mode === 'image' && <Btn variant="primary" size="md" disabled={!app || !/^\S+$/.test(image.trim())} onClick={() => go(imageArgs)}>Deploy image</Btn>}
      </>}>
      <div className="grid grid-cols-[1fr_auto] items-end gap-2.5">
        <Field label="App">
          <Select value={app} onChange={(e) => setApp(e.target.value)}>
            {!apps.data?.apps.length && <option value="">no apps yet</option>}
            {apps.data?.apps.map((a) => <option key={a.name} value={a.name}>{a.name}</option>)}
          </Select>
        </Field>
        <CreateInline />
      </div>
      <Seg value={mode} onChange={setMode} options={[{ value: 'push', label: 'git push' }, { value: 'sync', label: 'Sync repository' }, { value: 'image', label: 'Docker image' }]} />
      {mode === 'push' && (
        <>
          <div className="text-xs leading-normal text-muted">Add the Dokku remote to your local repository and push the deploy branch. Your SSH key must be registered with <span className="font-mono">ssh-keys:add</span>.</div>
          <Field label="Branch to push"><Input value={branch} onChange={(e) => setBranch(e.target.value)} /></Field>
          {[`git remote add dokku ${remote}`, `git push dokku ${branch || 'main'}:${deployBranch}`].map((c) => (
            <div key={c} className="flex items-center gap-2 rounded-lg border border-white/8 bg-term py-1 pl-3 pr-1 font-mono text-[11.5px] text-soft">
              <span className="min-w-0 flex-1 [overflow-wrap:anywhere]">$ {c}</span><CopyBtn text={c} />
            </div>
          ))}
          <div className="text-[11px] text-dim">This app deploys pushes to <span className="font-mono text-soft">{deployBranch}</span>. Change it with <span className="font-mono">git:set {app || '<app>'} deploy-branch</span> in the app’s Deploys tab.</div>
        </>
      )}
      {mode === 'sync' && (
        <>
          <div className="grid grid-cols-[minmax(0,1fr)_130px] gap-2">
            <Field label="Repository URL"><Input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="https://github.com/acme/api-gateway.git" /></Field>
            <Field label="Ref (optional)"><Input value={ref} onChange={(e) => setRef(e.target.value)} placeholder="main / tag / sha" /></Field>
          </div>
          <Checkbox checked={build} onChange={setBuild}>Build after sync (--build)</Checkbox>
          <Pre>$ dokku {syncArgs.filter(Boolean).join(' ')}</Pre>
        </>
      )}
      {mode === 'image' && (
        <>
          <Field label="Image" hint="Any image the host can pull, e.g. from Docker Hub or a registry you logged in to."><Input value={image} onChange={(e) => setImage(e.target.value)} placeholder="ghcr.io/acme/api:1.4.2" /></Field>
          <Pre>$ dokku git:from-image {app || '<app>'} {image || '<image>'}</Pre>
        </>
      )}
    </Modal>
  );
}

function CreateInline() {
  const { openCreateApp } = useUi();
  return <Btn size="sm" className="h-[30px]" onClick={openCreateApp}>+ New app</Btn>;
}

export function ProvisionDialog({ open, onClose, initialType }: { open: boolean; onClose: () => void; initialType?: string }) {
  const ds = useDatastores();
  const apps = useApps();
  const { run } = useRunner();
  const installed = DATASTORES.filter((d) => ds.data?.installed.has(d.type));
  const [type, setType] = useState('postgres');
  const [name, setName] = useState('');
  const [version, setVersion] = useState('');
  const [port, setPort] = useState('');
  const [link, setLink] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!open) return;
    const t = initialType ?? installed[0]?.type ?? 'postgres';
    setType(t); setName(`${t}-${Math.random().toString(36).slice(2, 6)}`); setVersion(defOf(t)?.version ?? ''); setPort(''); setLink([]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, initialType]);
  const def = defOf(type);
  const cmds = [
    [`${type}:create`, name, ...(version.trim() ? ['--image-version', version.trim()] : [])],
    ...(port.trim() ? [[`${type}:expose`, name, port.trim()]] : []),
    ...link.map((a) => [`${type}:link`, name, a]),
  ];
  const valid = /^[a-z0-9][a-z0-9_-]*$/.test(name) && (!port || /^\d{2,5}$/.test(port)) && ds.data?.installed.has(type);
  const submit = async () => {
    setBusy(true);
    for (const c of cmds) {
      const r = await run(c, { title: c[0], timeoutMs: 15 * 60_000 });
      if (r?.code !== 0) break;
    }
    setBusy(false);
    onClose();
  };
  return (
    <Modal open={open} onOpenChange={(v) => !v && onClose()} width={480} title={`Provision ${def?.name ?? type} service`}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" disabled={!valid} loading={busy} onClick={submit}>Create service</Btn></>}>
      {installed.length > 1 && <Seg value={type} onChange={(t) => { setType(t); setVersion(defOf(t)?.version ?? ''); }} options={installed.map((d) => ({ value: d.type, label: d.name }))} />}
      <Field label="Service name"><Input h="md" value={name} onChange={(e) => setName(e.target.value.toLowerCase())} /></Field>
      <div className="grid grid-cols-2 gap-2.5">
        <Field label="Image version" hint="Leave blank for the plugin default."><Input h="md" value={version} onChange={(e) => setVersion(e.target.value)} /></Field>
        <Field label="Expose on host port" hint="Opens it to external traffic."><Input h="md" value={port} onChange={(e) => setPort(e.target.value.replace(/\D/g, ''))} placeholder="none" /></Field>
      </div>
      <Field label={`Link to apps after create (sets ${def?.envVar ?? 'the connection URL'})`}>
        <div className="flex flex-wrap gap-1.5">
          {apps.data?.apps.map((a) => {
            const on = link.includes(a.name);
            return (
              <button key={a.name} type="button" onClick={() => setLink(on ? link.filter((x) => x !== a.name) : [...link, a.name])}
                className={cx('rounded-md border px-2 py-1 font-mono text-[11px]', on ? 'border-ok/35 bg-ok/14 text-ok' : 'border-white/10 bg-transparent text-soft hover:bg-white/6')}>{a.name}</button>
            );
          })}
          {!apps.data?.apps.length && <span className="text-[11px] text-dim">No apps to link.</span>}
        </div>
      </Field>
      <Pre>{cmds.map((c) => `$ dokku ${c.join(' ')}`).join('\n')}</Pre>
    </Modal>
  );
}

// ---------------------------------------------------------------- command palette

interface PaletteItem { id: string; label: string; hint?: string; icon: ReactNode; run: () => void; group: string }

const TAB_LABEL: Record<AppTab, string> = { overview: 'Overview', deploys: 'Deploys', build: 'Build', scale: 'Processes', env: 'Environment', domains: 'Routing', storage: 'Storage', logs: 'Logs', settings: 'Settings' };

export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
  const apps = useApps();
  const ds = useDatastores();
  const ui = useUi();
  const [q, setQ] = useState('');
  const [sel, setSel] = useState(0);
  useEffect(() => { if (open) { setQ(''); setSel(0); } }, [open]);

  const items = useMemo<PaletteItem[]>(() => {
    const go = (r: Route) => () => { onClose(); navigate(r); };
    const act = (f: () => void) => () => { onClose(); f(); };
    const list: PaletteItem[] = [
      { id: 'p-dash', label: 'Dashboard', icon: <Box size={13} />, run: go({ view: 'dash' }), group: 'Pages' },
      { id: 'p-apps', label: 'Apps', icon: <Box size={13} />, run: go({ view: 'apps' }), group: 'Pages' },
      { id: 'p-data', label: 'Datastores', icon: <Database size={13} />, run: go({ view: 'data' }), group: 'Pages' },
      { id: 'p-mon', label: 'Logs & monitoring', icon: <Terminal size={13} />, run: go({ view: 'monitor' }), group: 'Pages' },
      { id: 'p-srv', label: 'Server & SSH', icon: <Terminal size={13} />, run: go({ view: 'server' }), group: 'Pages' },
      { id: 'a-create', label: 'Create app', icon: <Box size={13} />, run: act(ui.openCreateApp), group: 'Actions' },
      { id: 'a-deploy', label: 'Deploy app', icon: <Box size={13} />, run: act(() => ui.openDeploy()), group: 'Actions' },
      { id: 'a-prov', label: 'Provision datastore', icon: <Database size={13} />, run: act(() => ui.openProvision()), group: 'Actions' },
      { id: 'a-term', label: 'Open console', icon: <Terminal size={13} />, run: act(ui.openConsole), group: 'Actions' },
    ];
    for (const a of apps.data?.apps ?? []) {
      list.push({ id: `app-${a.name}`, label: a.name, hint: a.health, icon: <Box size={13} />, run: go({ view: 'app', app: a.name, tab: 'overview' }), group: 'Apps' });
      for (const t of APP_TABS.filter((t) => t !== 'overview')) list.push({ id: `app-${a.name}-${t}`, label: `${a.name} › ${TAB_LABEL[t]}`, icon: <Box size={13} />, run: go({ view: 'app', app: a.name, tab: t }), group: 'App sections' });
      for (const d of a.domains) list.push({ id: `dom-${a.name}-${d}`, label: d, hint: a.name, icon: <Globe size={13} />, run: go({ view: 'app', app: a.name, tab: 'domains' }), group: 'Domains' });
    }
    for (const s of ds.data?.services ?? []) list.push({ id: `svc-${s.type}-${s.name}`, label: s.name, hint: s.type, icon: <Database size={13} />, run: go({ view: 'data' }), group: 'Services' });
    return list;
  }, [apps.data, ds.data, onClose, ui]);

  const filtered = useMemo(() => {
    const t = q.trim().toLowerCase();
    const r = t ? items.filter((i) => `${i.label} ${i.hint ?? ''} ${i.group}`.toLowerCase().includes(t)) : items.filter((i) => i.group !== 'App sections');
    return r.slice(0, 60);
  }, [items, q]);
  useEffect(() => setSel(0), [q]);

  return (
    <Dialog.Root open={open} onOpenChange={(v) => !v && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-bg/60 backdrop-blur-[3px]" />
        <Dialog.Content aria-describedby={undefined} className="fixed left-1/2 top-[12vh] z-50 w-[560px] max-w-[calc(100vw-32px)] -translate-x-1/2 animate-pop overflow-hidden rounded-[14px] border border-white/10 bg-card shadow-[0_20px_60px_rgba(0,0,0,.5)]">
          <Dialog.Title className="sr-only">Search</Dialog.Title>
          <div className="flex items-center gap-2.5 border-b border-white/8 px-4">
            <Search size={14} className="text-muted" />
            <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search apps, services, domains, actions…"
              onKeyDown={(e) => {
                if (e.key === 'ArrowDown') { e.preventDefault(); setSel((s) => Math.min(filtered.length - 1, s + 1)); }
                else if (e.key === 'ArrowUp') { e.preventDefault(); setSel((s) => Math.max(0, s - 1)); }
                else if (e.key === 'Enter') filtered[sel]?.run();
              }}
              className="h-12 flex-1 border-0 bg-transparent text-[13.5px] text-fg focus:shadow-none" />
            <Kbd>esc</Kbd>
          </div>
          <div className="max-h-[50vh] overflow-auto p-1.5" role="listbox">
            {filtered.length === 0 && <div className="p-6 text-center text-xs text-muted">No matches.</div>}
            {filtered.map((it, i) => (
              <button key={it.id} type="button" role="option" aria-selected={i === sel} onMouseMove={() => setSel(i)} onClick={it.run}
                className={cx('flex w-full items-center gap-2.5 rounded-lg border-0 px-3 py-2 text-left text-[12.5px] text-fg', i === sel ? 'bg-white/8' : 'bg-transparent')}>
                <span className="text-muted">{it.icon}</span>
                <span className="min-w-0 flex-1 truncate">{it.label}</span>
                {it.hint && <span className="font-mono text-[10.5px] text-muted">{it.hint}</span>}
                <span className="font-mono text-[10px] uppercase tracking-[.04em] text-dim">{it.group}</span>
              </button>
            ))}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
