import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, Terminal, TriangleAlert } from 'lucide-react';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { buildInstallScript, defaultInstallOptions, globalDomainFor, installScriptText, validateInstallOptions, type InstallOptions } from '../../shared/install-script';
import { StreamOutput, useStreamRun } from '../components/StreamPane';
import { Alert, Badge, Btn, Card, CopyBtn, cx, Field, Input, Page, Radio, Seg, Spinner, Switch, TONE } from '../components/ui';
import { api } from '../lib/api';
import { useHost } from '../lib/host';
import { navigate, useTitle } from '../lib/router';
import { useUi } from '../lib/uictx';

const STEPS = ['Requirements', 'Method & options', 'Keys & domain', 'Run'];
const PHASES = ['deps', 'docker', 'dokku', 'configure', 'done'];
const SCRIPT_COLOR = { comment: '#5f5f66', cmd: '#c9c9cc', emph: '#ededef', warn: TONE.warn, blank: '#c9c9cc' } as const;

interface Req { label: string; detail: string; state: string; tone: 'ok' | 'warn' | 'bad' }

function requirements(p: Record<string, string>): Req[] {
  const [id = '', ver = '', , pretty = ''] = (p.os ?? '').split('|');
  const osOk = (id === 'ubuntu' && parseFloat(ver) >= 22.04) || (id === 'debian' && parseFloat(ver) >= 11);
  const arch = p.arch ?? '';
  const archOk = /^(x86_64|amd64|aarch64|arm64)$/.test(arch);
  const [user = '', uid = '', sudo = ''] = (p.user ?? '').split('\n');
  const sudoOk = uid === '0' || sudo === 'sudo-ok';
  const nginx = p.nginx ?? 'none';
  const clean = nginx === 'none' || nginx === '0';
  const keys = Number(p.keys) || 0;
  const dokku = /dokku version (\S+)/.exec(p.dokku ?? '')?.[1];
  const memMb = Math.round((Number(/(\d+)/.exec(p.mem ?? '')?.[1]) || 0) / 1024);
  return [
    { label: 'Operating system', detail: `${pretty || 'unknown'} · supported: Ubuntu 22.04 / 24.04, Debian 11+`, state: osOk ? `${id} ${ver}` : 'unsupported', tone: osOk ? 'ok' : 'warn' },
    { label: 'Architecture', detail: `${arch || 'unknown'} · amd64 and arm64 are supported`, state: archOk ? arch : 'unsupported', tone: archOk ? 'ok' : 'bad' },
    { label: 'Sudo access', detail: `${user} · installer must run as root or a user with passwordless sudo`, state: sudoOk ? (uid === '0' ? 'root' : 'sudo') : 'no sudo', tone: sudoOk ? 'ok' : 'bad' },
    { label: 'Memory', detail: `${memMb} MiB · at least 1 GiB recommended (builds can need more)`, state: `${memMb} MiB`, tone: memMb >= 900 ? 'ok' : 'warn' },
    { label: 'Fresh machine', detail: clean ? 'nothing in /etc/nginx/sites-enabled' : `${nginx} file(s) in /etc/nginx/sites-enabled will be removed`, state: clean ? 'clean' : 'nginx in use', tone: clean ? 'ok' : 'warn' },
    { label: 'SSH keypair for deploys', detail: `~/.ssh/authorized_keys has ${keys} key${keys === 1 ? '' : 's'} · can be imported into dokku`, state: `${keys} key${keys === 1 ? '' : 's'}`, tone: keys > 0 ? 'ok' : 'warn' },
    { label: 'Existing Dokku', detail: dokku ? `dokku ${dokku} is already installed · use Upgrade on the Server page instead` : 'dokku: command not found · fresh install', state: dokku ?? 'none', tone: dokku ? 'warn' : 'ok' },
  ];
}

function phaseOf(lines: string[]): number {
  let p = 0;
  for (const l of lines) {
    if (p < 1 && /docker/i.test(l)) p = 1;
    if (p < 2 && /(installing|setting up|unpacking) dokku|bootstrap\.sh|make install|apt-get.*dokku/i.test(l)) p = 2;
    if (p < 3 && /ssh-keys:add|SHA256:|domains:set-global|Set(ting)? global|plugin:install/i.test(l)) p = 3;
  }
  return p;
}

export function InstallWizard() {
  useTitle('Install Dokku');
  const { host } = useHost();
  const ui = useUi();
  const qc = useQueryClient();
  const [step, setStep] = useState(0);
  const [o, setO] = useState<InstallOptions>(() => defaultInstallOptions());
  const set = <K extends keyof InstallOptions>(k: K, v: InstallOptions[K]) => setO((x) => ({ ...x, [k]: v }));
  const shell = host?.mode === 'shell';
  const pre = useQuery({ queryKey: ['preflight', host?.id], queryFn: () => api.preflight(host!.id), enabled: !!host && shell, retry: false, staleTime: 0 });
  const latest = useQuery({ queryKey: ['dokku-latest'], queryFn: api.latestDokku, staleTime: 6 * 3600_000 });
  const run = useStreamRun(host ? `install:${host.id}` : undefined);

  useEffect(() => { if (latest.data?.version) setO((x) => (x.dokkuTag === defaultInstallOptions().dokkuTag ? { ...x, dokkuTag: latest.data!.version! } : x)); }, [latest.data]);
  useEffect(() => {
    if (!host) return;
    const isIp = /^[\d.]+$|:/.test(host.host);
    const ip = isIp ? host.host : pre.data?.ip?.trim() || '';
    setO((x) => ({ ...x, serverIp: ip, globalDomain: x.globalDomain || (isIp ? '' : host.host), domainMode: x.globalDomain || !isIp ? 'custom' : x.domainMode }));
  }, [host, pre.data]);

  const reqs = useMemo(() => (pre.data ? requirements(pre.data) : []), [pre.data]);
  const blocked = reqs.some((r) => r.tone === 'bad');
  const script = useMemo(() => buildInstallScript(o), [o]);
  const errors = useMemo(() => validateInstallOptions(o), [o]);
  const phase = run.state === 'done' ? 4 : phaseOf(run.lines);

  if (!host || !shell) {
    return (
      <Page narrow>
        <Crumb />
        <h1 className="m-0 text-[26px] font-semibold tracking-[-.024em]">Install Dokku</h1>
        <Card className="flex flex-col items-start gap-3 p-5">
          <div className="text-[13.5px] font-semibold">{host ? `${host.name} is connected as the dokku user` : 'Connect to the server first'}</div>
          <div className="max-w-[640px] text-[12.5px] leading-relaxed text-muted">
            The installer runs over SSH as <span className="font-mono text-soft">root</span> or a user with passwordless sudo. Add the server with its root credentials; the connection test will report that Dokku is missing and offer to continue here.
          </div>
          <div className="flex gap-2">
            <Btn variant="primary" size="md" onClick={() => ui.openConnect()}>Connect a server</Btn>
            {host && <Btn size="md" onClick={() => ui.openConnect(host.id)}>Edit {host.name}</Btn>}
            <a className="self-center text-xs" href="https://dokku.com/docs/getting-started/installation/" target="_blank" rel="noreferrer noopener">Installation docs ↗</a>
          </div>
        </Card>
      </Page>
    );
  }

  const bool = (k: 'noRecommends' | 'vhost' | 'skipKey' | 'nginx', key: string, label: string, desc: string) => (
    <OptRow key={key} k={key} label={label} desc={desc}><Switch checked={o[k]} onChange={(v) => set(k, v)} label={label} /></OptRow>
  );
  const text = (k: 'hostname' | 'keyFile' | 'sourceRepo', key: string, label: string, desc: string, ph?: string) => (
    <OptRow key={key} k={key} label={label} desc={desc}><Input className="w-[220px] max-w-full" value={o[k]} onChange={(e) => set(k, e.target.value.trim())} placeholder={ph} /></OptRow>
  );
  const runTone = run.state === 'running' ? 'info' : run.state === 'done' ? 'ok' : run.state === 'failed' ? 'bad' : 'mute';

  return (
    <Page narrow>
      <Crumb />
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <div className="mb-1.5 text-[10.5px] font-semibold uppercase tracking-[.05em] text-muted">New host · {host.host}</div>
          <h1 className="m-0 text-[26px] font-semibold leading-[1.15] tracking-[-.024em]">Install Dokku</h1>
        </div>
        <a href="https://dokku.com/docs/getting-started/installation/" target="_blank" rel="noreferrer noopener" className="text-xs">Installation docs ↗</a>
      </div>
      <div className="no-scrollbar flex gap-1 overflow-x-auto border-b border-white/8" role="tablist">
        {STEPS.map((label, i) => (
          <button key={label} type="button" role="tab" aria-selected={step === i} onClick={() => run.state !== 'running' && setStep(i)}
            className={cx('-mb-px flex h-[38px] flex-none items-center gap-2 border-0 border-b-2 bg-transparent px-3 text-[12.5px] font-medium hover:text-fg', step === i ? 'border-fg text-fg' : 'border-transparent text-muted')}>
            <span className="font-mono text-[10.5px]" style={{ color: step > i ? TONE.ok : step === i ? '#ededef' : '#5f5f66' }}>0{i + 1}</span>{label}
          </button>
        ))}
      </div>

      <div className="grid items-start gap-4 [grid-template-columns:minmax(0,1.4fr)_minmax(0,1fr)] max-lg:[grid-template-columns:1fr]">
        <div className="flex min-w-0 flex-col gap-4">
          {step === 0 && (
            <Card>
              <div className="flex items-center justify-between border-b border-white/8 px-4 py-3">
                <span className="text-[13.5px] font-semibold">Requirements check</span>
                <Btn loading={pre.isFetching} onClick={() => pre.refetch()}>Re-run checks</Btn>
              </div>
              {pre.isLoading && <div className="flex items-center gap-2.5 px-4 py-4 text-xs text-muted"><Spinner />Inspecting {host.host}…</div>}
              {pre.error && <div className="px-4 py-4 text-xs text-bad">{pre.error.message}</div>}
              {reqs.map((q) => (
                <div key={q.label} className="grid items-center gap-3 border-t border-white/6 px-4 py-[11px]" style={{ gridTemplateColumns: '20px 1fr auto' }}>
                  <span className="grid place-items-center">{q.tone === 'ok' ? <Check size={14} strokeWidth={2.2} className="text-ok" /> : <TriangleAlert size={13} strokeWidth={1.8} style={{ color: TONE[q.tone] }} />}</span>
                  <div><div className="text-[12.5px]">{q.label}</div><div className="mt-0.5 font-mono text-[10.5px] text-muted">{q.detail}</div></div>
                  <span className="font-mono text-[10.5px]" style={{ color: TONE[q.tone] }}>{q.state}</span>
                </div>
              ))}
              <div className="flex gap-2.5 border-t border-white/8 px-4 py-3 text-xs leading-normal text-warn" style={{ background: 'rgba(245,158,11,.08)' }}>
                <TriangleAlert size={14} strokeWidth={1.8} className="mt-0.5 flex-none" />
                <span><span className="font-semibold">Fresh VM recommended.</span> First-time installation removes files in nginx <span className="font-mono">sites-enabled</span>. Back up any existing nginx config before continuing.</span>
              </div>
            </Card>
          )}

          {step === 1 && (
            <>
              <Card>
                <div className="border-b border-white/8 px-4 py-3 text-[13.5px] font-semibold">Install method</div>
                {([
                  ['bootstrap', 'bootstrap.sh (recommended)', 'Official installer: installs Docker, the dokku apt package and core plugin dependencies. Pin a release with DOKKU_TAG.'],
                  ['apt', 'Unattended apt package', 'For provisioning tools. Pre-seed debconf answers, add the packagecloud repo, then apt-get install dokku.'],
                  ['source', 'From source (make install)', 'Clone a repository and run sudo make install. For development or a patched fork.'],
                ] as const).map(([id, label, desc]) => (
                  <button key={id} type="button" onClick={() => set('method', id)} className={cx('grid w-full items-start gap-3 border-0 border-t border-white/6 px-4 py-3 text-left text-fg hover:bg-white/4', o.method === id ? 'bg-white/4' : 'bg-transparent')} style={{ gridTemplateColumns: '16px 1fr' }}>
                    <span className="mt-px"><Radio on={o.method === id} /></span>
                    <span><span className="text-[12.5px] font-medium">{label}</span><span className="mt-0.5 block text-xs leading-normal text-muted">{desc}</span></span>
                  </button>
                ))}
              </Card>
              {o.method === 'bootstrap' && (
                <Card className="flex flex-col gap-3.5 p-4">
                  <div className="text-[13.5px] font-semibold">Version</div>
                  <Seg value={o.verMode} onChange={(v) => set('verMode', v)} options={[{ value: 'tag', label: 'Release tag' }, { value: 'branch', label: 'Git branch (source)' }]} />
                  {o.verMode === 'tag'
                    ? <Field label="DOKKU_TAG" hint="Pinning a tag makes the install reproducible. Leave as latest unless you need a specific release.">
                      <div className="flex gap-2"><Input h="md" className="flex-1" value={o.dokkuTag} onChange={(e) => set('dokkuTag', e.target.value.trim())} />{latest.data?.version === o.dokkuTag && <Badge tone="ok" mono dot={false}>latest stable</Badge>}</div>
                    </Field>
                    : <Field label="DOKKU_BRANCH" hintTone="warn" hint="Installs from source. Unreleased branches may break; use for development only."><Input h="md" value={o.dokkuBranch} onChange={(e) => set('dokkuBranch', e.target.value.trim())} /></Field>}
                </Card>
              )}
              <Card>
                <div className="flex items-center justify-between border-b border-white/8 px-4 py-3"><span className="text-[13.5px] font-semibold">Options</span><span className="font-mono text-[10.5px] text-muted">env vars · debconf</span></div>
                {o.method !== 'source' && bool('noRecommends', 'DOKKU_NO_INSTALL_RECOMMENDS', 'Skip recommended packages', 'Skips herokuish (Heroku buildpacks) and other recommended dependencies. Only for Dockerfile-only hosts.')}
                {o.method !== 'source' && bool('vhost', 'dokku/vhost_enable', 'Vhost-based deployments', 'Apps get <app>.<hostname> instead of a port on the host IP.')}
                {o.method !== 'source' && text('hostname', 'dokku/hostname', 'Hostname', 'Used as the vhost domain and for the app URL printed after deploy. Defaults to the global domain.', globalDomainFor(o))}
                {o.method === 'apt' && bool('skipKey', 'dokku/skip_key_file', 'Skip key file check', 'When on, you must add an SSH key manually after install.')}
                {o.method === 'apt' && !o.skipKey && text('keyFile', 'dokku/key_file', 'SSH key file', 'Public key file on the server that is added to the dokku user.')}
                {o.method !== 'source' && bool('nginx', 'dokku/nginx_enable', 'Enable nginx-vhosts plugin', 'Turn off only if you will run a different proxy (Traefik, Caddy).')}
                {o.method === 'source' && text('sourceRepo', 'git clone', 'Source repository', 'HTTPS URL of the dokku repository or your fork.')}
              </Card>
            </>
          )}

          {step === 2 && (
            <>
              <Card className="flex flex-col gap-3.5 p-4">
                <div><div className="text-[13.5px] font-semibold">Admin SSH key</div><div className="mt-0.5 text-xs leading-normal text-muted">Grants push access to the <span className="font-mono text-soft">dokku</span> user.</div></div>
                <Seg value={o.keyMode} onChange={(v) => set('keyMode', v)} options={[{ value: 'authz', label: 'Reuse authorized_keys' }, { value: 'paste', label: 'Paste public key' }]} />
                <div className="grid gap-2.5" style={{ gridTemplateColumns: '140px 1fr' }}>
                  <Field label="Key name"><Input h="md" value={o.keyName} onChange={(e) => set('keyName', e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '-'))} /></Field>
                  {o.keyMode === 'paste'
                    ? <Field label="Public key"><Input h="md" value={o.publicKey} onChange={(e) => set('publicKey', e.target.value)} placeholder="ssh-ed25519 AAAA… user@host" /></Field>
                    : <Field label="Source"><div className="flex h-8 items-center rounded-lg border border-white/8 bg-white/3 px-[11px] font-mono text-xs text-muted">~/.ssh/authorized_keys of {host.username}</div></Field>}
                </div>
              </Card>
              <Card className="flex flex-col gap-2.5 p-4">
                <div className="mb-1"><div className="text-[13.5px] font-semibold">Global domain</div><div className="mt-0.5 text-xs leading-normal text-muted">Apps deploy to <span className="font-mono text-soft">&lt;app&gt;.&lt;global domain&gt;</span>. Needs an A record or CNAME pointing at the server.</div></div>
                {([
                  ['custom', 'Domain you control', `A record or CNAME → ${o.serverIp || host.host}; wildcard for per-app subdomains`, o.globalDomain || 'dokku.me'],
                  ['ip', 'Server IP', 'Apps are served on ports; no subdomain routing', o.serverIp || '—'],
                  ['sslip', 'sslip.io', 'Free wildcard DNS for the IP; subdomains without owning a domain', o.serverIp ? `${o.serverIp}.sslip.io` : '—'],
                ] as const).map(([id, label, desc, value]) => (
                  <button key={id} type="button" onClick={() => set('domainMode', id)} className={cx('grid items-center gap-3 rounded-lg border px-3 py-2.5 text-left text-fg hover:border-white/20', o.domainMode === id ? 'border-white/18 bg-white/4' : 'border-white/8 bg-transparent')} style={{ gridTemplateColumns: '16px 1fr auto' }}>
                    <Radio on={o.domainMode === id} />
                    <span><span className="text-[12.5px] font-medium">{label}</span><span className="mt-0.5 block text-[11.5px] text-muted">{desc}</span></span>
                    <span className="font-mono text-[11px] text-soft">{value}</span>
                  </button>
                ))}
                {o.domainMode === 'custom' && <Input h="md" value={o.globalDomain} onChange={(e) => set('globalDomain', e.target.value.trim().toLowerCase())} placeholder="apps.example.com" />}
                {o.domainMode !== 'custom' && !o.serverIp && <Input h="md" value={o.serverIp} onChange={(e) => set('serverIp', e.target.value.trim())} placeholder="public IP of the server" />}
              </Card>
              <Card>
                <div className="border-b border-white/8 px-4 py-3 text-[13.5px] font-semibold">After install</div>
                {([
                  ['disableInstaller', 'Disable web installer', 'sudo systemctl disable --now dokku-installer'],
                  ['letsencrypt', 'Install letsencrypt plugin', 'dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git'],
                  ['createFirst', 'Create first app', `dokku apps:create ${o.firstApp}`],
                ] as const).map(([k, label, cmd]) => (
                  <div key={k} className="grid items-center gap-4 border-t border-white/6 px-4 py-[11px]" style={{ gridTemplateColumns: '1fr auto' }}>
                    <div className="min-w-0"><div className="text-[12.5px]">{label}</div><div className="mt-[3px] font-mono text-[10.5px] text-muted [overflow-wrap:anywhere]">{cmd}</div></div>
                    <Switch checked={o.post[k]} onChange={(v) => set('post', { ...o.post, [k]: v })} label={label} />
                  </div>
                ))}
                {o.post.createFirst && (
                  <div className="grid items-center gap-2.5 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: 'auto 1fr' }}>
                    <span className="text-xs text-muted">First app name</span>
                    <Input className="max-w-[240px]" value={o.firstApp} onChange={(e) => set('firstApp', e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '-'))} />
                  </div>
                )}
              </Card>
            </>
          )}

          {step === 3 && (
            <>
              {errors.length > 0 && <Alert tone="bad" title="Fix these before running:">{errors.join(' · ')}</Alert>}
              {blocked && <Alert tone="bad" title="Requirements not met.">{reqs.filter((r) => r.tone === 'bad').map((r) => r.label).join(', ')} — see step 01.</Alert>}
              <div className="flex h-[460px] flex-col overflow-hidden rounded-xl border border-white/8 bg-term">
                <div className="flex items-center justify-between border-b border-white/8 bg-card px-3 py-2.5">
                  <span className="flex items-center gap-2 text-[12.5px] font-semibold"><Terminal size={13} strokeWidth={1.6} />Installer output</span>
                  <Badge tone={runTone} mono pulse={run.state === 'running'}>{run.state === 'done' ? 'complete' : run.state}</Badge>
                </div>
                <StreamOutput lines={run.lines} idle={<>Press Run to execute the generated script over SSH as <span className="text-soft">{host.username}@{host.host}</span>. Takes 5–10 minutes depending on connection speed.</>} />
                <div className="flex flex-wrap gap-4 border-t border-white/8 bg-card px-3 py-2 font-mono text-[10.5px] text-muted">
                  {PHASES.map((label, i) => {
                    const active = run.state !== 'idle' && phase >= i;
                    const dot = run.state === 'done' || phase > i ? TONE.ok : phase === i && run.state === 'running' ? TONE.info : phase === i && run.state === 'failed' ? TONE.bad : 'rgba(255,255,255,.12)';
                    return <span key={label} className="flex items-center gap-1.5" style={{ color: active ? '#ededef' : '#5f5f66' }}><span className="size-1.5 rounded-full" style={{ background: run.state === 'idle' ? 'rgba(255,255,255,.12)' : dot }} />{label}</span>;
                  })}
                </div>
              </div>
            </>
          )}

          <div className="flex justify-between gap-2">
            <Btn variant="outline" size="md" disabled={step === 0 || run.state === 'running'} onClick={() => setStep(step - 1)}>Back</Btn>
            <div className="flex gap-2">
              {step === 3 && (
                <>
                  <CopyBtn text={installScriptText(o)} label="Copy script" size="md" />
                  {run.state === 'running' && <Btn variant="outline" size="md" onClick={run.kill}>Cancel</Btn>}
                  {run.state === 'done'
                    ? <Btn variant="primary" size="md" onClick={() => { qc.invalidateQueries(); navigate({ view: 'dash' }); }}>Open dashboard</Btn>
                    : <Btn variant="primary" size="md" disabled={errors.length > 0 || blocked} loading={run.state === 'running'} onClick={() => run.start({ hostId: host.id, kind: 'install', options: o })}>{run.state === 'running' ? 'Installing…' : run.state === 'failed' ? 'Run again' : 'Run installer'}</Btn>}
                </>
              )}
              {step < 3 && <Btn variant="primary" size="md" onClick={() => setStep(step + 1)}>Continue</Btn>}
            </div>
          </div>
        </div>

        <div className="sticky top-0 min-w-0 overflow-hidden rounded-xl border border-white/8 bg-term">
          <div className="flex items-center justify-between border-b border-white/8 bg-card px-3 py-2.5">
            <span className="text-[12.5px] font-semibold">Generated script</span>
            <span className="font-mono text-[10.5px] text-muted">install-dokku.sh</span>
          </div>
          <div className="max-h-[70vh] overflow-auto px-3.5 py-3 font-mono text-[11px] leading-[1.75]">
            {script.map((l, i) => <div key={i} className="min-h-[1em] whitespace-pre-wrap [overflow-wrap:anywhere]" style={{ color: SCRIPT_COLOR[l.kind] }}>{l.text}</div>)}
          </div>
        </div>
      </div>
    </Page>
  );
}

function OptRow({ k, label, desc, children }: { k: string; label: string; desc: string; children: ReactNode }) {
  return (
    <div className="grid items-center gap-4 border-t border-white/6 px-4 py-[11px]" style={{ gridTemplateColumns: '1fr auto' }}>
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2"><span className="text-[12.5px]">{label}</span><span className="rounded bg-white/5 px-[5px] py-px font-mono text-[10px] text-muted">{k}</span></div>
        <div className="mt-[3px] text-[11.5px] leading-normal text-muted">{desc}</div>
      </div>
      {children}
    </div>
  );
}

function Crumb() {
  return (
    <div className="flex items-center gap-1.5 text-xs text-muted">
      <button type="button" onClick={() => navigate({ view: 'server' })} className="border-0 bg-transparent p-0 text-muted hover:text-fg">Server &amp; SSH</button>
      <span>/</span><span className="font-medium text-fg">Install Dokku</span>
    </div>
  );
}
