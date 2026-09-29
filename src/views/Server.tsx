import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { StreamOutput, useStreamRun } from '../components/StreamPane';
import { Alert, Badge, Btn, Card, CardHead, Cmd, Dot, Empty, Field, Input, KV, Modal, Page, PageHead, Pre, Skeleton, Textarea } from '../components/ui';
import { api } from '../lib/api';
import { useDokku, useDokkuBatch } from '../lib/dokku';
import { duration, pickFile, readFile } from '../lib/format';
import { useCurrentHost } from '../lib/host';
import { parsePlugins, parseReports, parseSshKeys, words, type Report } from '../lib/parse';
import { navigate, useTitle } from '../lib/router';
import { useAction } from '../lib/runner';
import { useUi } from '../lib/uictx';
import { useSystem } from './Dashboard';

const PUBKEY = /^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( .*)?$/;

/** Compares dotted versions; true when `latest` is newer than `current`. */
function newer(latest: string | null | undefined, current: string | null | undefined): boolean {
  if (!latest || !current) return false;
  const a = latest.replace(/^v/, '').split('.').map(Number);
  const b = current.replace(/^v/, '').split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  return false;
}

export function ServerView() {
  const host = useCurrentHost();
  useTitle('Server & SSH');
  const ui = useUi();
  const qc = useQueryClient();
  const { busy, act } = useAction();
  const sys = useSystem();
  const latest = useQuery({ queryKey: ['dokku-latest'], queryFn: api.latestDokku, staleTime: 6 * 3600_000 });
  const keys = useDokku(['ssh-keys:list', '--format', 'json'], (r) => parseSshKeys(r.stdout), { allowFail: true });
  const plugins = useDokku(['plugin:list'], (r) => parsePlugins(r.stdout));
  const globals = useDokkuBatch('globals', [['domains:report', '--global'], ['proxy:report'], ['scheduler:report'], ['registry:report'], ['config:export', '--global', '--format', 'json'], ['git:report']], ([dom, proxy, sched, reg, cfg, git]) => {
    const first = (text: string): Report => Object.values(parseReports(text))[0] ?? {};
    let env: Record<string, string> = {};
    try { env = JSON.parse(cfg.stdout.trim() || '{}'); } catch { /* keep empty */ }
    return { domains: first(dom.stdout), proxy: first(proxy.stdout), sched: first(sched.stdout), registry: first(reg.stdout), git: first(git.stdout), env };
  });

  const root = host.mode === 'shell';
  const needsRoot = root ? undefined : 'Needs root — connect as root or a sudo user';
  const [addKey, setAddKey] = useState(false);
  const [login, setLogin] = useState(false);
  const [upgrade, setUpgrade] = useState(false);
  const [pluginUrl, setPluginUrl] = useState('');
  const [showCore, setShowCore] = useState(false);
  const [globalDomain, setGlobalDomain] = useState('');
  const curGlobal = words(globals.data?.domains['domains global vhosts']).join(' ');
  useEffect(() => setGlobalDomain(curGlobal), [curGlobal]);

  const third = (plugins.data ?? []).filter((p) => !p.core);
  const core = (plugins.data ?? []).filter((p) => p.core);
  const upgradable = newer(latest.data?.version, sys.data?.dokku);
  const registries = root ? (sys.data?.registries ?? '').split('\n').filter(Boolean) : words(globals.data?.registry['registry computed auth servers'] ?? globals.data?.registry['registry global auth servers']);
  const installer = sys.data?.installer;
  const pluginName = (url: string) => /([\w-]+?)(?:\.git)?$/.exec(url.trim())?.[1]?.replace(/^dokku-/, '') ?? '';

  return (
    <Page>
      <PageHead eyebrow={host.name} title="Server & SSH settings" />
      {!root && <Alert tone="info" title="Connected as the dokku user.">SSH keys, plugin installs, upgrades, host metrics and the web terminal need root. <button type="button" className="border-0 bg-transparent p-0 text-info underline" onClick={() => ui.openConnect(host.id)}>Edit the connection</button> to use root or a sudo user.</Alert>}

      <div className="grid items-start gap-4 [grid-template-columns:minmax(0,1.4fr)_minmax(0,1fr)] max-lg:[grid-template-columns:1fr]">
        <Card>
          <CardHead title="Authorized SSH keys" right={<Btn disabled={!root} title={needsRoot} onClick={() => setAddKey(true)}>+ Add key</Btn>} />
          {keys.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {keys.data && keys.data.length === 0 && <Empty>No deploy keys registered. Add one so developers can <span className="font-mono">git push</span>.</Empty>}
          {keys.data?.map((k) => (
            <div key={k.fingerprint + k.name} className="grid items-center gap-4 border-t border-white/6 px-4 py-[11px]" style={{ gridTemplateColumns: '1fr auto' }}>
              <div className="min-w-0">
                <div className="text-[12.5px] font-medium">{k.name}</div>
                <div className="mt-0.5 truncate font-mono text-[10.5px] text-muted">{k.fingerprint}{k.publicKey ? ` · ${k.publicKey.split(' ')[0]}${k.publicKey.split(' ')[2] ? ` · ${k.publicKey.split(' ')[2]}` : ''}` : ''}</div>
              </div>
              <Btn variant="dangerGhost" size="xs" disabled={!root} title={needsRoot} loading={busy === `rm-${k.name}`}
                onClick={() => act(`rm-${k.name}`, ['ssh-keys:remove', k.name], { confirm: { title: `Revoke ${k.name}?`, body: 'Anyone using this key loses git push and dokku SSH access immediately. If this console connects as the dokku user with this key, it will be locked out too.', confirmLabel: 'Revoke key', danger: true } })}>Revoke</Btn>
            </div>
          ))}
          <Cmd>$ dokku ssh-keys:list  ·  ssh-keys:add &lt;name&gt; &lt; key.pub  ·  ssh-keys:remove &lt;name&gt;</Cmd>
        </Card>

        <Card className="flex flex-col gap-2.5 p-4">
          <div className="text-[13.5px] font-semibold">System</div>
          {sys.isLoading ? <Skeleton className="h-32 w-full" /> : (
            <div>
              <KV k="Dokku" v={sys.data?.dokku ?? '—'} />
              {sys.data?.docker && <KV k="Docker" v={sys.data.docker} />}
              {sys.data?.os && <KV k="OS" v={`${sys.data.os}${sys.data.arch ? ` · ${sys.data.arch}` : ''}`} />}
              {sys.data?.kernel && <KV k="Kernel" v={sys.data.kernel} />}
              {sys.data?.uptime && <KV k="Uptime" v={duration(Number(String(sys.data.uptime).split(' ')[0]))} />}
              <KV k="Proxy" v={globals.data?.proxy['proxy global type'] || 'nginx'} />
              <KV k="Scheduler" v={globals.data?.sched['scheduler global selected'] || 'docker-local'} />
              <KV k="Plugins" v={plugins.data ? `${third.length} installed · ${core.length} core` : '—'} />
              <KV k="Connection" v={`${host.username}@${host.host}:${host.port}`} />
              <KV k="Host key" v={<span title={host.hostKey}>{host.hostKey ? `${host.hostKey.slice(0, 22)}…` : 'not pinned'}</span>} />
            </div>
          )}
          <Btn className="mt-1 h-[30px]" onClick={() => ui.openConnect(host.id)}>Edit connection</Btn>
        </Card>
      </div>

      <div className="grid items-start gap-4 [grid-template-columns:minmax(0,1.4fr)_minmax(0,1fr)] max-lg:[grid-template-columns:1fr]">
        <Card>
          <CardHead title="Installation" right={upgradable ? <Badge tone="warn" mono dot={false}>upgrade available · {latest.data?.version}</Badge> : sys.data?.dokku ? <Badge tone="ok" mono dot={false}>up to date</Badge> : undefined} />
          <div className="grid items-center gap-4 border-t border-white/6 px-4 py-3" style={{ gridTemplateColumns: '1fr auto' }}>
            <div className="min-w-0"><div className="text-[12.5px]">Upgrade Dokku on {host.name}</div><div className="mt-[3px] font-mono text-[10.5px] text-muted [overflow-wrap:anywhere]">{sys.data?.dokku ?? '?'}{upgradable ? ` → ${latest.data?.version?.replace(/^v/, '')}` : ''} · apt-get install dokku · plugin:install-dependencies --core</div></div>
            <Btn disabled={!root} title={needsRoot} onClick={() => setUpgrade(true)}>Review upgrade</Btn>
          </div>
          <div className="grid items-center gap-4 border-t border-white/6 px-4 py-3" style={{ gridTemplateColumns: '1fr auto' }}>
            <div className="min-w-0"><div className="text-[12.5px]">Install Dokku on a new host</div><div className="mt-[3px] font-mono text-[10.5px] text-muted [overflow-wrap:anywhere]">bootstrap.sh · DOKKU_TAG · debconf options · ssh-keys:add · domains:set-global</div></div>
            <Btn onClick={() => navigate({ view: 'install' })}>Open installer</Btn>
          </div>
          {root && (
            <div className="grid items-center gap-4 border-t border-white/6 px-4 py-3" style={{ gridTemplateColumns: '1fr auto' }}>
              <div className="min-w-0"><div className="text-[12.5px]">Web installer service</div><div className="mt-[3px] font-mono text-[10.5px] text-muted [overflow-wrap:anywhere]">dokku-installer.service · public SSH-key form until disabled</div></div>
              <Dot tone={installer === 'enabled' ? 'warn' : 'ok'}>{installer === 'enabled' ? 'enabled' : installer === 'disabled' ? 'disabled' : 'not present'}</Dot>
            </div>
          )}
        </Card>

        <Card className="flex flex-col gap-2.5 p-4">
          <div className="text-[13.5px] font-semibold">Global configuration</div>
          <Field label="Global domain(s)" hint="Apps without custom domains are served at <app>.<global domain>.">
            <div className="flex gap-1.5">
              <Input className="flex-1" value={globalDomain} onChange={(e) => setGlobalDomain(e.target.value)} placeholder="apps.example.com" />
              <Btn disabled={globalDomain.trim() === curGlobal || !/^[\w.* -]+$/.test(globalDomain.trim())} loading={busy === 'gd'} onClick={() => act('gd', ['domains:set-global', ...globalDomain.trim().split(/\s+/)])}>Save</Btn>
            </div>
          </Field>
          {globals.isLoading ? <Skeleton className="h-20 w-full" /> : (
            <div>
              <KV k="Vhost deployments" v={globals.data?.domains['domains global enabled'] === 'true' ? 'enabled' : 'disabled'} />
              <KV k="Default deploy branch" v={globals.data?.git['git global deploy branch'] || 'master'} />
              <KV k="Default registry" v={globals.data?.registry['registry global server'] || 'docker hub'} />
              <KV k="Global env vars" v={Object.keys(globals.data?.env ?? {}).length} />
            </div>
          )}
          <div className="font-mono text-[10.5px] text-muted">$ dokku domains:set-global {globalDomain.trim() || '<domain>'}</div>
        </Card>
      </div>

      <div className="grid items-start gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,380px),1fr))]">
        <Card>
          <CardHead title="Plugins" right={<Btn disabled={!root} title={needsRoot} loading={busy === 'upd-all'} onClick={() => act('upd-all', ['plugin:update'], { title: 'Update all plugins', timeoutMs: 30 * 60_000, confirm: { title: 'Update all plugins?', body: 'Pulls the latest revision of every third-party plugin and re-runs their install hooks.', confirmLabel: 'Update all' } })}>Update all</Btn>} />
          {plugins.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {plugins.data && third.length === 0 && <Empty>No third-party plugins. Datastores, Let's Encrypt and others are installed from a git URL below.</Empty>}
          {(showCore ? [...third, ...core] : third).map((p) => (
            <div key={p.name} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
              <div className="min-w-0"><div className="font-mono text-xs">{p.name}</div><div className="mt-0.5 truncate font-mono text-[10.5px] text-muted">{p.description}</div></div>
              <span className="font-mono text-[10.5px]" style={{ color: p.enabled ? '#8a8a90' : '#f59e0b' }}>{p.version}{p.enabled ? '' : ' · disabled'}</span>
              {p.core ? <span className="px-2 text-[11px] text-dim">core</span> : (
                <div className="flex gap-1">
                  <Btn disabled={!root} title={needsRoot} loading={busy === `upd-${p.name}`} onClick={() => act(`upd-${p.name}`, ['plugin:update', p.name], { timeoutMs: 15 * 60_000 })}>Update</Btn>
                  <Btn disabled={!root} title={needsRoot} loading={busy === `tog-${p.name}`} onClick={() => act(`tog-${p.name}`, [p.enabled ? 'plugin:disable' : 'plugin:enable', p.name])}>{p.enabled ? 'Disable' : 'Enable'}</Btn>
                  <Btn variant="dangerGhost" disabled={!root} title={needsRoot} loading={busy === `rm-${p.name}`} onClick={() => act(`rm-${p.name}`, ['plugin:uninstall', p.name], { confirm: { title: `Uninstall ${p.name}?`, body: 'Commands provided by this plugin stop working. Existing service data is left on disk.', confirmLabel: 'Uninstall', danger: true, typeToConfirm: p.name } })}>Remove</Btn>
                </div>
              )}
            </div>
          ))}
          {core.length > 0 && <button type="button" onClick={() => setShowCore(!showCore)} className="w-full border-0 border-t border-white/6 bg-transparent px-4 py-2 text-left text-[11.5px] text-muted hover:text-fg">{showCore ? 'Hide' : 'Show'} {core.length} core plugins</button>}
          <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '1fr auto' }}>
            <Input value={pluginUrl} onChange={(e) => setPluginUrl(e.target.value)} placeholder="https://github.com/dokku/dokku-letsencrypt.git" disabled={!root} />
            <Btn disabled={!root || !/^https:\/\/\S+$/.test(pluginUrl.trim())} title={needsRoot} loading={busy === 'plug'}
              onClick={() => act('plug', ['plugin:install', pluginUrl.trim()], { title: `Install ${pluginName(pluginUrl)}`, timeoutMs: 15 * 60_000, confirm: { title: `Install ${pluginName(pluginUrl)}?`, body: <>Plugins run as root on the host. Only install from sources you trust.<br /><span className="font-mono text-soft">{pluginUrl.trim()}</span></>, confirmLabel: 'Install plugin' } }).then((r) => r?.code === 0 && setPluginUrl(''))}>Install plugin</Btn>
          </div>
          <Cmd>$ dokku plugin:list  ·  plugin:install &lt;git-url&gt;  ·  plugin:update [&lt;plugin&gt;]  ·  requires root</Cmd>
        </Card>

        <Card>
          <CardHead title="Registry credentials" right={<Btn onClick={() => setLogin(true)}>+ Login</Btn>} />
          {registries.length === 0 && <Empty>{root || globals.data?.registry['registry computed auth servers'] !== undefined ? 'Not logged in to any registry. Public images work without credentials.' : 'Logged-in registries cannot be listed as the dokku user on this Dokku version. Logging in still works.'}</Empty>}
          {registries.map((server) => (
            <div key={server} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
              <div className="min-w-0 truncate font-mono text-xs">{server}</div>
              <Dot tone="ok">authenticated</Dot>
              <Btn variant="dangerGhost" loading={busy === `lo-${server}`} onClick={() => act(`lo-${server}`, ['registry:logout', server]).then(() => qc.invalidateQueries({ queryKey: ['dokku', host.id, 'system'] }))}>Log out</Btn>
            </div>
          ))}
          <Cmd>$ dokku registry:login --password-stdin &lt;server&gt; &lt;user&gt;  ·  password is piped over SSH, never stored by the console</Cmd>
        </Card>
      </div>

      {addKey && <AddKeyDialog onClose={() => setAddKey(false)} />}
      {login && <RegistryLoginDialog onClose={() => { setLogin(false); qc.invalidateQueries({ queryKey: ['dokku', host.id, 'system'] }); }} />}
      {upgrade && <UpgradeDialog current={sys.data?.dokku ?? null} latest={latest.data?.version ?? null} onClose={() => { setUpgrade(false); qc.invalidateQueries({ queryKey: ['dokku', host.id] }); }} />}
    </Page>
  );
}

function AddKeyDialog({ onClose }: { onClose: () => void }) {
  const { busy, act } = useAction();
  const [name, setName] = useState('');
  const [key, setKey] = useState('');
  const valid = /^[\w.@-]{1,64}$/.test(name) && PUBKEY.test(key.trim());
  const load = async () => {
    const f = await pickFile('.pub,text/plain');
    if (!f) return;
    const text = (await readFile(f)).trim();
    setKey(text);
    if (!name) setName((text.split(' ')[2] ?? f.name.replace(/\.pub$/, '')).replace(/[^\w.@-]/g, '-'));
  };
  return (
    <Modal open onOpenChange={(v) => !v && onClose()} title="Add SSH key" subtitle="Grants git push and dokku command access to the holder of the private key." width={520}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" disabled={!valid} loading={busy === 'add'} onClick={() => act('add', ['ssh-keys:add', name], { stdin: key.trim() + '\n', title: `Add key ${name}` }).then((r) => r?.code === 0 && onClose())}>Add key</Btn></>}>
      <Field label="Key name"><Input h="md" autoFocus value={name} onChange={(e) => setName(e.target.value.replace(/[^\w.@-]/g, '-'))} placeholder="alice-laptop" /></Field>
      <Field label={<span className="flex items-center justify-between">Public key<Btn size="xs" onClick={load}>Choose .pub file</Btn></span>} hint={key && !PUBKEY.test(key.trim()) ? <span className="text-bad">This does not look like an OpenSSH public key. Never paste a private key here.</span> : 'One line, starting with ssh-ed25519, ssh-rsa or ecdsa-sha2-…'}>
        <Textarea className="w-full" value={key} onChange={(e) => setKey(e.target.value)} placeholder="ssh-ed25519 AAAA… user@host" spellCheck={false} />
      </Field>
      <Pre>$ dokku ssh-keys:add {name || '<name>'} &lt; key.pub</Pre>
    </Modal>
  );
}

function RegistryLoginDialog({ onClose }: { onClose: () => void }) {
  const { busy, act } = useAction();
  const [f, setF] = useState({ server: 'ghcr.io', user: '', password: '' });
  const valid = /^[\w.:/-]+$/.test(f.server) && /^\S+$/.test(f.user) && f.password.length > 0;
  return (
    <Modal open onOpenChange={(v) => !v && onClose()} title="Log in to a registry" subtitle="Docker Hub, GHCR, ECR or any private registry." width={460}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" disabled={!valid} loading={busy === 'login'}
        onClick={() => act('login', ['registry:login', '--password-stdin', f.server, f.user], { stdin: f.password, title: `registry:login ${f.server}` }).then((r) => r?.code === 0 && onClose())}>Log in</Btn></>}>
      <Field label="Server"><Input h="md" value={f.server} onChange={(e) => setF({ ...f, server: e.target.value.trim() })} placeholder="docker.io" /></Field>
      <div className="grid grid-cols-2 gap-2.5">
        <Field label="Username"><Input h="md" value={f.user} onChange={(e) => setF({ ...f, user: e.target.value.trim() })} autoComplete="off" /></Field>
        <Field label="Password or token"><Input h="md" type="password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} autoComplete="new-password" /></Field>
      </div>
      <div className="text-[11px] leading-normal text-dim">The password is written to the command's stdin over the SSH channel. It does not appear in the process list, the activity log or the console's storage; Docker stores the resulting token on the host.</div>
      <Pre>$ dokku registry:login --password-stdin {f.server || '<server>'} {f.user || '<user>'}</Pre>
    </Modal>
  );
}

function UpgradeDialog({ current, latest, onClose }: { current: string | null; latest: string | null; onClose: () => void }) {
  const host = useCurrentHost();
  const { state, lines, start, kill } = useStreamRun(`upgrade:${host.id}`);
  return (
    <Modal open onOpenChange={(v) => !v && state !== 'running' && onClose()} title="Upgrade Dokku" subtitle={`${current ?? '?'} → ${latest?.replace(/^v/, '') ?? 'latest packaged version'} on ${host.name}`} width={720}
      footer={<>
        {state === 'running' ? <Btn size="md" onClick={kill}>Cancel</Btn> : <Btn size="md" onClick={onClose}>Close</Btn>}
        {state !== 'done' && <Btn variant="primary" size="md" loading={state === 'running'} onClick={() => start({ hostId: host.id, kind: 'upgrade' })}>{state === 'failed' ? 'Retry upgrade' : 'Run upgrade'}</Btn>}
      </>}>
      {state === 'idle' && (
        <>
          <Alert tone="warn" title="Read the release notes first.">Minor versions can include breaking changes and migrations. Apps keep running during the package upgrade, but plan a maintenance window and have a backup. <a href="https://dokku.com/docs/appendices/0.38.0-migration-guide/" target="_blank" rel="noreferrer noopener">Migration guides ↗</a></Alert>
          <Pre>{`$ sudo apt-get update -qq\n$ sudo apt-get -qq -y install --only-upgrade dokku\n$ sudo dokku plugin:install-dependencies --core`}</Pre>
          <div className="text-[11.5px] leading-normal text-muted">Works for apt-based installs (bootstrap.sh and the Debian package). Source installs upgrade with <span className="font-mono">git pull &amp;&amp; sudo make install</span> from the web terminal.</div>
        </>
      )}
      {state !== 'idle' && (
        <div className="flex h-[360px] flex-col overflow-hidden rounded-lg border border-white/8 bg-term">
          <StreamOutput lines={lines} idle="Starting…" />
          <div className="border-t border-white/8 bg-card px-3 py-1.5 font-mono text-[10.5px] text-muted">{state === 'running' ? 'upgrading…' : state === 'done' ? 'upgrade complete' : 'upgrade failed — see output'}</div>
        </div>
      )}
    </Modal>
  );
}
