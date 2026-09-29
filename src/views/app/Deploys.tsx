import { useQuery } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Badge, Btn, Card, CardHead, Checkbox, Cmd, Col, CopyBtn, Empty, Field, Grid2, Input, Modal, Pre, Skeleton, SwitchRow, THead, type Tone } from '../../components/ui';
import { api } from '../../lib/api';
import { notSupported, output, useDokku, useReport } from '../../lib/dokku';
import { ago, ms } from '../../lib/format';
import { useCurrentHost } from '../../lib/host';
import { bool, stripAnsi } from '../../lib/parse';
import { useAction } from '../../lib/runner';
import { gitRemote } from '../Apps';

interface Build { id: string; kind: string; status: string; source: string; started_at: string; finished_at?: string; duration?: string; exit_code?: number | string; display_status?: string }

const statusTone = (s: string): Tone => (/succe|deployed|ok/i.test(s) ? 'ok' : /fail|error/i.test(s) ? 'bad' : /running|build/i.test(s) ? 'info' : 'mute');

export function DeploysTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const git = useReport('git', app);
  const appR = useReport('apps', app);
  const { busy, act, run } = useAction();
  const [branch, setBranch] = useState('');
  const [syncUrl, setSyncUrl] = useState('');
  const [syncRef, setSyncRef] = useState('');
  const [build, setBuild] = useState(true);
  const [image, setImage] = useState('');
  const [outputOf, setOutputOf] = useState<string | null>(null);
  const [unlocking, setUnlocking] = useState(false);
  const deployBranch = git.data?.['git deploy branch'] || git.data?.['git computed deploy branch'] || git.data?.['git global deploy branch'] || 'master';
  useEffect(() => { if (git.data) setBranch(deployBranch); }, [git.data, deployBranch]);
  const locked = bool(appR.data?.['app locked']);
  const keepGit = bool(git.data?.['git keep git dir'] || git.data?.['git computed keep git dir']);
  const remote = gitRemote(host, app);

  const builds = useDokku(['builds:list', app, '--format', 'json'], (r) => {
    if (notSupported(r)) return { supported: false as const, list: [] as Build[] };
    const t = r.stdout.trim();
    let list: Build[] = [];
    try { list = t.startsWith('[') ? JSON.parse(t) : []; } catch { /* keep empty */ }
    return { supported: true as const, list };
  }, { allowFail: true, refetchInterval: 15_000 });
  const activity = useQuery({ queryKey: ['activity', host.id], queryFn: () => api.activity(host.id), enabled: builds.data?.supported === false });
  const deployActs = (activity.data ?? []).filter((a) => a.command.split(' ').includes(app) && /git:(sync|from-image)|ps:(rebuild|restart)|builds:/.test(a.command)).slice(0, 10);

  const unlockStale = async () => {
    setUnlocking(true);
    const r = await run(['git:unlock', app, '--force'], { quietFail: true, title: 'Clear stale lock' });
    // git:unlock was folded into apps:unlock in Dokku 0.34; a real failure stays in the job dock with details.
    if (r && r.code !== 0 && notSupported(r)) await run(['apps:unlock', app], { title: 'Clear stale lock' });
    setUnlocking(false);
  };

  const validRepo = /^(https?:\/\/|git@|ssh:\/\/)\S+$/.test(syncUrl.trim());
  const syncArgs = ['git:sync', ...(build ? ['--build'] : []), app, syncUrl.trim() || '<git-url>', ...(syncRef.trim() ? [syncRef.trim()] : [])];

  return (
    <Grid2>
      <Col>
        <Card>
          <CardHead title="Git" right={<span className="font-mono text-[10.5px]">rev {git.data?.['git sha']?.slice(0, 7) ?? '—'} · {deployBranch}</span>} />
          <div className="flex flex-col gap-3 px-4 py-3.5">
            <Field label="Git remote">
              <div className="flex gap-1.5">
                <div className="flex h-[30px] min-w-0 flex-1 items-center truncate rounded-[7px] border border-white/10 bg-field px-2.5 font-mono text-[11.5px] text-soft">{remote}</div>
                <CopyBtn text={remote} label="Copy" />
              </div>
            </Field>
            <Field label="Deploy branch" hint="Pushes to other branches are stored but not deployed.">
              <div className="flex gap-1.5">
                <Input className="flex-1" value={branch} onChange={(e) => setBranch(e.target.value)} />
                <Btn disabled={!branch.trim() || branch === deployBranch} loading={busy === 'branch'} onClick={() => act('branch', ['git:set', app, 'deploy-branch', branch.trim()])}>Save</Btn>
              </div>
            </Field>
            <div className="border-t border-white/6 pt-3">
              <SwitchRow title="Keep .git directory" desc="Exposes the repository inside the build (git:set keep-git-dir)." checked={keepGit} busy={busy === 'keepgit'}
                onChange={(v) => act('keepgit', ['git:set', app, 'keep-git-dir', String(v)])} />
            </div>
            <SwitchRow title="Deploy lock" desc={locked ? 'Deploys are blocked. Pushes are rejected until unlocked.' : 'Deploys allowed. Lock to reject pushes temporarily.'} checked={locked} busy={busy === 'lock'}
              onChange={(v) => act('lock', [v ? 'apps:lock' : 'apps:unlock', app])} />
            <div className="flex items-center justify-between gap-3">
              <div><div className="text-[12.5px]">Stale git lock</div><div className="mt-0.5 text-[11.5px] text-muted">Clear only if a previous deploy was interrupted.</div></div>
              <Btn loading={unlocking} onClick={unlockStale}>Unlock</Btn>
            </div>
          </div>
          <Cmd>$ dokku git:set {app} deploy-branch {branch || deployBranch}  ·  apps:{locked ? 'unlock' : 'lock'} {app}  ·  git:unlock {app}</Cmd>
        </Card>

        <Card>
          <CardHead title="Sync from repository" right="deploy without a push" />
          <div className="grid grid-cols-[minmax(0,1fr)_120px] gap-2 px-4 py-3.5">
            <Input value={syncUrl} onChange={(e) => setSyncUrl(e.target.value)} placeholder="https://github.com/acme/api-gateway.git" />
            <Input value={syncRef} onChange={(e) => setSyncRef(e.target.value)} placeholder="ref (optional)" />
            <div className="col-span-2"><Checkbox checked={build} onChange={setBuild}>Build after sync (--build)</Checkbox></div>
          </div>
          <Cmd action={<Btn variant="primary" size="md" disabled={!validRepo} loading={busy === 'sync'} onClick={() => act('sync', syncArgs, { title: `Sync ${app}`, timeoutMs: 30 * 60_000 })}>Sync &amp; deploy</Btn>}>$ dokku {syncArgs.join(' ')}</Cmd>
        </Card>

        <Card>
          <CardHead title="Deploy an image" right="git:from-image" />
          <div className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 px-4 py-3.5">
            <Input value={image} onChange={(e) => setImage(e.target.value)} placeholder="ghcr.io/acme/api:1.4.2" />
            <Btn disabled={!/^\S+$/.test(image.trim())} loading={busy === 'image'} onClick={() => act('image', ['git:from-image', app, image.trim()], { title: `Deploy ${image.trim()}`, timeoutMs: 30 * 60_000 })}>Deploy</Btn>
          </div>
          <Cmd>$ dokku git:from-image {app} {image.trim() || '<image>'}  ·  roll back by deploying a previous image tag</Cmd>
        </Card>
      </Col>

      <Card>
        <CardHead title="Builds & releases" right={<>
          {builds.data?.supported && <Btn loading={busy === 'cancel'} onClick={() => act('cancel', ['builds:cancel', app])}>Cancel running</Btn>}
          <Btn loading={busy === 'rebuild'} onClick={() => act('rebuild', ['ps:rebuild', app], { title: `Rebuild ${app}`, timeoutMs: 30 * 60_000 })}>Trigger rebuild</Btn>
        </>} />
        {builds.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
        {builds.data?.supported && (
          <>
            <THead cols="minmax(0,1fr) auto auto"><span>build · source</span><span>status</span><span /></THead>
            {builds.data.list.length === 0 && <Empty>No builds recorded for this app yet.</Empty>}
            {builds.data.list.map((b, i) => (
              <div key={b.id} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5 hover:bg-white/3" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
                <div className="min-w-0">
                  <div className="truncate font-mono text-[11.5px]" style={{ color: i === 0 ? '#ededef' : '#8a8a90' }}>{b.id} · {b.kind}</div>
                  <div className="mt-0.5 font-mono text-[10.5px] text-muted">{b.source || '—'} · {ago(b.started_at)}{b.duration ? ` · ${b.duration}` : ''}</div>
                </div>
                <Badge tone={statusTone(b.display_status || b.status)} mono dot={false}>{b.display_status || b.status}</Badge>
                <Btn onClick={() => setOutputOf(b.id)}>Output</Btn>
              </div>
            ))}
          </>
        )}
        {builds.data && !builds.data.supported && (
          <>
            <div className="border-b border-white/6 px-4 py-2.5 text-[11.5px] leading-normal text-muted">
              Build history (<span className="font-mono">builds:list</span>) needs Dokku 0.38 or newer. Showing deploys started from this console.
            </div>
            {deployActs.length === 0 && <Empty>No deploys from this console yet.</Empty>}
            {deployActs.map((a) => (
              <div key={a.id} className="grid items-center gap-3 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
                <div className="min-w-0">
                  <div className="truncate font-mono text-[11.5px]">{a.command}</div>
                  <div className="mt-0.5 font-mono text-[10.5px] text-muted">{ago(a.ts)} · {ms(a.durationMs)}</div>
                </div>
                <Badge tone={a.ok ? 'ok' : 'bad'} mono dot={false}>{a.ok ? 'deployed' : `exit ${a.code}`}</Badge>
              </div>
            ))}
          </>
        )}
        <Cmd>$ dokku builds:list {app}  ·  builds:output {app} &lt;id&gt;  ·  ps:rebuild {app}</Cmd>
      </Card>
      {outputOf && <BuildOutput app={app} id={outputOf} onClose={() => setOutputOf(null)} />}
    </Grid2>
  );
}

function BuildOutput({ app, id, onClose }: { app: string; id: string; onClose: () => void }) {
  const out = useDokku(['builds:output', app, id], (r) => (r.code === 0 ? stripAnsi(r.stdout) : output(r)), { allowFail: true });
  return (
    <Modal open onOpenChange={(v) => !v && onClose()} title={`Build ${id}`} width={820}>
      {out.isLoading ? <Skeleton className="h-40 w-full" /> : <Pre className="max-h-[60vh] overflow-auto">{out.data || 'No output recorded.'}</Pre>}
    </Modal>
  );
}
