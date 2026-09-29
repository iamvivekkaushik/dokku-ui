import { useState } from 'react';
import { Badge, Btn, Card, CardHead, Cmd, cx, Dot, Empty, Field, Input, Modal, Page, PageHead, Pre, Skeleton, SwitchRow, TONE } from '../components/ui';
import { DATASTORES, defOf, useDatastores, type Service } from '../lib/datastores';
import { useApps } from '../lib/dokku';
import { useCurrentHost } from '../lib/host';
import { useTitle } from '../lib/router';
import { useAction } from '../lib/runner';
import { useUi } from '../lib/uictx';

export function Datastores() {
  const host = useCurrentHost();
  useTitle('Datastores');
  const ds = useDatastores();
  const apps = useApps();
  const ui = useUi();
  const { busy, act } = useAction();
  const [lastCmd, setLastCmd] = useState('$ dokku <service>:links <name>');
  const [infoOpen, setInfoOpen] = useState<Record<string, boolean>>({});
  const [expose, setExpose] = useState<Service | null>(null);
  const [backup, setBackup] = useState<Service | null>(null);
  const appNames = apps.data?.apps.map((a) => a.name) ?? [];
  const services = ds.data?.services ?? [];
  const key = (s: Service) => `${s.type}/${s.name}`;
  const anyInstalled = !!ds.data && DATASTORES.some((d) => ds.data.installed.has(d.type));

  const toggleLink = async (s: Service, app: string) => {
    const on = s.links.includes(app);
    const args = [`${s.type}:${on ? 'unlink' : 'link'}`, s.name, app];
    setLastCmd(`$ dokku ${args.join(' ')}`);
    await act(`link-${key(s)}-${app}`, args, on ? { confirm: { title: `Unlink ${s.name} from ${app}?`, body: `Removes ${defOf(s.type)?.envVar ?? 'the connection URL'} from ${app} and restarts it.`, confirmLabel: 'Unlink', danger: true } } : undefined);
  };

  return (
    <Page>
      <PageHead eyebrow="Plugins" title="Datastores" right={<Btn variant="primary" size="md" disabled={!anyInstalled} title={anyInstalled ? undefined : 'Install a datastore plugin first'} onClick={() => ui.openProvision()}>+ Provision service</Btn>} />

      <div className="grid gap-3 [grid-template-columns:repeat(auto-fill,minmax(200px,1fr))]">
        {DATASTORES.map((d) => {
          const plugin = ds.data?.plugins.find((p) => p.name === d.type);
          const inst = !!plugin?.enabled;
          const count = services.filter((s) => s.type === d.type).length;
          return (
            <div key={d.type} className={cx('flex flex-col gap-2.5 rounded-xl border border-white/8 bg-card p-3.5', !inst && !ds.isLoading && 'opacity-60')}>
              <div className="flex items-center justify-between">
                <span className="grid size-7 place-items-center rounded-[7px] font-mono text-[11px] font-medium" style={{ background: d.hue + '1f', color: d.hue }}>{d.glyph}</span>
                <span className="font-mono text-[10px] uppercase tracking-[.04em]" style={{ color: inst ? TONE.ok : '#5f5f66' }}>{ds.isLoading ? '…' : inst ? 'installed' : 'not installed'}</span>
              </div>
              <div><div className="text-[13.5px] font-semibold">{d.name}</div><div className="mt-0.5 font-mono text-[10.5px] text-muted">{inst ? `v${plugin!.version} · ${count} service${count === 1 ? '' : 's'}` : 'dokku plugin:install'}</div></div>
              {inst
                ? <Btn variant="ghost" className="h-[26px] border border-white/10 text-soft" onClick={() => ui.openProvision(d.type)}>Provision</Btn>
                : <Btn variant="ghost" className="h-[26px] border border-white/10 text-soft" loading={busy === `inst-${d.type}`} disabled={host.mode === 'dokku'} title={host.mode === 'dokku' ? 'Plugin installs need root — connect as root or a sudo user' : undefined}
                  onClick={() => act(`inst-${d.type}`, ['plugin:install', d.repo, '--name', d.type], { title: `Install ${d.name} plugin`, timeoutMs: 15 * 60_000 })}>Install plugin</Btn>}
            </div>
          );
        })}
      </div>
      {host.mode === 'dokku' && <div className="text-[11px] text-dim">Connected as the dokku user: installing plugins needs root. Everything else here works.</div>}

      <div className="grid items-start gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr))]">
        <Card>
          <CardHead title="Services" right={<span className="font-mono text-[10.5px]">&lt;service&gt;:list · info · expose · backup · destroy</span>} />
          {ds.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {ds.data && services.length === 0 && <Empty>No services yet. {anyInstalled ? 'Provision one above.' : 'Install a datastore plugin first.'}</Empty>}
          {services.map((s) => {
            const exposed = s.exposed && s.exposed !== '-' && s.exposed !== '';
            const running = /running/i.test(s.status);
            return (
              <div key={key(s)} className="flex flex-col gap-2.5 border-t border-white/6 px-4 py-3">
                <div className="grid items-center gap-3" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
                  <div className="min-w-0">
                    <div className="font-mono text-[12.5px]">{s.name}</div>
                    <div className="mt-0.5 truncate font-mono text-[10.5px] text-muted">{s.version.includes(':') ? s.version : `${s.type}:${s.version || '?'}`} · dokku-{s.type}-{s.name}{s.info['internal ip'] ? ` · ${s.info['internal ip']}` : ''}</div>
                  </div>
                  <Dot tone={running ? 'ok' : /restart|paused|created/i.test(s.status) ? 'warn' : 'mute'}>{s.status}</Dot>
                  <div className="flex gap-1">
                    <Btn onClick={() => setInfoOpen((o) => ({ ...o, [key(s)]: !o[key(s)] }))}>Info</Btn>
                    {running
                      ? <Btn loading={busy === `stop-${key(s)}`} onClick={() => act(`stop-${key(s)}`, [`${s.type}:stop`, s.name], { confirm: { title: `Stop ${s.name}?`, body: 'Linked apps lose their connection until the service is started again.', confirmLabel: 'Stop', danger: true } })}>Stop</Btn>
                      : <Btn loading={busy === `start-${key(s)}`} onClick={() => act(`start-${key(s)}`, [`${s.type}:start`, s.name])}>Start</Btn>}
                    <Btn variant="dangerGhost" loading={busy === `destroy-${key(s)}`} onClick={() => act(`destroy-${key(s)}`, [`${s.type}:destroy`, s.name, '--force'], { confirm: { title: `Destroy ${s.name}?`, body: s.links.length ? `Still linked to ${s.links.join(', ')}. Unlink first, or destroying will fail.` : 'The container and its data directory are deleted permanently.', confirmLabel: 'Destroy', danger: true, typeToConfirm: s.name } })}>Destroy</Btn>
                  </div>
                </div>
                <div className="grid gap-2 [grid-template-columns:repeat(auto-fit,minmax(200px,1fr))]">
                  <div className="flex items-center justify-between gap-2 rounded-lg border border-white/6 bg-white/2 px-2.5 py-2">
                    <div><div className="text-[11.5px]">Expose externally</div><div className="mt-px font-mono text-[10.5px]" style={{ color: exposed ? TONE.warn : '#8a8a90' }}>{exposed ? s.exposed : 'internal network only'}</div></div>
                    <SwitchRow title="" checked={!!exposed} busy={busy === `expose-${key(s)}`} onChange={(v) => (v ? setExpose(s) : act(`expose-${key(s)}`, [`${s.type}:unexpose`, s.name]))} />
                  </div>
                  <div className="flex items-center justify-between gap-2 rounded-lg border border-white/6 bg-white/2 px-2.5 py-2">
                    <div className="min-w-0"><div className="text-[11.5px]">Backups</div><div className="mt-px truncate font-mono text-[10.5px] text-muted">{s.info['backup schedule'] || 'S3-compatible · not scheduled'}</div></div>
                    <Btn size="xs" onClick={() => setBackup(s)}>Back up…</Btn>
                  </div>
                </div>
                {infoOpen[key(s)] && (
                  <Pre>{Object.entries(s.info).map(([k, v]) => `${k.padEnd(22)} ${k === 'dsn' ? v.replace(/:([^:@/]+)@/, ':••••••••@') : v}`).join('\n')}</Pre>
                )}
              </div>
            );
          })}
          <Cmd>{lastCmd}</Cmd>
        </Card>

        <Card>
          <CardHead title="App linkage" right={<span className="font-mono text-[10.5px]">click a cell to link / unlink</span>} />
          {services.length === 0 || appNames.length === 0
            ? <Empty>{services.length === 0 ? 'Provision a service to link it to apps.' : 'Create an app to link services to.'}</Empty>
            : (
              <div className="overflow-auto">
                <div className="grid items-center bg-white/3 px-4 py-2 font-mono text-[10px] uppercase tracking-[.04em] text-muted" style={{ gridTemplateColumns: `120px repeat(${appNames.length}, minmax(80px,1fr))` }}>
                  <span />{appNames.map((n) => <span key={n} className="truncate px-1 text-center" title={n}>{n}</span>)}
                </div>
                {services.map((s) => (
                  <div key={key(s)} className="grid items-center border-t border-white/6 px-4 py-1.5" style={{ gridTemplateColumns: `120px repeat(${appNames.length}, minmax(80px,1fr))` }}>
                    <span className="truncate font-mono text-[11.5px]" title={s.name}>{s.name}</span>
                    {appNames.map((a) => {
                      const on = s.links.includes(a);
                      const b = busy === `link-${key(s)}-${a}`;
                      return (
                        <button key={a} type="button" disabled={b} title={`${s.type}:${on ? 'unlink' : 'link'} ${s.name} ${a}`} onClick={() => toggleLink(s, a)}
                          className="mx-1 grid h-[30px] place-items-center rounded-[7px] border font-mono text-[11px] transition-colors hover:border-white/25"
                          style={{ background: on ? 'rgba(34,197,94,.14)' : 'rgba(255,255,255,.02)', borderColor: on ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.08)', color: TONE.ok }}>
                          {b ? '…' : on ? '●' : ''}
                        </button>
                      );
                    })}
                  </div>
                ))}
              </div>
            )}
          <Cmd>{lastCmd}</Cmd>
        </Card>
      </div>

      {expose && <ExposeDialog s={expose} onClose={() => setExpose(null)} />}
      {backup && <BackupDialog s={backup} onClose={() => setBackup(null)} />}
    </Page>
  );
}

function ExposeDialog({ s, onClose }: { s: Service; onClose: () => void }) {
  const { busy, act } = useAction();
  const def = defOf(s.type);
  const [port, setPort] = useState(String((def?.port ?? 5000) + 10000));
  return (
    <Modal open onOpenChange={(v) => !v && onClose()} title={`Expose ${s.name}`} width={420}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" disabled={!/^\d{2,5}$/.test(port)} loading={busy === 'expose'} onClick={() => act('expose', [`${s.type}:expose`, s.name, port]).then((r) => r?.code === 0 && onClose())}>Expose</Btn></>}>
      <Field label="Host port" hint={`Container port ${def?.port ?? '?'} becomes reachable on every interface of the host. Protect it with a firewall.`}><Input h="md" value={port} onChange={(e) => setPort(e.target.value.replace(/\D/g, ''))} /></Field>
      <Badge tone="warn" dot={false}>opens the database to the internet</Badge>
      <Pre>$ dokku {s.type}:expose {s.name} {port}</Pre>
    </Modal>
  );
}

function BackupDialog({ s, onClose }: { s: Service; onClose: () => void }) {
  const { busy, act, run, wrap } = useAction();
  const [tab, setTab] = useState<'now' | 'auth' | 'schedule'>('now');
  const [bucket, setBucket] = useState(s.info['backup bucket'] || '');
  const [auth, setAuth] = useState({ key: '', secret: '', region: '', endpoint: '' });
  const [cron, setCron] = useState('0 2 * * *');
  const [iam, setIam] = useState(false);
  const authArgs = [`${s.type}:backup-auth`, s.name, auth.key, auth.secret, ...(auth.region || auth.endpoint ? [auth.region || 'us-east-1', 'v4', ...(auth.endpoint ? [auth.endpoint] : [])] : [])];
  return (
    <Modal open onOpenChange={(v) => !v && onClose()} title={`Back up ${s.name}`} width={520}
      footer={<>
        <Btn size="md" onClick={onClose}>Close</Btn>
        {tab === 'now' && <Btn variant="primary" size="md" disabled={!bucket} loading={busy === 'bk'} onClick={() => act('bk', [`${s.type}:backup`, s.name, bucket, ...(iam ? ['--use-iam'] : [])], { timeoutMs: 60 * 60_000 })}>Run backup</Btn>}
        {tab === 'auth' && <Btn variant="primary" size="md" disabled={!auth.key || !auth.secret} loading={busy === 'auth'} onClick={() => act('auth', authArgs, { title: 'Set backup credentials' })}>Save credentials</Btn>}
        {tab === 'schedule' && <><Btn size="md" loading={busy === 'unsched'} onClick={() => act('unsched', [`${s.type}:backup-unschedule`, s.name])}>Remove schedule</Btn><Btn variant="primary" size="md" disabled={!bucket || cron.trim().split(/\s+/).length !== 5} loading={busy === 'sched'} onClick={() => wrap('sched', () => run([`${s.type}:backup-schedule`, s.name, cron.trim(), bucket, ...(iam ? ['--use-iam'] : [])]))}>Schedule</Btn></>}
      </>}>
      <div className="flex gap-0.5 rounded-lg bg-white/5 p-0.5">
        {(['now', 'auth', 'schedule'] as const).map((t) => <button key={t} type="button" onClick={() => setTab(t)} className={cx('h-[26px] flex-1 rounded-md border text-xs font-medium', tab === t ? 'border-white/10 bg-elev2 text-fg' : 'border-transparent text-muted')}>{t === 'now' ? 'Back up now' : t === 'auth' ? 'S3 credentials' : 'Schedule'}</button>)}
      </div>
      {tab !== 'auth' && <Field label="Bucket"><Input h="md" value={bucket} onChange={(e) => setBucket(e.target.value.trim())} placeholder="acme-db-backups" /></Field>}
      {tab === 'auth' && (
        <>
          <div className="grid grid-cols-2 gap-2.5">
            <Field label="Access key ID"><Input h="md" value={auth.key} onChange={(e) => setAuth({ ...auth, key: e.target.value.trim() })} /></Field>
            <Field label="Secret access key"><Input h="md" type="password" value={auth.secret} onChange={(e) => setAuth({ ...auth, secret: e.target.value.trim() })} /></Field>
            <Field label="Region"><Input h="md" value={auth.region} onChange={(e) => setAuth({ ...auth, region: e.target.value.trim() })} placeholder="us-east-1" /></Field>
            <Field label="Endpoint (S3-compatible)"><Input h="md" value={auth.endpoint} onChange={(e) => setAuth({ ...auth, endpoint: e.target.value.trim() })} placeholder="https://s3.example.com" /></Field>
          </div>
          <div className="text-[11px] text-dim">Credentials are passed straight to <span className="font-mono">{s.type}:backup-auth</span> and stored by the plugin on the host; the console does not keep them.</div>
        </>
      )}
      {tab === 'schedule' && <Field label="Cron schedule" hint="Server local time. Requires credentials (or IAM) to be set first."><Input h="md" value={cron} onChange={(e) => setCron(e.target.value)} /></Field>}
      {tab !== 'auth' && <label className="flex items-center gap-2 text-xs text-soft"><input type="checkbox" checked={iam} onChange={(e) => setIam(e.target.checked)} />Use the instance IAM role (--use-iam)</label>}
      <Pre>{tab === 'now' ? `$ dokku ${s.type}:backup ${s.name} ${bucket || '<bucket>'}${iam ? ' --use-iam' : ''}` : tab === 'auth' ? `$ dokku ${s.type}:backup-auth ${s.name} <key-id> <secret>${auth.region || auth.endpoint ? ` ${auth.region || 'us-east-1'} v4${auth.endpoint ? ` ${auth.endpoint}` : ''}` : ''}` : `$ dokku ${s.type}:backup-schedule ${s.name} "${cron}" ${bucket || '<bucket>'}${iam ? ' --use-iam' : ''}`}</Pre>
    </Modal>
  );
}
