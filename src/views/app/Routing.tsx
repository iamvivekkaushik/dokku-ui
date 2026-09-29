import { useQuery } from '@tanstack/react-query';
import { Globe, X } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Badge, Btn, Card, CardHead, Cmd, Col, Empty, Field, Grid2, IconBtn, Input, KV, Modal, Seg, Select, Skeleton, SwitchRow, Textarea, THead, TONE } from '../../components/ui';
import { api } from '../../lib/api';
import { notSupported, useApps, useDokku, useReport } from '../../lib/dokku';
import { daysUntil, pickFile, readFile } from '../../lib/format';
import { useCurrentHost } from '../../lib/host';
import { bool, words } from '../../lib/parse';
import { useAction } from '../../lib/runner';

const PROXIES = ['nginx', 'caddy', 'traefik', 'haproxy', 'openresty'];

export function RoutingTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const { busy, act, wrap, run } = useAction();
  const apps = useApps();
  const dom = useReport('domains', app);
  const certs = useReport('certs', app);
  const proxy = useReport('proxy', app);
  const ports = useReport('ports', app);
  const nginx = useReport('nginx', app, { enabled: (proxy.data?.['proxy computed type'] ?? 'nginx') === 'nginx' });
  const le = useDokku(['letsencrypt:report', app], (r) => (notSupported(r) || r.code !== 0 ? null : parseLe(r.stdout)), { allowFail: true });
  const leList = useDokku(['letsencrypt:list'], (r) => (notSupported(r) || r.code !== 0 ? null : r.stdout), { allowFail: true });

  const domains = words(dom.data?.['domains app vhosts']);
  const globalVhosts = apps.data?.globalVhosts ?? words(dom.data?.['domains global vhosts']);
  const [newDomain, setNewDomain] = useState('');
  const dns = useQuery({ queryKey: ['dns', host.id, domains.join(',')], queryFn: () => api.dns(host.id, domains), enabled: domains.length > 0, staleTime: 5 * 60_000 });
  const dnsFor = (d: string) => dns.data?.results.find((r) => r.name === d);

  const sslOn = bool(certs.data?.['ssl enabled']);
  const expires = certs.data?.['ssl expires at'];
  const days = daysUntil(expires);
  const certTone = !sslOn ? 'warn' : days != null && days < 14 ? 'bad' : days != null && days < 30 ? 'warn' : 'ok';
  const leActive = le.data?.active === 'true' || (leList.data ?? '').split('\n').some((l) => l.trim().startsWith(app + ' '));
  const leInstalled = le.data !== null && le.data !== undefined;
  const [leEmail, setLeEmail] = useState('');
  useEffect(() => { if (le.data) setLeEmail(le.data['computed email'] || le.data.email || le.data['global email'] || ''); }, [le.data]);
  const [certUpload, setCertUpload] = useState<{ crt: string; key: string } | null>(null);

  const enableLe = async () => {
    if (!leEmail.trim()) return;
    const cur = le.data?.['computed email'] || '';
    if (leEmail.trim() !== cur) { const r = await run(['letsencrypt:set', app, 'email', leEmail.trim()]); if (r?.code !== 0) return; }
    const r = await run(['letsencrypt:enable', app], { title: `Let's Encrypt for ${app}`, timeoutMs: 10 * 60_000 });
    if (r?.code === 0) await run(['letsencrypt:cron-job', '--add'], { quietFail: true, title: 'Enable auto-renew cron' });
  };

  const proxyType = proxy.data?.['proxy type'] || '';
  const proxyEff = proxy.data?.['proxy computed type'] || 'nginx';
  const proxyOn = bool(proxy.data?.['proxy enabled']);
  const portMap = words(ports.data?.['ports map'] || ports.data?.['ports map detected']).map((p) => { const [scheme, hostPort, containerPort] = p.split(':'); return { scheme, host: hostPort, container: containerPort, raw: p }; });
  const [np, setNp] = useState({ scheme: 'http', host: '', container: '' });
  const npValid = /^(http|https|tcp|udp|grpc|grpcs)$/.test(np.scheme) && /^\d+$/.test(np.host) && /^\d+$/.test(np.container);

  const hsts = bool(nginx.data?.['nginx computed hsts']);
  const hstsSub = bool(nginx.data?.['nginx computed hsts include subdomains']);
  const hstsPreload = bool(nginx.data?.['nginx computed hsts preload']);
  const proxyDesc: Record<string, string> = {
    nginx: 'Default. Vhost configs in /home/dokku/<app>/nginx.conf; supports custom templates.',
    caddy: 'Automatic HTTPS via Caddy. Enable with caddy:start after switching.',
    traefik: 'Label-based routing with Traefik; enable with traefik:start.',
    haproxy: 'HAProxy via the haproxy-vhosts plugin. TCP-friendly.',
    openresty: 'OpenResty (nginx + Lua) via the openresty-vhosts plugin.',
  };

  return (
    <Grid2>
      <Col>
        <Card>
          <CardHead title="Domains" right={<>global fallback: <span className="font-mono text-soft">{globalVhosts.length ? globalVhosts.map((g) => `${app}.${g}`).join(', ') : 'none'}</span></>} />
          {dom.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {dom.data && domains.length === 0 && <Empty>No domains. The app is unreachable through the proxy until one is added.</Empty>}
          {domains.map((d) => {
            const r = dnsFor(d);
            const dnsText = !r ? 'DNS …' : r.addresses.length === 0 ? 'no A record' : r.matches ? 'DNS ok' : `A → ${r.addresses[0]}${r.matches === false ? ' (not this host)' : ''}`;
            const dnsTone = !r ? TONE.mute : r.matches ? TONE.ok : r.addresses.length ? TONE.warn : TONE.bad;
            const covered = sslOn && words(certs.data?.['ssl hostnames']).some((h) => h === d || (h.startsWith('*.') && d.endsWith(h.slice(1))));
            return (
              <div key={d} className="grid items-center gap-3 border-t border-white/6 px-4 py-[11px]" style={{ gridTemplateColumns: 'minmax(0,1fr) auto auto' }}>
                <div className="min-w-0">
                  <a href={`${covered ? 'https' : 'http'}://${d}`} target="_blank" rel="noreferrer noopener" className="block truncate text-[13px] font-medium text-fg hover:underline">{d}</a>
                  <div className="mt-0.5 font-mono text-[10.5px] text-muted">{r?.cname ? `CNAME ${r.cname} · ` : ''}<span style={{ color: dnsTone }}>{dnsText}</span></div>
                </div>
                <Badge tone={covered ? 'ok' : 'warn'} mono dot={false}>{covered ? 'TLS' : 'no cert'}</Badge>
                <IconBtn title="Remove domain" danger onClick={() => run(['domains:remove', app, d], { confirm: { title: `Remove ${d}?`, body: 'The proxy stops routing this hostname to the app.', confirmLabel: 'Remove', danger: true } })}><X size={13} /></IconBtn>
              </div>
            );
          })}
          <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '1fr auto' }}>
            <Input value={newDomain} onChange={(e) => setNewDomain(e.target.value.trim().toLowerCase())} placeholder="app.example.com" onKeyDown={(e) => e.key === 'Enter' && newDomain && act('adddom', ['domains:add', app, ...newDomain.split(/[\s,]+/)]).then(() => setNewDomain(''))} />
            <Btn disabled={!/^[a-z0-9*.-]+\.[a-z]{2,}$/.test(newDomain)} loading={busy === 'adddom'} onClick={() => act('adddom', ['domains:add', app, ...newDomain.split(/[\s,]+/)]).then(() => setNewDomain(''))}>Add domain</Btn>
          </div>
          <Cmd>$ dokku domains:add {app} &lt;domain&gt;  ·  domains:remove  ·  domains:report  ·  <span className="text-dim">DNS should point at {dns.data?.hostIps.join(', ') || host.host}</span></Cmd>
        </Card>

        <Card>
          <CardHead title="Ports" right="scheme : host → container" />
          <THead cols="80px 1fr 1fr auto"><span>scheme</span><span>host port</span><span>container</span><span /></THead>
          {ports.isLoading && <div className="p-4"><Skeleton className="h-4 w-full" /></div>}
          {ports.data && portMap.length === 0 && <Empty>No port mappings yet; Dokku detects them on first deploy.</Empty>}
          {portMap.map((p) => (
            <div key={p.raw} className="grid items-center gap-3 border-t border-white/6 px-4 py-2" style={{ gridTemplateColumns: '80px 1fr 1fr auto' }}>
              <span className="font-mono text-[11.5px]" style={{ color: p.scheme === 'https' ? TONE.ok : '#c9c9cc' }}>{p.scheme}</span>
              <span className="font-mono text-[11.5px]">{p.host}</span>
              <span className="font-mono text-[11.5px] text-soft">{p.container}</span>
              <IconBtn title="Remove mapping" danger onClick={() => run(['ports:remove', app, p.raw])}><X size={13} /></IconBtn>
            </div>
          ))}
          {!ports.data?.['ports map'] && ports.data?.['ports map detected'] && <div className="border-t border-white/6 px-4 py-1.5 text-[10.5px] text-dim">Showing detected mappings; Dokku applies them on deploy until you set explicit ones.</div>}
          <div className="grid gap-2 border-t border-white/6 bg-white/2 px-4 py-2.5" style={{ gridTemplateColumns: '80px 1fr 1fr auto' }}>
            <Select value={np.scheme} onChange={(e) => setNp({ ...np, scheme: e.target.value })}>{['http', 'https', 'tcp', 'udp', 'grpc', 'grpcs'].map((s) => <option key={s}>{s}</option>)}</Select>
            <Input value={np.host} onChange={(e) => setNp({ ...np, host: e.target.value.replace(/\D/g, '') })} placeholder="80" />
            <Input value={np.container} onChange={(e) => setNp({ ...np, container: e.target.value.replace(/\D/g, '') })} placeholder="5000" />
            <Btn disabled={!npValid} loading={busy === 'port'} onClick={() => act('port', ['ports:add', app, `${np.scheme}:${np.host}:${np.container}`]).then(() => setNp({ scheme: 'http', host: '', container: '' }))}>Map</Btn>
          </div>
          <Cmd>$ dokku ports:add {app} {np.scheme}:{np.host || '<host>'}:{np.container || '<container>'}  ·  ports:remove  ·  ports:clear</Cmd>
        </Card>
      </Col>

      <Col>
        <Card>
          <CardHead title="Certificate" right={<Badge tone={certTone} mono dot={false}>{!sslOn ? 'no certificate' : days != null ? `valid · ${days}d` : 'valid'}</Badge>} />
          {certs.isLoading ? <div className="p-4"><Skeleton className="h-16 w-full" /></div> : (
            <div className="px-4 py-1">
              <KV k="Issuer" v={certs.data?.['ssl issuer'] || '—'} />
              <KV k="Expires" v={expires ? `${expires}${days != null ? ` · in ${days} days` : ''}` : '—'} />
              <KV k="SANs" v={certs.data?.['ssl hostnames'] || '—'} />
              <KV k="Verified" v={certs.data?.['ssl verified'] || '—'} />
            </div>
          )}
          <div className="flex flex-col gap-3 border-t border-white/6 px-4 py-3">
            {leInstalled ? (
              <>
                <SwitchRow title="Let's Encrypt" desc={leActive ? `Managed by dokku-letsencrypt${le.data?.expiration ? ` · renews before ${le.data.expiration}` : ''}` : 'Issue and auto-renew a certificate for the domains above.'} checked={leActive} busy={busy === 'le'}
                  onChange={(v) => (v ? wrap('le', enableLe) : act('le', ['letsencrypt:disable', app], { confirm: { title: 'Disable Let’s Encrypt?', body: 'The certificate is removed and the app falls back to HTTP.', confirmLabel: 'Disable', danger: true } }))} />
                {!leActive && (
                  <div className="grid gap-2" style={{ gridTemplateColumns: '1fr auto' }}>
                    <Input value={leEmail} onChange={(e) => setLeEmail(e.target.value)} placeholder="ops@example.com (required by Let's Encrypt)" />
                    <Btn variant="primary" disabled={!/^\S+@\S+\.\S+$/.test(leEmail) || domains.length === 0} loading={busy === 'le'} onClick={() => wrap('le', enableLe)}>Enable</Btn>
                  </div>
                )}
                {leActive && <div className="flex gap-1.5"><Btn loading={busy === 'renew'} onClick={() => act('renew', ['letsencrypt:auto-renew', app], { timeoutMs: 10 * 60_000 })}>Renew now</Btn><Btn loading={busy === 'cron'} onClick={() => act('cron', ['letsencrypt:cron-job', '--add'])}>Ensure auto-renew cron</Btn></div>}
              </>
            ) : (
              <div className="text-[11.5px] leading-normal text-muted">The <span className="font-mono">letsencrypt</span> plugin is not installed. Install it from <a href="#/server">Server &amp; SSH → Plugins</a> to issue free certificates.</div>
            )}
            <div className="flex items-center justify-between gap-3 border-t border-white/6 pt-3">
              <div><div className="text-[12.5px]">Custom certificate</div><div className="mt-0.5 text-[11.5px] text-muted">Upload server.crt and server.key (PEM)</div></div>
              <div className="flex gap-1.5">
                <Btn onClick={() => setCertUpload({ crt: '', key: '' })}>Upload</Btn>
                <Btn variant="dangerGhost" disabled={!sslOn} onClick={() => run(['certs:remove', app], { confirm: { title: 'Remove certificate?', body: 'HTTPS stops working for this app until a new certificate is added.', confirmLabel: 'Remove', danger: true } })}>Remove</Btn>
              </div>
            </div>
          </div>
          <Cmd>$ dokku {leInstalled ? `letsencrypt:enable ${app}  ·  letsencrypt:auto-renew ${app}` : `certs:add ${app} < cert-key.tar  ·  certs:report ${app}`}</Cmd>
        </Card>

        <Card>
          <CardHead title="Reverse proxy" right={<SwitchRow title="" checked={proxyOn} busy={busy === 'proxyon'} onChange={(v) => act('proxyon', [v ? 'proxy:enable' : 'proxy:disable', app], v ? undefined : { confirm: { title: 'Disable the proxy?', body: 'Domains stop routing to this app; containers are reachable only by their published ports.', confirmLabel: 'Disable', danger: true } })} />} />
          <div className="flex flex-col gap-2.5 px-4 py-3.5">
            <Seg value={proxyEff} onChange={(v) => act('proxy', ['proxy:set', app, v], { confirm: { title: `Switch proxy to ${v}?`, body: `Routing is rebuilt with the ${v} plugin. Non-nginx proxies need their service started once (e.g. ${v}:start).`, confirmLabel: 'Switch' } })} options={PROXIES} />
            <div className="text-[11.5px] leading-normal text-muted">{proxyDesc[proxyEff] ?? 'Custom proxy plugin.'}{proxyType ? '' : ' (using global default)'}</div>
            {proxyEff === 'nginx' && nginx.data && (
              <div className="flex flex-col gap-2 border-t border-white/6 pt-2">
                <SwitchRow title="HSTS" desc={`max-age ${nginx.data['nginx computed hsts max age']}`} checked={hsts} busy={busy === 'hsts'} onChange={(v) => act('hsts', ['nginx:set', app, 'hsts', String(v)]).then(() => run(['proxy:build-config', app], { title: 'Rebuild nginx config' }))} />
                <SwitchRow title="HSTS include subdomains" checked={hstsSub} busy={busy === 'hstss'} onChange={(v) => act('hstss', ['nginx:set', app, 'hsts-include-subdomains', String(v)]).then(() => run(['proxy:build-config', app], { title: 'Rebuild nginx config' }))} />
                <SwitchRow title="HSTS preload" checked={hstsPreload} busy={busy === 'hstsp'} onChange={(v) => act('hstsp', ['nginx:set', app, 'hsts-preload', String(v)]).then(() => run(['proxy:build-config', app], { title: 'Rebuild nginx config' }))} />
                <div className="text-[11px] text-dim">HTTP → HTTPS redirects are automatic whenever a certificate is installed. Client max body: {nginx.data['nginx computed client max body size']}.</div>
              </div>
            )}
          </div>
          <Cmd>$ dokku proxy:set {app} {proxyEff}  ·  proxy:{proxyOn ? 'disable' : 'enable'} {app}  ·  nginx:set {app} hsts true</Cmd>
        </Card>
      </Col>

      {certUpload && (
        <Modal open onOpenChange={(v) => !v && setCertUpload(null)} title="Upload certificate" width={560}
          footer={<><Btn size="md" onClick={() => setCertUpload(null)}>Cancel</Btn>
            <Btn variant="primary" size="md" disabled={!/BEGIN CERTIFICATE/.test(certUpload.crt) || !/PRIVATE KEY/.test(certUpload.key)} loading={busy === 'certadd'}
              onClick={() => act('certadd', ['certs:add', app], { stdinFiles: { 'server.crt': certUpload.crt, 'server.key': certUpload.key }, title: 'Install certificate' }).then((r) => r?.code === 0 && setCertUpload(null))}>Install</Btn></>}>
          <Field label={<span className="flex items-center justify-between">server.crt (PEM, full chain)<Btn size="xs" onClick={async () => { const f = await pickFile('.crt,.pem,.cer'); if (!f) return; const crt = await readFile(f); setCertUpload((c) => c && { ...c, crt }); }}>Choose file</Btn></span>}>
            <Textarea className="h-28 w-full" value={certUpload.crt} onChange={(e) => setCertUpload({ ...certUpload, crt: e.target.value })} placeholder="-----BEGIN CERTIFICATE-----" spellCheck={false} />
          </Field>
          <Field label={<span className="flex items-center justify-between">server.key (PEM)<Btn size="xs" onClick={async () => { const f = await pickFile('.key,.pem'); if (!f) return; const key = await readFile(f); setCertUpload((c) => c && { ...c, key }); }}>Choose file</Btn></span>}>
            <Textarea className="h-28 w-full" value={certUpload.key} onChange={(e) => setCertUpload({ ...certUpload, key: e.target.value })} placeholder="-----BEGIN PRIVATE KEY-----" spellCheck={false} />
          </Field>
          <div className="flex items-center gap-2 text-[11px] text-dim"><Globe size={11} />Sent as a tar archive on stdin: <span className="font-mono">dokku certs:add {app} &lt; cert-key.tar</span></div>
        </Modal>
      )}
    </Grid2>
  );
}

function parseLe(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const l of text.split('\n')) {
    const m = /^\s+Letsencrypt (.+?):\s*(.*?)\s*$/i.exec(l);
    if (m) out[m[1].toLowerCase()] = m[2];
  }
  return out;
}
