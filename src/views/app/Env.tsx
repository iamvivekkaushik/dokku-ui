import { Eye, EyeOff, Lock, X } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Btn, Card, CopyBtn, cx, Empty, IconBtn, Input, Modal, Pre, Seg, Skeleton, Switch, Textarea, THead } from '../../components/ui';
import { useDokku } from '../../lib/dokku';
import { download, pickFile, readFile } from '../../lib/format';
import { b64, isSecretKey, parseEnvFile } from '../../lib/parse';
import { useAction } from '../../lib/runner';

const HIDDEN = new Set(['DOKKU_APP_TYPE', 'DOKKU_PROXY_PORT', 'DOKKU_PROXY_SSL_PORT', 'GIT_REV', 'DOKKU_APP_RESTORE', 'DOKKU_DOCKERFILE_START_CMD']);

export function EnvTab({ app }: { app: string }) {
  const { busy, wrap, run } = useAction();
  const env = useDokku(['config:export', '--format', 'json', app], (r) => {
    try { return JSON.parse(r.stdout.trim() || '{}') as Record<string, string>; } catch { return {}; }
  });
  const [revealed, setRevealed] = useState<Record<string, boolean>>({});
  const [revealAll, setRevealAll] = useState(false);
  const [keysOnly, setKeysOnly] = useState(false);
  const [showSystem, setShowSystem] = useState(false);
  const [restart, setRestart] = useState(true);
  const [pending, setPending] = useState<Record<string, string>>({});
  const [removed, setRemoved] = useState<string[]>([]);
  const [nk, setNk] = useState('');
  const [nv, setNv] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [exportFmt, setExportFmt] = useState<'env' | 'json' | 'shell'>('env');
  const [importText, setImportText] = useState<string | null>(null);

  const rows = useMemo(() => {
    const merged = { ...(env.data ?? {}), ...pending };
    return Object.keys(merged).filter((k) => !removed.includes(k) && (showSystem || !HIDDEN.has(k))).sort().map((k) => ({
      key: k, value: merged[k], secret: isSecretKey(k), isNew: !(k in (env.data ?? {})), changed: k in (env.data ?? {}) && k in pending && env.data?.[k] !== pending[k],
    }));
  }, [env.data, pending, removed, showSystem]);
  const dirty = Object.keys(pending).length > 0 || removed.length > 0;

  const flag = restart ? [] : ['--no-restart'];
  const save = async () => {
    // Values go base64-encoded so newlines, quotes and shell metacharacters survive intact.
    if (Object.keys(pending).length) {
      const r = await run(['config:set', '--encoded', ...flag, app, ...Object.entries(pending).map(([k, v]) => `${k}=${b64(v)}`)], { title: `Set ${Object.keys(pending).length} vars` });
      if (r?.code !== 0) return;
    }
    if (removed.length) {
      const r = await run(['config:unset', ...flag, app, ...removed], { title: `Unset ${removed.length} vars` });
      if (r?.code !== 0) return;
    }
    setPending({}); setRemoved([]);
  };
  const addVar = () => {
    const k = nk.trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) return;
    setPending((p) => ({ ...p, [k]: nv }));
    setRemoved((r) => r.filter((x) => x !== k));
    setNk(''); setNv('');
  };
  const exportText = () => {
    const data = Object.fromEntries(rows.map((r) => [r.key, r.value]));
    if (exportFmt === 'json') return JSON.stringify(data, null, 2);
    const q = (v: string) => (/^[\w./:@-]*$/.test(v) ? v : `'${v.replace(/'/g, `'\\''`)}'`);
    return Object.entries(data).map(([k, v]) => (exportFmt === 'shell' ? `export ${k}=${q(v)}` : `${k}=${q(v)}`)).join('\n') + '\n';
  };
  const doImport = async () => {
    const f = await pickFile('.env,text/plain');
    if (f) setImportText(await readFile(f));
  };
  const applyImport = (replace: boolean) => {
    const pairs = parseEnvFile(importText ?? '');
    setPending((p) => ({ ...p, ...Object.fromEntries(pairs) }));
    if (replace) setRemoved(Object.keys(env.data ?? {}).filter((k) => !HIDDEN.has(k) && !pairs.some(([k2]) => k2 === k)));
    setImportText(null);
  };

  return (
    <Card>
      <div className="flex flex-wrap items-center gap-2 border-b border-white/8 px-4 py-3">
        <span className="flex-1 text-[13.5px] font-semibold">Config vars <span className="font-mono text-[10.5px] font-normal text-muted">{rows.length}</span></span>
        <Btn onClick={doImport}>Import .env</Btn>
        <div className="flex items-center">
          <Btn className="rounded-r-none" onClick={() => download(`${app}.${exportFmt === 'json' ? 'json' : 'env'}`, exportText())}>Export</Btn>
          <Seg size="sm" mono value={exportFmt} onChange={setExportFmt} options={['env', 'json', 'shell']} className="rounded-l-none border border-l-0 border-white/10 bg-elev" />
        </div>
        <Btn onClick={() => setRevealAll(!revealAll)}>{revealAll ? 'Hide values' : 'Reveal all'}</Btn>
        <Btn className={cx(keysOnly && 'bg-elev2')} onClick={() => setKeysOnly(!keysOnly)}>{keysOnly ? 'Show values' : 'Keys only'}</Btn>
        <Btn className={cx(showSystem && 'bg-elev2')} onClick={() => setShowSystem(!showSystem)} title="Show DOKKU_* and GIT_REV">System</Btn>
      </div>
      <THead cols="240px 1fr 90px"><span>key</span><span>value</span><span /></THead>
      {env.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
      {env.data && rows.length === 0 && <Empty>No config vars set. Add one below or import a .env file.</Empty>}
      {rows.map((r) => {
        const shown = !r.secret || revealAll || revealed[r.key];
        return (
          <div key={r.key} className={cx('grid items-center gap-3 border-t border-white/6 px-4 py-2 hover:bg-white/3', (r.isNew || r.changed) && 'bg-info/6')} style={{ gridTemplateColumns: '240px 1fr 90px' }}>
            <span className="flex min-w-0 items-center gap-2 font-mono text-xs">
              {r.secret && <Lock size={11} strokeWidth={1.7} className="flex-none text-muted" />}
              <span className="truncate">{r.key}</span>
              {r.isNew && <span className="rounded bg-info/20 px-1 font-sans text-[9.5px] uppercase text-info">new</span>}
              {r.changed && <span className="rounded bg-info/20 px-1 font-sans text-[9.5px] uppercase text-info">edited</span>}
            </span>
            <button type="button" onClick={() => setEditing(r.key)} title="Edit value" className={cx('truncate border-0 bg-transparent p-0 text-left font-mono text-xs hover:underline', shown ? 'text-fg' : 'tracking-[.1em] text-dim')}>
              {keysOnly ? '' : shown ? (r.value || <span className="italic text-dim">empty</span>) : '••••••••••••••••'}
            </button>
            <span className="flex justify-end gap-1">
              {r.secret && !keysOnly && <IconBtn title={shown ? 'Hide' : 'Reveal'} onClick={() => setRevealed((x) => ({ ...x, [r.key]: !x[r.key] }))}>{shown ? <EyeOff size={13} strokeWidth={1.6} /> : <Eye size={13} strokeWidth={1.6} />}</IconBtn>}
              <CopyBtn text={r.value} />
              <IconBtn title="Delete" danger onClick={() => { setRemoved((x) => [...x, r.key]); setPending(({ [r.key]: _, ...rest }) => rest); }}><X size={13} strokeWidth={1.6} /></IconBtn>
            </span>
          </div>
        );
      })}
      {removed.length > 0 && <div className="border-t border-white/6 bg-bad/6 px-4 py-2 font-mono text-[11px] text-bad">will unset: {removed.join(' ')} <button type="button" className="ml-2 border-0 bg-transparent p-0 text-muted underline" onClick={() => setRemoved([])}>undo</button></div>}
      <div className="grid items-center gap-3 border-t border-white/8 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '240px 1fr 90px' }}>
        <Input value={nk} onChange={(e) => setNk(e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, '_'))} placeholder="NEW_KEY" onKeyDown={(e) => e.key === 'Enter' && addVar()} />
        <Input value={nv} onChange={(e) => setNv(e.target.value)} placeholder="value" onKeyDown={(e) => e.key === 'Enter' && addVar()} />
        <Btn className="h-[30px]" disabled={!nk.trim()} onClick={addVar}>Add</Btn>
      </div>
      <div className="flex flex-wrap items-center gap-3 border-t border-white/8 px-4 py-3">
        <label className="flex items-center gap-2 text-[12.5px]"><Switch checked={restart} onChange={setRestart} label="Restart app on save" />Restart app on save</label>
        <span className="min-w-0 flex-1 font-mono text-[11px] text-muted [overflow-wrap:anywhere]">$ dokku config:set --encoded {restart ? '' : '--no-restart '}{app} KEY=…  ·  config:unset {restart ? '' : '--no-restart '}{app} KEY</span>
        {dirty && <Btn onClick={() => { setPending({}); setRemoved([]); }}>Discard</Btn>}
        <Btn variant="primary" size="md" disabled={!dirty} loading={busy === 'save'} onClick={() => wrap('save', save)}>Save changes</Btn>
      </div>

      {editing && (
        <EditValue k={editing} value={pending[editing] ?? env.data?.[editing] ?? ''} onClose={() => setEditing(null)} onSave={(v) => { setPending((p) => ({ ...p, [editing]: v })); setEditing(null); }} />
      )}
      {importText !== null && (
        <Modal open onOpenChange={(v) => !v && setImportText(null)} title="Import .env" width={560}
          footer={<><Btn size="md" onClick={() => setImportText(null)}>Cancel</Btn><Btn size="md" onClick={() => applyImport(true)}>Replace all</Btn><Btn variant="primary" size="md" onClick={() => applyImport(false)}>Merge</Btn></>}>
          <Textarea className="h-64 w-full" value={importText} onChange={(e) => setImportText(e.target.value)} spellCheck={false} />
          <div className="text-xs text-muted">{parseEnvFile(importText).length} variables parsed. Nothing is sent until you press Save changes.</div>
        </Modal>
      )}
    </Card>
  );
}

function EditValue({ k, value, onClose, onSave }: { k: string; value: string; onClose: () => void; onSave: (v: string) => void }) {
  const [v, setV] = useState(value);
  return (
    <Modal open onOpenChange={(x) => !x && onClose()} title={<span className="font-mono">{k}</span>} width={560}
      footer={<><Btn size="md" onClick={onClose}>Cancel</Btn><Btn variant="primary" size="md" onClick={() => onSave(v)}>Apply</Btn></>}>
      <Textarea className="h-40 w-full" value={v} onChange={(e) => setV(e.target.value)} spellCheck={false} autoFocus />
      <Pre>Multi-line values are supported; they are sent base64-encoded with <span className="text-fg">config:set --encoded</span>.</Pre>
    </Modal>
  );
}
