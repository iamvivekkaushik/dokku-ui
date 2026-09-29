import { useEffect, useState } from 'react';
import { Btn, Card, CardHead, Cmd, Col, Field, Grid2, Input, KV, Skeleton, SwitchRow } from '../../components/ui';
import { useReport } from '../../lib/dokku';
import { useCurrentHost } from '../../lib/host';
import { bool } from '../../lib/parse';
import { navigate } from '../../lib/router';
import { useAction } from '../../lib/runner';
import { APP_NAME } from '../../components/ActionDialogs';

export function SettingsTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const { busy, act, wrap, run } = useAction();
  const appR = useReport('apps', app);
  const git = useReport('git', app);
  const reg = useReport('registry', app);
  const [rename, setRename] = useState(app);
  const [reg2, setReg2] = useState({ server: '', repo: '' });
  useEffect(() => { if (reg.data) setReg2({ server: reg.data['registry server'] || '', repo: reg.data['registry image repo'] || '' }); }, [reg.data]);
  const locked = bool(appR.data?.['app locked']);
  const push = bool(reg.data?.['registry computed push on release']);
  const created = appR.data?.['app created at'] ? new Date(Number(appR.data['app created at']) * 1000).toISOString().slice(0, 10) : '—';

  const doRename = async () => {
    const r = await run(['apps:rename', app, rename.trim()], { confirm: { title: `Rename ${app} → ${rename.trim()}?`, body: 'Dokku redeploys the app under the new name and updates the git remote. Domains and config are kept; update your local git remote afterwards.', confirmLabel: 'Rename' }, timeoutMs: 30 * 60_000 });
    if (r?.code === 0) navigate({ view: 'app', app: rename.trim(), tab: 'settings' });
  };
  const destroy = async () => {
    const r = await run(['--force', 'apps:destroy', app], { confirm: { title: `Destroy ${app}?`, body: 'Containers, images, config, domains and linked-service env vars are removed. Persistent storage directories on the host are kept.', confirmLabel: 'Destroy app', danger: true, typeToConfirm: app }, timeoutMs: 10 * 60_000 });
    if (r?.code === 0) navigate({ view: 'apps' });
  };
  const saveRegistry = async () => {
    const cur = reg.data ?? {};
    if (reg2.server !== (cur['registry server'] || '')) { const r = await run(reg2.server ? ['registry:set', app, 'server', reg2.server] : ['registry:set', app, 'server']); if (r?.code !== 0) return; }
    if (reg2.repo !== (cur['registry image repo'] || '')) await run(reg2.repo ? ['registry:set', app, 'image-repo', reg2.repo] : ['registry:set', app, 'image-repo']);
  };

  return (
    <Grid2>
      <Col>
        <Card>
          <CardHead title="General" />
          <div className="flex flex-col gap-3 px-4 py-3.5">
            <Field label="App name" hint="Renaming redeploys the app and updates the git remote. Domains and config are kept.">
              <div className="flex gap-1.5">
                <Input className="flex-1" value={rename} onChange={(e) => setRename(e.target.value.toLowerCase())} />
                <Btn disabled={rename.trim() === app || !APP_NAME.test(rename.trim())} loading={busy === 'rename'} onClick={() => wrap('rename', doRename)}>Rename</Btn>
              </div>
            </Field>
            {appR.isLoading ? <Skeleton className="h-16 w-full" /> : (
              <div>
                <KV k="Created" v={created} />
                <KV k="Deploy source" v={`${appR.data?.['app deploy source'] || 'git push'} · ${git.data?.['git deploy branch'] || git.data?.['git global deploy branch'] || 'master'}`} />
                <KV k="Locked" v={String(locked)} />
                <KV k="Directory" v={appR.data?.['app dir'] || `/home/dokku/${app}`} />
              </div>
            )}
          </div>
          <Cmd>$ dokku apps:rename {app} {rename.trim() || '<new>'}  ·  apps:report {app}</Cmd>
        </Card>

        <Card>
          <CardHead title="Container registry" right="push built images upstream" />
          <div className="flex flex-col gap-3 px-4 py-3.5">
            <SwitchRow title="Push on release" desc="Required for k3s / multi-host schedulers" checked={push} busy={busy === 'push'} onChange={(v) => act('push', ['registry:set', app, 'push-on-release', String(v)])} />
            <div className="grid grid-cols-2 gap-2.5">
              <Field label="Server"><Input value={reg2.server} onChange={(e) => setReg2({ ...reg2, server: e.target.value.trim() })} placeholder={reg.data?.['registry global server'] || 'ghcr.io'} /></Field>
              <Field label="Image repo"><Input value={reg2.repo} onChange={(e) => setReg2({ ...reg2, repo: e.target.value.trim() })} placeholder={reg.data?.['registry computed image repo'] || `dokku/${app}`} /></Field>
            </div>
            <div className="text-[11px] text-dim">Log in to the registry once from <a href="#/server">Server &amp; SSH → Registry credentials</a>. Computed image: <span className="font-mono">{reg.data?.['registry computed server'] || ''}{reg.data?.['registry computed image repo'] || '—'}</span></div>
          </div>
          <Cmd action={<Btn loading={busy === 'reg'} onClick={() => wrap('reg', saveRegistry)}>Save</Btn>}>$ dokku registry:set {app} server {reg2.server || '<server>'}  ·  registry:set {app} image-repo {reg2.repo || '<repo>'}</Cmd>
        </Card>
      </Col>

      <Col>
        <Card>
          <CardHead title="Deploy lock" right={<SwitchRow title="" checked={locked} busy={busy === 'lock'} onChange={(v) => act('lock', [v ? 'apps:lock' : 'apps:unlock', app])} />} />
          <div className="px-4 py-3.5 text-xs leading-normal text-muted">{locked ? 'Deploys are blocked. Pushes are rejected until unlocked.' : 'Deploys allowed. Lock to reject pushes temporarily.'} Useful during maintenance windows or incident response.</div>
          <Cmd>$ dokku apps:{locked ? 'unlock' : 'lock'} {app}  ·  apps:locked {app}</Cmd>
        </Card>

        <Card>
          <CardHead title="Clone" />
          <div className="flex items-center justify-between gap-3 px-4 py-3.5">
            <div className="text-xs leading-normal text-muted">Create a new app with this app's config, domains, ports and settings (<span className="font-mono">apps:clone</span>).</div>
            <Btn onClick={() => navigate({ view: 'apps' })}>Use Create app</Btn>
          </div>
        </Card>

        <Card danger>
          <CardHead danger title="Danger zone" />
          <div className="flex flex-col gap-2.5 px-4 py-3.5">
            <div className="text-xs leading-normal text-muted">Destroying removes containers, images, config, domains and linked services' env vars. Persistent storage on the host is <span className="text-fg">not</span> deleted.</div>
            <Btn variant="danger" className="self-start" loading={busy === 'destroy'} onClick={() => wrap('destroy', destroy)}>Destroy app</Btn>
          </div>
          <Cmd>$ dokku --force apps:destroy {app}</Cmd>
        </Card>
        <div className="text-[10.5px] text-dim">Host: {host.name}</div>
      </Col>
    </Grid2>
  );
}
