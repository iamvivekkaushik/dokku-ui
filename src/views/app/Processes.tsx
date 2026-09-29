import { useEffect, useMemo, useState } from 'react';
import { splitArgs } from '../../components/Terminal';
import { Btn, Card, CardHead, Cmd, Col, Dot, Empty, Grid2, Input, Seg, Select, Skeleton, Stepper } from '../../components/ui';
import { useDokku, useReport } from '../../lib/dokku';
import { cronHuman, parseCron, parseResource, parseScale, procStatuses } from '../../lib/parse';
import { useAction } from '../../lib/runner';
import { useUi } from '../../lib/uictx';

export function ProcessesTab({ app }: { app: string }) {
  const ui = useUi();
  const { busy, act, run } = useAction();
  const ps = useReport('ps', app, { refetchInterval: 15_000 });
  const scaleQ = useDokku(['ps:scale', app], (r) => parseScale(r.stdout));
  const cron = useDokku(['cron:list', app, '--format', 'json'], (r) => parseCron(r.stdout), { allowFail: true });
  const resQ = useReport('resource', app);
  const checks = useReport('checks', app);
  const sched = useReport('scheduler', app);

  const [scale, setScale] = useState<Record<string, number>>({});
  const [newType, setNewType] = useState('');
  useEffect(() => { if (scaleQ.data) setScale(scaleQ.data); }, [scaleQ.data]);
  const dirty = scaleQ.data && Object.entries(scale).some(([k, v]) => scaleQ.data[k] !== v);
  const scaleArgs = ['ps:scale', app, ...Object.entries(scale).map(([k, v]) => `${k}=${v}`)];

  const [oneOff, setOneOff] = useState('');
  const procs = ps.data ? procStatuses(ps.data) : [];
  const restartPolicy = ps.data?.['ps restart policy'] || ps.data?.['ps computed restart policy'] || '';
  const [policy, setPolicy] = useState('');
  useEffect(() => setPolicy(restartPolicy), [restartPolicy]);

  const resources = useMemo(() => parseResource(resQ.data ?? {}), [resQ.data]);
  const [res, setRes] = useState({ cpuLimit: '', memLimit: '', cpuRes: '', memRes: '' });
  useEffect(() => {
    const d = resources._default_ ?? {};
    setRes({ cpuLimit: d['limit-cpu'] ?? '', memLimit: d['limit-memory'] ?? '', cpuRes: d['reserve-cpu'] ?? '', memRes: d['reserve-memory'] ?? '' });
  }, [resources]);
  const limitArgs = ['resource:limit', ...(res.cpuLimit ? ['--cpu', res.cpuLimit] : []), ...(res.memLimit ? ['--memory', res.memLimit] : []), app];
  const reserveArgs = ['resource:reserve', ...(res.cpuRes ? ['--cpu', res.cpuRes] : []), ...(res.memRes ? ['--memory', res.memRes] : []), app];
  const applyResources = async () => {
    if (limitArgs.length > 2) { const r = await run(limitArgs); if (r?.code !== 0) return; }
    if (reserveArgs.length > 2) await run(reserveArgs);
  };
  const clearResources = async () => {
    const r = await run(['resource:limit-clear', app], { confirm: { title: 'Clear resource limits?', body: 'Removes all CPU and memory limits and reservations for this app. Takes effect on the next deploy or restart.', confirmLabel: 'Clear' } });
    if (r?.code === 0) await run(['resource:reserve-clear', app]);
  };
  const perType = Object.entries(resources).filter(([k]) => k !== '_default_');

  const list = (v?: string) => (v && v !== 'none' ? v.split(/[,\s]+/).filter(Boolean) : []);
  const disabled = list(checks.data?.['checks disabled list']);
  const skipped = list(checks.data?.['checks skipped list']);
  const types = Object.keys(scaleQ.data ?? {});
  const checkState = (t: string) => (disabled.includes(t) || disabled.includes('_all_') ? 'disabled' : skipped.includes(t) || skipped.includes('_all_') ? 'skipped' : 'enabled');

  const scheduler = sched.data?.['scheduler selected'] || '';
  const schedEff = scheduler || sched.data?.['scheduler computed selected'] || 'docker-local';
  const schedDesc: Record<string, string> = {
    'docker-local': 'Containers run on this host via the Docker daemon. Default.',
    k3s: 'Deploys to the k3s cluster managed by scheduler-k3s. Requires a registry with push-on-release.',
    null: 'No-op scheduler. Builds images but never starts containers.',
  };

  const runOneOff = () => {
    try {
      const words = splitArgs(oneOff.trim());
      if (!words.length) return;
      ui.openTerminal({ kind: 'dokku', args: ['run', app, ...words] }, `dokku run ${app} ${oneOff.trim()}`);
    } catch { /* unterminated quote: ignore */ }
  };

  return (
    <Grid2>
      <Col>
        <Card>
          <CardHead title="Process types" right={<>
            <Btn loading={busy === 'start'} onClick={() => act('start', ['ps:start', app])}>Start</Btn>
            <Btn loading={busy === 'stop'} onClick={() => act('stop', ['ps:stop', app], { confirm: { title: `Stop ${app}?`, body: 'All processes stop until started again.', confirmLabel: 'Stop', danger: true } })}>Stop</Btn>
            <Btn loading={busy === 'restart'} onClick={() => act('restart', ['ps:restart', app])}>Restart</Btn>
            <Btn loading={busy === 'rebuild'} onClick={() => act('rebuild', ['ps:rebuild', app], { timeoutMs: 30 * 60_000 })}>Rebuild</Btn>
          </>} />
          {scaleQ.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {scaleQ.data && Object.keys(scale).length === 0 && <Empty>No process types yet. They come from the Procfile (or Dockerfile CMD) on the first deploy.</Empty>}
          {Object.entries(scale).map(([name, n]) => {
            const running = procs.filter((p) => p.type === name && p.state === 'running').length;
            return (
              <div key={name} className="grid items-center gap-3 border-t border-white/6 px-4 py-3" style={{ gridTemplateColumns: '90px minmax(0,1fr) 120px' }}>
                <span className="font-mono text-[12.5px]">{name}</span>
                <span className="truncate font-mono text-[11px] text-muted">{running} running{scaleQ.data?.[name] !== n ? ` → ${n}` : ''}</span>
                <Stepper value={n} onChange={(v) => setScale((s) => ({ ...s, [name]: v }))} />
              </div>
            );
          })}
          <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '1fr auto' }}>
            <Input value={newType} onChange={(e) => setNewType(e.target.value.replace(/[^\w-]/g, ''))} placeholder="add process type from Procfile (e.g. worker)" />
            <Btn disabled={!newType || newType in scale} onClick={() => { setScale((s) => ({ ...s, [newType]: 1 })); setNewType(''); }}>Add</Btn>
          </div>
          <Cmd action={<Btn variant="primary" size="md" disabled={!dirty} loading={busy === 'scale'} onClick={() => act('scale', scaleArgs, { timeoutMs: 15 * 60_000 })}>Apply scale</Btn>}>
            <span className="text-soft">$ dokku {scaleArgs.join(' ')}</span>
          </Cmd>
        </Card>

        <Card>
          <CardHead title="One-off command" right="ephemeral container · dokku run" />
          <div className="grid gap-2 px-4 py-3" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
            <Input value={oneOff} onChange={(e) => setOneOff(e.target.value)} placeholder="npm run migrate" onKeyDown={(e) => e.key === 'Enter' && runOneOff()} />
            <Btn disabled={!oneOff.trim()} onClick={runOneOff}>Run</Btn>
            <Btn disabled={!oneOff.trim()} title="Run in the background (--detach)" loading={busy === 'detach'} onClick={() => { try { act('detach', ['run', '--detach', app, ...splitArgs(oneOff.trim())]); } catch { /* ignore */ } }}>Detached</Btn>
          </div>
          <div className="flex flex-wrap items-center gap-2 px-4 pb-3">
            <span className="text-xs text-muted">Enter a running container:</span>
            {procs.filter((p) => p.state === 'running').map((p) => (
              <Btn key={`${p.type}.${p.index}`} className="font-mono text-[11px]" onClick={() => ui.openTerminal({ kind: 'dokku', args: ['enter', app, p.type, String(p.index)] }, `dokku enter ${app} ${p.type} ${p.index}`)}>{p.type}.{p.index}</Btn>
            ))}
            {!procs.some((p) => p.state === 'running') && <span className="text-xs text-dim">none running</span>}
          </div>
          <Cmd>$ dokku run {app} {oneOff.trim() || '<cmd>'}  ·  $ dokku enter {app} web 1</Cmd>
        </Card>

        <Card>
          <CardHead title="Scheduled tasks" right={<span className="font-mono text-[10.5px]">from app.json · cron:list</span>} />
          {cron.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {cron.data && cron.data.length === 0 && <Empty>No cron entries. Add a <span className="font-mono">cron</span> block to app.json and redeploy.</Empty>}
          {cron.data?.map((c) => (
            <div key={c.id} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
              <div className="min-w-0">
                <div className="truncate font-mono text-[11.5px]">{c.command}</div>
                <div className="mt-0.5 truncate font-mono text-[10.5px] text-muted">{c.schedule} · {cronHuman(c.schedule)} · id {c.id.slice(0, 10)}…</div>
              </div>
              <Btn loading={busy === `cron-${c.id}`} onClick={() => act(`cron-${c.id}`, ['cron:run', app, c.id], { title: `cron:run ${c.command}`, timeoutMs: 60 * 60_000 })}>Run now</Btn>
            </div>
          ))}
          <Cmd>$ dokku cron:run {app} &lt;cron-id&gt;</Cmd>
        </Card>
      </Col>

      <Col>
        <Card>
          <CardHead title="Resources" right="default for all process types" />
          <div className="flex flex-col gap-3.5 px-4 py-3.5">
            {([['CPU', 'cpuLimit', 'cpuRes', '1.0'], ['Memory', 'memLimit', 'memRes', '512m']] as const).map(([label, l, r, ph]) => (
              <div key={label} className="grid items-center gap-2.5" style={{ gridTemplateColumns: '90px 1fr 1fr' }}>
                <span className="text-[12.5px]">{label}</span>
                <label className="flex flex-col gap-1 font-mono text-[10.5px] uppercase tracking-[.04em] text-muted">limit<Input value={res[l]} onChange={(e) => setRes({ ...res, [l]: e.target.value.trim() })} placeholder={ph} /></label>
                <label className="flex flex-col gap-1 font-mono text-[10.5px] uppercase tracking-[.04em] text-muted">reserve<Input value={res[r]} onChange={(e) => setRes({ ...res, [r]: e.target.value.trim() })} placeholder="—" /></label>
              </div>
            ))}
            {perType.length > 0 && (
              <div className="rounded-lg border border-white/6 bg-white/2 px-3 py-2 font-mono text-[10.5px] leading-relaxed text-muted">
                {perType.map(([t, v]) => <div key={t}>{t}: {Object.entries(v).map(([k, x]) => `${k} ${x}`).join(' · ')}</div>)}
              </div>
            )}
            <div className="text-[11.5px] leading-normal text-muted">Limits cap usage; reservations guarantee a minimum. Memory accepts <span className="font-mono">512m</span>, <span className="font-mono">2g</span>; CPU is a share of vCPUs. Applied on the next deploy or restart.</div>
          </div>
          <Cmd action={<div className="flex gap-1.5"><Btn onClick={clearResources}>Clear</Btn><Btn disabled={limitArgs.length <= 2 && reserveArgs.length <= 2} loading={busy === 'res'} onClick={applyResources}>Apply</Btn></div>}>
            $ dokku {limitArgs.join(' ')}<br />$ dokku {reserveArgs.join(' ')}
          </Cmd>
        </Card>

        <Card>
          <CardHead title="Zero-downtime checks" right={<Btn loading={busy === 'checks'} onClick={() => act('checks', ['checks:run', app], { timeoutMs: 10 * 60_000 })}>Run checks</Btn>} />
          {checks.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {types.length === 0 && checks.data && <Empty>No process types yet.</Empty>}
          {types.map((t) => {
            const st = checkState(t);
            return (
              <div key={t} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
                <div className="min-w-0">
                  <div className="font-mono text-[11.5px]">{t}</div>
                  <div className="mt-0.5 font-mono text-[10.5px] text-muted">wait to retire {checks.data?.['checks computed wait to retire'] || '60'}s</div>
                </div>
                <Seg size="sm" mono value={st} onChange={(v) => act(`chk-${t}`, [`checks:${v === 'enabled' ? 'enable' : v === 'disabled' ? 'disable' : 'skip'}`, app, t])} options={['enabled', 'skipped', 'disabled']} />
              </div>
            );
          })}
          <Cmd>$ dokku checks:run {app}  ·  checks:enable|skip|disable {app} &lt;proc&gt;</Cmd>
        </Card>

        <Card>
          <CardHead title="Restart policy & scheduler" />
          <div className="flex flex-col gap-3 px-4 py-3.5">
            <div className="grid items-center gap-2" style={{ gridTemplateColumns: '1fr auto' }}>
              <Select value={policy} onChange={(e) => setPolicy(e.target.value)}>
                {['on-failure:10', 'always', 'unless-stopped', 'no', ...(policy && !['on-failure:10', 'always', 'unless-stopped', 'no'].includes(policy) ? [policy] : [])].map((p) => <option key={p} value={p}>{p}</option>)}
              </Select>
              <Btn disabled={policy === restartPolicy} loading={busy === 'policy'} onClick={() => act('policy', ['ps:set', app, 'restart-policy', policy])}>Save</Btn>
            </div>
            <Seg value={schedEff} onChange={(v) => act('sched', ['scheduler:set', app, 'selected', v])} options={['docker-local', 'k3s', 'null']} />
            <div className="text-[11.5px] leading-normal text-muted">{schedDesc[schedEff] ?? 'Custom scheduler plugin.'}</div>
            {procs.length > 0 && <div className="flex flex-wrap gap-2">{procs.map((p) => <Dot key={`${p.type}${p.index}`} tone={p.state === 'running' ? 'ok' : 'mute'}>{p.type}.{p.index}</Dot>)}</div>}
          </div>
          <Cmd>$ dokku ps:set {app} restart-policy {policy || '<policy>'}  ·  scheduler:set {app} selected {schedEff}</Cmd>
        </Card>
      </Col>
    </Grid2>
  );
}
