import { ArrowUp, X } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Btn, Card, CardHead, Cmd, Empty, Field, Grid2, IconBtn, Input, KV, Radio, Skeleton, cx } from '../../components/ui';
import { useReport } from '../../lib/dokku';
import { useAction } from '../../lib/runner';

const BUILDERS: [string, string][] = [
  ['', 'Auto-detect. Uses the Dockerfile when present, otherwise Heroku buildpacks.'],
  ['herokuish', 'Heroku buildpacks via herokuish. Default when no Dockerfile is present.'],
  ['pack', 'Cloud Native Buildpacks (pack CLI). Modern successor to herokuish.'],
  ['dockerfile', 'Build from the Dockerfile in the repository.'],
  ['nixpacks', 'Language auto-detection with Nix-based reproducible images.'],
  ['railpack', "Railway's Railpack builder. Fast, layered images (Dokku 0.36+)."],
  ['lambda', 'Package for AWS Lambda instead of a long-running container.'],
  ['null', 'Skip building. Deploy a pre-built image via git:from-image.'],
];

export function BuildTab({ app }: { app: string }) {
  const builder = useReport('builder', app);
  const bp = useReport('buildpacks', app);
  const df = useReport('builder-dockerfile', app);
  const { busy, act, run } = useAction();
  const [newBp, setNewBp] = useState('');
  const [bpIndex, setBpIndex] = useState('');
  const [dfPath, setDfPath] = useState('');
  const [buildDir, setBuildDir] = useState('');

  const selected = builder.data?.['builder selected'] ?? '';
  const computed = builder.data?.['builder computed selected'] || builder.data?.['builder detected'] || '';
  const effective = selected || computed;
  const buildpacks = (bp.data?.['buildpacks list'] ?? '').split(/[,\s]+/).filter(Boolean);
  useEffect(() => { if (df.data) setDfPath(df.data['builder dockerfile dockerfile path'] || ''); }, [df.data]);
  useEffect(() => { if (builder.data) setBuildDir(builder.data['builder build dir'] || ''); }, [builder.data]);

  const showBuildpacks = !effective || effective === 'herokuish' || effective === 'pack';
  const move = async (i: number) => {
    // Swap i-1 and i using 1-based --index replacement.
    const a = buildpacks[i - 1], b = buildpacks[i];
    const r = await run(['buildpacks:set', '--index', String(i), app, b], { title: 'Reorder buildpacks' });
    if (r?.code === 0) await run(['buildpacks:set', '--index', String(i + 1), app, a], { title: 'Reorder buildpacks' });
  };

  return (
    <>
      <Card>
        <CardHead title="Builder" right={<>auto-detected: <span className="font-mono text-soft">{builder.data?.['builder detected'] || computed || '—'}</span></>} />
        {builder.isLoading ? <div className="p-4"><Skeleton className="h-20 w-full" /></div> : (
          <div className="grid gap-2.5 px-4 py-3.5 [grid-template-columns:repeat(auto-fill,minmax(180px,1fr))]">
            {BUILDERS.map(([id, desc]) => {
              const on = selected === id;
              return (
                <button key={id || 'auto'} type="button" disabled={busy === 'builder'} onClick={() => !on && act('builder', id ? ['builder:set', app, 'selected', id] : ['builder:set', app, 'selected'], { title: `Builder → ${id || 'auto'}` })}
                  className={cx('flex flex-col gap-1.5 rounded-[10px] border p-3 text-left text-fg transition-colors hover:border-white/22', on ? 'border-white/18 bg-white/4' : 'border-white/8 bg-transparent')}>
                  <div className="flex items-center justify-between"><span className="font-mono text-xs font-medium">{id || 'auto'}</span><Radio on={on} /></div>
                  <span className="text-[11.5px] leading-[1.45] text-muted">{desc}</span>
                </button>
              );
            })}
          </div>
        )}
        <Cmd>$ dokku builder:set {app} selected {selected || '(unset → auto)'}</Cmd>
      </Card>

      <Grid2>
        {showBuildpacks && (
          <Card>
            <CardHead title="Buildpacks" right={<Btn disabled={!buildpacks.length} loading={busy === 'clear'} onClick={() => act('clear', ['buildpacks:clear', app])}>Clear (auto-detect)</Btn>} />
            {bp.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
            {bp.data && buildpacks.length === 0 && <Empty>No buildpacks pinned. The builder will auto-detect from the repository.</Empty>}
            {buildpacks.map((url, i) => (
              <div key={url + i} className="grid items-center gap-2.5 border-t border-white/6 px-4 py-2.5" style={{ gridTemplateColumns: '28px 1fr auto' }}>
                <span className="font-mono text-[11px] text-muted">{String(i + 1).padStart(2, '0')}</span>
                <span className="truncate font-mono text-[11.5px]">{url}</span>
                <div className="flex gap-1">
                  <IconBtn title="Move up" disabled={i === 0} onClick={() => move(i)}><ArrowUp size={13} /></IconBtn>
                  <IconBtn title="Remove" danger onClick={() => run(['buildpacks:remove', app, url])}><X size={13} /></IconBtn>
                </div>
              </div>
            ))}
            <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '1fr 64px auto' }}>
              <Input value={newBp} onChange={(e) => setNewBp(e.target.value)} placeholder="https://github.com/heroku/heroku-buildpack-nodejs.git  or  heroku/nodejs" />
              <Input value={bpIndex} onChange={(e) => setBpIndex(e.target.value.replace(/\D/g, ''))} placeholder="index" title="Optional 1-based position" />
              <Btn disabled={!newBp.trim()} loading={busy === 'addbp'} onClick={async () => { const r = await act('addbp', ['buildpacks:add', ...(bpIndex ? ['--index', bpIndex] : []), app, newBp.trim()]); if (r?.code === 0) { setNewBp(''); setBpIndex(''); } }}>Add</Btn>
            </div>
            <Cmd>$ dokku buildpacks:add {bpIndex ? `--index ${bpIndex} ` : ''}{app} {newBp.trim() || '<url>'}  ·  buildpacks:remove  ·  buildpacks:set</Cmd>
          </Card>
        )}

        {(effective === 'dockerfile' || !effective) && (
          <Card>
            <CardHead title="Dockerfile" />
            <div className="flex flex-col gap-3 px-4 py-3.5">
              <Field label="Dockerfile path" hint={`Effective: ${df.data?.['builder dockerfile computed dockerfile path'] ?? 'Dockerfile'}`}>
                <div className="flex gap-1.5">
                  <Input className="flex-1" value={dfPath} onChange={(e) => setDfPath(e.target.value)} placeholder="Dockerfile" />
                  <Btn loading={busy === 'df'} onClick={() => act('df', dfPath.trim() ? ['builder-dockerfile:set', app, 'dockerfile-path', dfPath.trim()] : ['builder-dockerfile:set', app, 'dockerfile-path'])}>Save</Btn>
                </div>
              </Field>
            </div>
            <Cmd>$ dokku builder-dockerfile:set {app} dockerfile-path {dfPath || 'Dockerfile'}</Cmd>
          </Card>
        )}

        <Card>
          <CardHead title="Build environment" />
          <div className="flex flex-col gap-3 px-4 py-3.5">
            <Field label="Build directory" hint="Subdirectory of the repository to build (monorepos). Empty = repository root.">
              <div className="flex gap-1.5">
                <Input className="flex-1" value={buildDir} onChange={(e) => setBuildDir(e.target.value)} placeholder="/" />
                <Btn loading={busy === 'bd'} onClick={() => act('bd', buildDir.trim() ? ['builder:set', app, 'build-dir', buildDir.trim()] : ['builder:set', app, 'build-dir'])}>Save</Btn>
              </div>
            </Field>
            <div>
              <KV k="Selected builder" v={selected || 'auto'} />
              <KV k="Computed builder" v={computed || '—'} />
              <KV k="Build stack" v={bp.data?.['buildpacks computed stack'] || '—'} />
              <KV k="Computed build dir" v={builder.data?.['builder computed build dir'] || '/'} />
            </div>
          </div>
          <Cmd>$ dokku builder:report {app}  ·  builder:set {app} build-dir &lt;dir&gt;</Cmd>
        </Card>
      </Grid2>
    </>
  );
}
