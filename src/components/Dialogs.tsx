import { useQueryClient } from '@tanstack/react-query';
import { Check, ChevronDown, ChevronUp, Terminal, TriangleAlert, X } from 'lucide-react';
import { useEffect, useState, type DragEvent } from 'react';
import type { AuthMethod, HandshakeStep, HostInput } from '../../shared/types';
import { api } from '../lib/api';
import { copy, ms, readFile } from '../lib/format';
import { useHost } from '../lib/host';
import { stripAnsi } from '../lib/parse';
import { navigate } from '../lib/router';
import { remediation, useRunner, type Job } from '../lib/runner';
import { Btn, Field, IconBtn, Input, Modal, Seg, Spinner, Switch, Textarea, TONE } from './ui';

// ---------------------------------------------------------------- connect host

const HANDSHAKE_LABELS = ['ssh connect', 'host key', 'authentication', 'dokku version'];

export function ConnectHostDialog({ open, onClose, editId }: { open: boolean; onClose: () => void; editId: string | null }) {
  const { hosts, setHostId, refreshHosts } = useHost();
  const { confirm } = useRunner();
  const qc = useQueryClient();
  const editing = editId ? hosts.find((h) => h.id === editId) : undefined;
  const blank = { name: '', host: '', port: '22', username: 'dokku', auth: 'key' as AuthMethod, privateKey: '', keyPath: '', passphrase: '', password: '', sudo: false };
  const [f, setF] = useState(blank);
  const [steps, setSteps] = useState<HandshakeStep[]>([]);
  const [testing, setTesting] = useState(false);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setSteps([]); setError(''); setTesting(false);
    setF(editing ? { ...blank, name: editing.name, host: editing.host, port: String(editing.port), username: editing.username, auth: editing.auth, keyPath: editing.keyPath ?? '', sudo: editing.sudo } : blank);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editId]);

  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => { setF((x) => ({ ...x, [k]: v })); setSteps([]); };
  const input = (): HostInput & { id?: string } => ({
    id: editing?.id, name: f.name.trim() || f.host.trim(), host: f.host.trim(), port: Number(f.port) || 22, username: f.username.trim(), auth: f.auth,
    privateKey: f.auth === 'key' ? f.privateKey : undefined, keyPath: f.auth === 'key' ? f.keyPath.trim() : undefined,
    passphrase: f.auth === 'key' ? f.passphrase : undefined, password: f.auth === 'password' ? f.password : undefined, sudo: f.username.trim() !== 'dokku' && f.sudo,
  });

  const test = async () => {
    setTesting(true); setError(''); setSteps([]);
    try {
      await api.testConnection(input(), (s) => setSteps((prev) => [...prev.filter((p) => p.step !== s.step), s].sort((a, b) => a.step - b.step)));
    } catch (err) { setError((err as Error).message); }
    setTesting(false);
  };

  const last = steps[steps.length - 1];
  const sshOk = steps.some((s) => s.step === 2 && s.status === 'ok');
  const dokkuOk = steps.some((s) => s.step === 3 && s.status === 'ok');
  const canSave = !testing && sshOk && (dokkuOk || last?.status === 'warn');
  const hostKey = steps.find((s) => s.hostKey)?.hostKey;

  const save = async (thenInstall = false) => {
    setSaving(true); setError('');
    try {
      const body = { ...input(), hostKey };
      const saved = editing ? await api.updateHost(editing.id, body) : await api.createHost(body);
      refreshHosts();
      setHostId(saved.id);
      qc.invalidateQueries({ queryKey: ['status'] });
      onClose();
      if (thenInstall) navigate({ view: 'install' });
    } catch (err) { setError((err as Error).message); }
    setSaving(false);
  };

  const remove = async () => {
    if (!editing) return;
    if (!(await confirm({ title: `Remove ${editing.name}?`, body: 'This only removes the saved connection from the console. Nothing on the server changes.', confirmLabel: 'Remove host', danger: true }))) return;
    await api.deleteHost(editing.id);
    refreshHosts();
    onClose();
  };

  const onDrop = async (e: DragEvent) => {
    e.preventDefault();
    const file = e.dataTransfer.files?.[0];
    if (file && file.size < 64 * 1024) set('privateKey', await readFile(file));
  };

  const isDokkuUser = f.username.trim() === 'dokku';
  return (
    <Modal open={open} onOpenChange={(v) => !v && onClose()} width={500}
      title={editing ? `Edit ${editing.name}` : 'Connect a Dokku host'}
      subtitle="Credentials are stored only on the console server (data/hosts.json, mode 600) and never sent back to the browser."
      footer={<>
        {editing
          ? <button type="button" onClick={remove} className="mr-auto border-0 bg-transparent p-0 text-xs text-muted hover:text-bad">Remove host</button>
          : <button type="button" onClick={() => (canSave && !dokkuOk ? save(true) : (onClose(), navigate({ view: 'install' })))} className="mr-auto whitespace-nowrap border-0 bg-transparent p-0 text-xs text-muted hover:text-fg">No Dokku on this server? Install it →</button>}
        <Btn size="md" onClick={test} loading={testing} disabled={!f.host.trim() || !f.username.trim()}><Terminal size={12} strokeWidth={1.7} />Test connection</Btn>
        <Btn variant="primary" size="md" disabled={!canSave} loading={saving} onClick={() => save(!dokkuOk && !editing)} title={canSave ? undefined : 'Run a successful connection test first'}>
          {editing ? 'Save changes' : dokkuOk ? 'Save host' : 'Save & install Dokku'}
        </Btn>
      </>}>
      <div className="grid grid-cols-[1fr_110px] gap-2.5">
        <Field label="Hostname or IP"><Input h="md" value={f.host} onChange={(e) => set('host', e.target.value)} placeholder="165.227.14.92" autoFocus /></Field>
        <Field label="SSH port"><Input h="md" value={f.port} onChange={(e) => set('port', e.target.value.replace(/\D/g, ''))} inputMode="numeric" /></Field>
      </div>
      <div className="grid grid-cols-2 gap-2.5">
        <Field label="Display name"><Input h="md" value={f.name} onChange={(e) => set('name', e.target.value)} placeholder={f.host || 'prod-01'} /></Field>
        <Field label="Username"><Input h="md" value={f.username} onChange={(e) => set('username', e.target.value)} /></Field>
      </div>
      <div className="-mt-2 text-[11px] text-dim">
        Use <span className="font-mono">dokku</span> for app commands. Plugin installs, SSH key management, host metrics and the web terminal need <span className="font-mono">root</span> or a sudo user.
      </div>
      {!isDokkuUser && (
        <div className="flex items-center justify-between gap-3 rounded-lg border border-white/8 bg-white/2 px-3 py-2">
          <div><div className="text-[12.5px]">Run dokku with sudo</div><div className="mt-0.5 text-[11px] text-muted">Needs passwordless sudo. Leave off when connecting as root.</div></div>
          <Switch checked={f.sudo} onChange={(v) => set('sudo', v)} label="Run dokku with sudo" />
        </div>
      )}
      <Field label="Authentication">
        <Seg full value={f.auth} onChange={(v) => set('auth', v)} options={[{ value: 'key', label: 'Private key' }, { value: 'password', label: 'Password' }, { value: 'agent', label: 'SSH agent' }]} />
      </Field>
      {f.auth === 'key' && (
        <>
          <div onDragOver={(e) => e.preventDefault()} onDrop={onDrop}>
            <Textarea className="w-full border-dashed border-white/16" value={f.privateKey} onChange={(e) => set('privateKey', e.target.value)} spellCheck={false}
              placeholder={editing?.hasPrivateKey ? 'A key is stored. Paste a new key to replace it.' : '-----BEGIN OPENSSH PRIVATE KEY-----\n…\nPaste key or drop an id_ed25519 file'} />
          </div>
          <div className="grid grid-cols-2 gap-2.5">
            <Field label="…or key path on the console server"><Input value={f.keyPath} onChange={(e) => set('keyPath', e.target.value)} placeholder="~/.ssh/id_ed25519" /></Field>
            <Field label="Key passphrase"><Input type="password" value={f.passphrase} onChange={(e) => set('passphrase', e.target.value)} placeholder={editing?.hasPassphrase ? 'stored' : 'optional'} /></Field>
          </div>
        </>
      )}
      {f.auth === 'password' && <Field label="Password"><Input h="md" type="password" value={f.password} onChange={(e) => set('password', e.target.value)} placeholder={editing?.hasPassword ? 'stored — type to replace' : ''} /></Field>}
      {f.auth === 'agent' && <div className="text-[11.5px] text-muted">Uses the SSH agent at <span className="font-mono">$SSH_AUTH_SOCK</span> of the console server process.</div>}

      {(steps.length > 0 || testing) && (
        <div className="rounded-lg border border-white/8 bg-term px-3.5 py-3 font-mono text-[11.5px] leading-[1.8]">
          {HANDSHAKE_LABELS.map((label, i) => {
            const s = steps.find((x) => x.step === i);
            const color = !s ? '#5f5f66' : s.status === 'fail' ? TONE.bad : s.status === 'warn' ? TONE.warn : s.status === 'running' ? '#ededef' : '#c9c9cc';
            return (
              <div key={i} className="flex items-start gap-2.5" style={{ color }}>
                <span className="mt-[5px] grid size-3 flex-none place-items-center">
                  {!s && <span className="size-1 rounded-full bg-dim" />}
                  {s?.status === 'running' && <Spinner size={10} />}
                  {s?.status === 'ok' && <Check size={12} strokeWidth={2.2} className="text-ok" />}
                  {s?.status === 'fail' && <X size={12} strokeWidth={2.2} />}
                  {s?.status === 'warn' && <TriangleAlert size={11} strokeWidth={2} />}
                </span>
                <span className="min-w-0 [overflow-wrap:anywhere]">{s?.text ?? label}{s?.detail && <span className="block text-[10.5px] text-muted">{s.detail}</span>}</span>
              </div>
            );
          })}
        </div>
      )}
      {error && <div className="text-xs text-bad">{error}</div>}
    </Modal>
  );
}

// ---------------------------------------------------------------- command error

export function CommandErrorDialog() {
  const { failed, setFailed } = useRunner();
  const { host } = useHost();
  if (!failed) return null;
  const text = stripAnsi(failed.output.map((o) => o.text).join(''));
  const full = `$ ssh -p ${host?.port ?? 22} ${failed.hostLabel} -- ${failed.command.replace(/^dokku /, host?.mode === 'dokku' ? '' : 'dokku ')}\n${text}`;
  return (
    <Modal open onOpenChange={(v) => !v && setFailed(null)} width={560} title="Command failed"
      header={
        <div className="flex gap-3 border-b px-5 py-[18px]" style={{ background: 'rgba(239,68,68,.1)', borderColor: 'rgba(239,68,68,.26)' }}>
          <TriangleAlert size={18} strokeWidth={1.7} className="mt-px flex-none text-bad" />
          <div className="min-w-0 flex-1">
            <div className="text-sm font-semibold text-bad">Command failed · {failed.code == null ? 'no exit code' : `exit ${failed.code}`}</div>
            <div className="mt-0.5 text-xs [overflow-wrap:anywhere]" style={{ color: 'rgba(239,68,68,.8)' }}>{failed.command} returned a non-zero status{failed.durationMs ? ` after ${ms(failed.durationMs)}` : ''}</div>
          </div>
          <IconBtn title="Close" onClick={() => setFailed(null)}><X size={13} /></IconBtn>
        </div>
      }
      footer={<>
        <Btn size="md" onClick={() => copy(full)}>Copy output</Btn>
        <Btn size="md" onClick={() => setFailed(null)}>Dismiss</Btn>
        <Btn variant="primary" size="md" onClick={failed.retry}>Retry</Btn>
      </>}>
      <div className="max-h-[340px] overflow-auto whitespace-pre-wrap rounded-lg border border-white/8 bg-term px-3.5 py-3 font-mono text-[11.5px] leading-[1.7] text-soft">
        <div className="text-muted">$ {failed.command}</div>
        {failed.output.map((o, i) => <span key={i} className={o.stream === 'stderr' ? 'text-bad' : undefined}>{stripAnsi(o.text)}</span>)}
      </div>
      <div className="text-[12.5px] leading-normal text-muted">{remediation(text)}</div>
    </Modal>
  );
}

// ---------------------------------------------------------------- confirm

export function ConfirmDialog() {
  const { pendingConfirm: c } = useRunner();
  const [typed, setTyped] = useState('');
  useEffect(() => setTyped(''), [c]);
  if (!c) return null;
  const ok = !c.typeToConfirm || typed === c.typeToConfirm;
  return (
    <Modal open onOpenChange={(v) => !v && c.resolve(false)} width={420} title={c.title}
      footer={<>
        <Btn size="md" onClick={() => c.resolve(false)}>Cancel</Btn>
        <Btn variant={c.danger ? 'danger' : 'primary'} size="md" disabled={!ok} onClick={() => c.resolve(true)} autoFocus={!c.typeToConfirm}>{c.confirmLabel ?? 'Confirm'}</Btn>
      </>}>
      {c.body && <div className="text-[12.5px] leading-normal text-muted">{c.body}</div>}
      {c.typeToConfirm && (
        <Field label={<span>Type <span className="font-mono text-fg">{c.typeToConfirm}</span> to confirm</span>}>
          <Input h="md" autoFocus value={typed} onChange={(e) => setTyped(e.target.value)} placeholder={c.typeToConfirm} onKeyDown={(e) => { if (e.key === 'Enter' && ok) c.resolve(true); }} />
        </Field>
      )}
    </Modal>
  );
}

// ---------------------------------------------------------------- job dock

function JobCard({ job }: { job: Job }) {
  const { dismiss, setFailed } = useRunner();
  const [open, setOpen] = useState(false);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (job.status !== 'running') return;
    const t = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(t);
  }, [job.status]);
  const long = job.status === 'running' && now - job.startedAt > 1500;
  const expanded = open || long;
  const text = stripAnsi(job.output.map((o) => o.text).join(''));
  const tail = text.split('\n').filter(Boolean).slice(-12).join('\n');
  const color = job.status === 'ok' ? TONE.ok : job.status === 'fail' ? TONE.bad : TONE.info;
  return (
    <div className="animate-rise overflow-hidden rounded-xl border border-white/10 bg-card shadow-[0_12px_40px_rgba(0,0,0,.45)]">
      <div className="flex items-center gap-2.5 px-3 py-2.5">
        {job.status === 'running' ? <Spinner size={11} /> : <span className="size-1.5 flex-none rounded-full" style={{ background: color }} />}
        <div className="min-w-0 flex-1">
          <div className="truncate font-mono text-[11.5px]">{job.command}</div>
          <div className="font-mono text-[10.5px] text-muted">
            {job.status === 'running' ? `running · ${ms(now - job.startedAt)}` : job.status === 'ok' ? `done · ${ms(job.durationMs)}` : `failed · exit ${job.code}`}
          </div>
        </div>
        {job.status === 'fail' && <Btn size="xs" onClick={() => setFailed(job)}>Details</Btn>}
        {job.status === 'running' && job.kill && <Btn size="xs" onClick={job.kill}>Cancel</Btn>}
        <IconBtn title={expanded ? 'Collapse' : 'Show output'} onClick={() => setOpen(!open)}>{expanded ? <ChevronDown size={13} /> : <ChevronUp size={13} />}</IconBtn>
        {job.status !== 'running' && <IconBtn title="Dismiss" onClick={() => dismiss(job.id)}><X size={13} /></IconBtn>}
      </div>
      {expanded && (
        <div className="max-h-[220px] overflow-auto whitespace-pre-wrap border-t border-white/8 bg-term px-3 py-2 font-mono text-[10.5px] leading-[1.6] text-soft [overflow-wrap:anywhere]">
          {tail || <span className="text-dim">waiting for output…</span>}
        </div>
      )}
    </div>
  );
}

export function JobDock() {
  const { jobs } = useRunner();
  if (!jobs.length) return null;
  return (
    <div className="fixed bottom-4 right-4 z-30 flex w-[380px] max-w-[calc(100vw-32px)] flex-col gap-2" aria-live="polite">
      {jobs.map((j) => <JobCard key={j.id} job={j} />)}
    </div>
  );
}
