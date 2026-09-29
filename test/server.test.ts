import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildInstallScript, defaultInstallOptions, installScriptText, validateInstallOptions, type InstallOptions } from '../shared/install-script';
import { parseMetrics, parseSize, sections } from '../server/scripts';
import { makeTar } from '../server/tar';

describe('makeTar', () => {
  it('produces an archive that tar can extract', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'dkc-tar-'));
    const crt = '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
    const key = '-----BEGIN PRIVATE KEY-----\n' + 'A'.repeat(1500) + '\n-----END PRIVATE KEY-----\n';
    writeFileSync(path.join(dir, 'c.tar'), makeTar({ 'server.crt': crt, 'server.key': key }));
    expect(execFileSync('tar', ['-tf', 'c.tar'], { cwd: dir, encoding: 'utf8' }).trim().split('\n')).toEqual(['server.crt', 'server.key']);
    execFileSync('tar', ['-xf', 'c.tar'], { cwd: dir });
    expect(readFileSync(path.join(dir, 'server.crt'), 'utf8')).toBe(crt);
    expect(readFileSync(path.join(dir, 'server.key'), 'utf8')).toBe(key);
  });

  it('rejects path traversal in entry names', () => {
    expect(() => makeTar({ '../etc/passwd': 'x' })).toThrow();
    expect(() => makeTar({ 'a/b': 'x' })).toThrow();
  });
});

describe('install script', () => {
  const base = (patch: Partial<InstallOptions> = {}): InstallOptions => ({ ...defaultInstallOptions('203.0.113.10'), ...patch });
  const variants: [string, InstallOptions][] = [
    ['bootstrap tag', base()],
    ['bootstrap branch', base({ verMode: 'branch' })],
    ['apt', base({ method: 'apt', noRecommends: true })],
    ['source', base({ method: 'source' })],
    ['pasted key + custom domain', base({ keyMode: 'paste', publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFKN user@host', domainMode: 'custom', globalDomain: 'apps.example.com', post: { disableInstaller: true, letsencrypt: true, createFirst: true } })],
  ];

  it.each(variants)('%s is valid bash', (_name, o) => {
    expect(validateInstallOptions(o)).toEqual([]);
    execFileSync('bash', ['-n'], { input: installScriptText(o) });
  });

  it('uses the chosen tag and global domain', () => {
    const text = installScriptText(base({ dokkuTag: 'v0.35.20' }));
    expect(text).toContain('https://dokku.com/install/v0.35.20/bootstrap.sh');
    expect(text).toContain('DOKKU_TAG=v0.35.20');
    expect(text).toContain('dokku domains:set-global 203.0.113.10.sslip.io');
  });

  it('refuses values that could inject shell', () => {
    expect(validateInstallOptions(base({ dokkuTag: 'v1.0.0; rm -rf /' }))).not.toEqual([]);
    expect(validateInstallOptions(base({ keyName: 'a b' }))).not.toEqual([]);
    expect(validateInstallOptions(base({ domainMode: 'custom', globalDomain: 'x.com$(id)' }))).not.toEqual([]);
    expect(validateInstallOptions(base({ keyMode: 'paste', publicKey: 'ssh-ed25519 AAAA\nmalicious' }))).not.toEqual([]);
    expect(validateInstallOptions(base({ post: { disableInstaller: true, letsencrypt: true, createFirst: true }, firstApp: 'a;b' }))).not.toEqual([]);
    expect(validateInstallOptions(base({ method: 'source', sourceRepo: 'https://x/y.git; id' }))).not.toEqual([]);
  });

  it('quotes a pasted key with awkward comment text', () => {
    const o = base({ keyMode: 'paste', publicKey: "ssh-ed25519 AAAAC3Nz it's $(mine)" });
    expect(validateInstallOptions(o)).toEqual([]);
    const line = buildInstallScript(o).find((l) => l.text.startsWith('PUBLIC_KEY='))!.text;
    const out = execFileSync('bash', ['-c', `${line}; printf '%s' "$PUBLIC_KEY"`], { encoding: 'utf8' });
    expect(out).toBe("ssh-ed25519 AAAAC3Nz it's $(mine)");
  });
});

describe('host metrics', () => {
  it('splits sections', () => {
    expect(sections('@@a\n1\n2\n@@b\n\n@@c\nx\n')).toEqual({ a: '1\n2', b: '', c: 'x' });
  });

  it('parses sizes', () => {
    expect(parseSize('98MiB')).toBe(98 * 1024 ** 2);
    expect(parseSize('1.5GiB')).toBe(1.5 * 1024 ** 3);
    expect(parseSize('512kB')).toBe(512_000);
    expect(parseSize('0B')).toBe(0);
  });

  it('computes cpu, memory, disk and containers', () => {
    const m = parseMetrics(`@@load
0.46 0.51 0.48 1/812 12345
@@nproc
8
@@stat1
cpu  1000 0 500 8000 100 0 0 0 0 0
@@stat2
cpu  1100 0 550 8300 100 0 0 0 0 0
@@mem
MemTotal:       16000000 kB
MemAvailable:   12000000 kB
SwapTotal:       4000000 kB
SwapFree:        4000000 kB
@@disk
/dev/vda1 85899345920 42949672960 42949672960 50% /
@@uptime
3567890.12 100.00
@@stats
{"CPUPerc":"1.50%","MemUsage":"98MiB / 512MiB","Name":"demo-app.web.1"}
@@ps
{"ID":"b0af7e6995fb0123","Image":"dokku/demo-app:latest","Names":"demo-app.web.1","State":"running","Status":"Up 2 minutes"}
{"ID":"475779320b4d0123","Image":"dokku/demo-app:latest","Names":"demo-app.web.2","State":"exited","Status":"Exited (0)"}
@@end
`);
    expect(m.cores).toBe(8);
    expect(m.load).toEqual([0.46, 0.51, 0.48]);
    expect(Math.round(m.cpuPct!)).toBe(33); // 150 busy of 450 total ticks
    expect(m.mem).toEqual({ total: 16000000 * 1024, available: 12000000 * 1024 });
    expect(m.disk).toMatchObject({ device: '/dev/vda1', total: 85899345920, used: 42949672960, mount: '/' });
    expect(m.uptimeSec).toBeCloseTo(3567890.12);
    expect(m.containers).toHaveLength(2);
    expect(m.containers[0]).toMatchObject({ name: 'demo-app.web.1', state: 'running', cpuPct: 1.5, memBytes: 98 * 1024 ** 2, memLimit: 512 * 1024 ** 2 });
    expect(m.containers[1]).toMatchObject({ name: 'demo-app.web.2', state: 'exited', cpuPct: null });
  });

  it('survives a host without docker access', () => {
    const m = parseMetrics('@@load\n0 0 0\n@@nproc\n2\n@@stat1\ncpu 1 1 1 1\n@@stat2\ncpu 1 1 1 1\n@@mem\n@@disk\n@@uptime\n@@stats\n@@ps\n@@end\n');
    expect(m.dockerAvailable).toBe(false);
    expect(m.containers).toEqual([]);
    expect(m.cpuPct).toBeNull();
  });
});
