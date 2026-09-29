import { HardDrive, X } from 'lucide-react';
import { useState } from 'react';
import { Btn, Card, CardHead, Cmd, Empty, Grid2, IconBtn, Input, Modal, Seg, Select, Skeleton, THead } from '../../components/ui';
import { useDokku, useReport } from '../../lib/dokku';
import { useCurrentHost } from '../../lib/host';
import { parseLines, parseStorage, splitDockerOptions } from '../../lib/parse';
import { useAction } from '../../lib/runner';

type Phase = 'build' | 'deploy' | 'run';

export function StorageTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const { busy, act, wrap, run } = useAction();
  const mounts = useDokku(['storage:list', app, '--format', 'json'], (r) => parseStorage(r.stdout));
  const dopts = useReport('docker-options', app);
  const net = useReport('network', app);
  const networks = useDokku(['network:list'], (r) => parseLines(r.stdout).filter((n) => /^[\w.-]+$/.test(n)));
  const [mountOpen, setMountOpen] = useState(false);
  const [m, setM] = useState({ name: '', host: '', container: '/app/storage', chown: 'herokuish' });
  const [phase, setPhase] = useState<Phase>('deploy');
  const [newOpt, setNewOpt] = useState('');
  const [newNet, setNewNet] = useState('');

  const hostPath = m.host || (m.name ? `/var/lib/dokku/data/storage/${m.name}` : '');
  const mountValid = /^\/\S+$/.test(hostPath) && /^\/\S+$/.test(m.container);
  const doMount = async () => {
    if (!m.host && m.name) {
      // Creates the directory with the right ownership for the build stack.
      const r = await run(['storage:ensure-directory', ...(m.chown !== 'herokuish' ? ['--chown', m.chown] : []), m.name], { title: 'Create storage directory' });
      if (r?.code !== 0) return;
    }
    const r = await run(['storage:mount', app, `${hostPath}:${m.container}`]);
    if (r?.code === 0) { setMountOpen(false); setM({ name: '', host: '', container: '/app/storage', chown: 'herokuish' }); }
  };

  const opts = splitDockerOptions(dopts.data?.[`docker options ${phase}`]);
  const netRows: [keyof typeof netKeys, string, string][] = [['initial-network', 'Initial network', 'Network the container is created on'], ['attach-post-create', 'Attach after create', 'Joined right after the container is created'], ['attach-post-deploy', 'Attach after deploy', 'Joined once the container is running']];
  const netKeys = { 'initial-network': 'network initial network', 'attach-post-create': 'network attach post create', 'attach-post-deploy': 'network attach post deploy' } as const;
  const netChoices = ['', ...(networks.data ?? []).filter((n) => !['none', 'host'].includes(n))];

  return (
    <>
      <Card>
        <CardHead title="Persistent storage" right={<Btn onClick={() => setMountOpen(true)}>+ Mount volume</Btn>} />
        {mounts.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
        {mounts.data && mounts.data.length === 0 && <Empty>No volumes mounted. The container filesystem is ephemeral and reset on each deploy.</Empty>}
        {mounts.data && mounts.data.length > 0 && <THead cols="1fr 1fr 120px 100px"><span>host path</span><span>container path</span><span>options</span><span /></THead>}
        {mounts.data?.map((mt) => (
          <div key={mt.host + mt.container} className="grid items-center gap-4 border-t border-white/6 px-4 py-3" style={{ gridTemplateColumns: '1fr 1fr 120px 100px' }}>
            <span className="flex min-w-0 items-center gap-2 font-mono text-[11.5px]"><HardDrive size={13} strokeWidth={1.6} className="flex-none text-muted" /><span className="truncate">{mt.host}</span></span>
            <span className="truncate font-mono text-[11.5px] text-soft">→ {mt.container}</span>
            <span className="font-mono text-[11px] text-muted">{mt.options || '—'}</span>
            <Btn variant="dangerGhost" size="xs" className="justify-self-end" onClick={() => run(['storage:unmount', app, `${mt.host}:${mt.container}`], { confirm: { title: 'Unmount volume?', body: <>Detaches <span className="font-mono">{mt.container}</span> on the next deploy or restart. Files on the host are kept.</>, confirmLabel: 'Unmount', danger: true } })}>Unmount</Btn>
          </div>
        ))}
        <Cmd>$ dokku storage:mount {app} /var/lib/dokku/data/storage/{app}:/app/storage  ·  storage:unmount  ·  storage:list  ·  <span className="text-dim">restart the app to apply</span></Cmd>
      </Card>

      <Grid2>
        <Card>
          <CardHead title="Docker options" right={<Seg size="sm" value={phase} onChange={setPhase} options={['build', 'deploy', 'run']} />} />
          {dopts.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {dopts.data && opts.length === 0 && <Empty>No extra flags for the {phase} phase.</Empty>}
          {opts.map((flag) => (
            <div key={flag} className="grid items-center gap-3 border-t border-white/6 px-4 py-2" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
              <span className="font-mono text-[11.5px] [overflow-wrap:anywhere]">{flag}</span>
              <IconBtn title="Remove flag" danger onClick={() => run(['docker-options:remove', app, phase, flag])}><X size={13} /></IconBtn>
            </div>
          ))}
          <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '1fr auto' }}>
            <Input value={newOpt} onChange={(e) => setNewOpt(e.target.value)} placeholder="--shm-size=256m" onKeyDown={(e) => e.key === 'Enter' && newOpt.trim().startsWith('-') && act('dopt', ['docker-options:add', app, phase, newOpt.trim()]).then(() => setNewOpt(''))} />
            <Btn disabled={!newOpt.trim().startsWith('-')} loading={busy === 'dopt'} onClick={() => act('dopt', ['docker-options:add', app, phase, newOpt.trim()]).then(() => setNewOpt(''))}>Add flag</Btn>
          </div>
          <Cmd>$ dokku docker-options:add {app} {phase} "{newOpt.trim() || '<flag>'}"  ·  docker-options:remove  ·  docker-options:report</Cmd>
        </Card>

        <Card>
          <CardHead title="Networks" right={
            <div className="flex gap-1.5">
              <Input className="w-[150px]" value={newNet} onChange={(e) => setNewNet(e.target.value.replace(/[^\w.-]/g, ''))} placeholder="new-network" />
              <Btn disabled={!newNet} loading={busy === 'mknet'} onClick={() => act('mknet', ['network:create', newNet]).then(() => setNewNet(''))}>Create</Btn>
            </div>} />
          {net.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {netRows.map(([prop, label, desc]) => {
            const cur = net.data?.[netKeys[prop]] ?? '';
            const computed = net.data?.[`network computed ${prop.replace(/-/g, ' ')}`] ?? '';
            return (
              <div key={prop} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) 180px' }}>
                <div className="min-w-0"><div className="text-[12.5px]">{label}</div><div className="mt-0.5 truncate font-mono text-[10.5px] text-muted">{prop} · {desc}{!cur && computed ? ` · global: ${computed}` : ''}</div></div>
                <Select value={cur} disabled={busy === `net-${prop}`} onChange={(e) => act(`net-${prop}`, e.target.value ? ['network:set', app, prop, e.target.value] : ['network:set', app, prop])}>
                  {netChoices.map((n) => <option key={n} value={n}>{n || '(none)'}</option>)}
                  {cur && !netChoices.includes(cur) && <option value={cur}>{cur}</option>}
                </Select>
              </div>
            );
          })}
          <div className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) 180px' }}>
            <div><div className="text-[12.5px]">Bind all interfaces</div><div className="mt-0.5 font-mono text-[10.5px] text-muted">bind-all-interfaces · publish ports on 0.0.0.0 instead of the docker bridge</div></div>
            <Seg size="sm" mono value={net.data?.['network bind all interfaces'] === 'true' ? 'true' : 'false'} onChange={(v) => act('bind', ['network:set', app, 'bind-all-interfaces', v])} options={['false', 'true']} />
          </div>
          {networks.data && networks.data.length > 0 && <div className="border-t border-white/6 px-4 py-2 font-mono text-[10.5px] text-muted">available: {networks.data.join(' · ')}{host.mode === 'dokku' ? '' : ''}</div>}
          <Cmd>$ dokku network:set {app} attach-post-create &lt;network&gt;  ·  network:create  ·  network:report</Cmd>
        </Card>
      </Grid2>

      <Modal open={mountOpen} onOpenChange={setMountOpen} title="Mount a volume" width={480}
        footer={<><Btn size="md" onClick={() => setMountOpen(false)}>Cancel</Btn><Btn variant="primary" size="md" disabled={!mountValid} loading={busy === 'mount'} onClick={() => wrap('mount', doMount)}>Mount</Btn></>}>
        <div className="grid grid-cols-2 gap-2.5">
          <label className="flex flex-col gap-1 text-xs text-muted">Storage name (managed)<Input value={m.name} onChange={(e) => setM({ ...m, name: e.target.value.replace(/[^\w.-]/g, ''), host: '' })} placeholder={app} /></label>
          <label className="flex flex-col gap-1 text-xs text-muted">Owner<Select value={m.chown} onChange={(e) => setM({ ...m, chown: e.target.value })}>{['herokuish', 'heroku', 'packeto', 'root', 'false'].map((c) => <option key={c}>{c}</option>)}</Select></label>
        </div>
        <label className="flex flex-col gap-1 text-xs text-muted">…or existing host path<Input value={m.host} onChange={(e) => setM({ ...m, host: e.target.value })} placeholder="/srv/data/uploads" /></label>
        <label className="flex flex-col gap-1 text-xs text-muted">Container path<Input value={m.container} onChange={(e) => setM({ ...m, container: e.target.value })} /></label>
        <div className="rounded-lg border border-white/8 bg-term px-3 py-2 font-mono text-[11px] leading-relaxed text-muted">
          {!m.host && m.name && <div>$ dokku storage:ensure-directory {m.chown !== 'herokuish' ? `--chown ${m.chown} ` : ''}{m.name}</div>}
          <div>$ dokku storage:mount {app} {hostPath || '<host-path>'}:{m.container}</div>
        </div>
      </Modal>
    </>
  );
}
