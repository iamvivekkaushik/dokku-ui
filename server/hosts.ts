// Persistent host registry. Credentials live only on the console server in
// data/hosts.json (mode 0600) and are never returned to the browser.
import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type { HostInfo, HostInput } from '../shared/types';

export interface HostRecord extends HostInput {
  id: string;
  createdAt: string;
  sudo: boolean;
}

export const DATA_DIR = process.env.DOKKU_UI_DATA_DIR ?? path.resolve(process.cwd(), 'data');
const FILE = path.join(DATA_DIR, 'hosts.json');

let cache: HostRecord[] | null = null;

async function load(): Promise<HostRecord[]> {
  if (cache) return cache;
  try {
    cache = JSON.parse(await fs.readFile(FILE, 'utf8')) as HostRecord[];
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    cache = [];
  }
  return cache;
}

async function save(list: HostRecord[]): Promise<void> {
  await fs.mkdir(DATA_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${FILE}.${process.pid}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(list, null, 2), { mode: 0o600 });
  await fs.rename(tmp, FILE);
  cache = list;
}

export function toInfo(h: HostRecord): HostInfo {
  return {
    id: h.id, name: h.name, host: h.host, port: h.port, username: h.username, auth: h.auth,
    keyPath: h.keyPath, hasPrivateKey: !!h.privateKey, hasPassword: !!h.password, hasPassphrase: !!h.passphrase,
    hostKey: h.hostKey, sudo: h.sudo, mode: h.username === 'dokku' ? 'dokku' : 'shell', createdAt: h.createdAt,
  };
}

export function validateInput(input: Partial<HostInput>, partial = false): string[] {
  const errs: string[] = [];
  const need = (k: keyof HostInput) => !partial || input[k] !== undefined;
  if (need('name') && (typeof input.name !== 'string' || !/^[\w .-]{1,60}$/.test(input.name))) errs.push('name: 1-60 letters, digits, spaces, dots or dashes');
  if (need('host') && (typeof input.host !== 'string' || !/^[A-Za-z0-9.:[\]-]{1,253}$/.test(input.host))) errs.push('host: hostname or IP address');
  if (need('port') && (!Number.isInteger(input.port) || input.port! < 1 || input.port! > 65535)) errs.push('port: 1-65535');
  if (need('username') && (typeof input.username !== 'string' || !/^[a-z_][a-z0-9_-]{0,31}$/i.test(input.username))) errs.push('username: invalid');
  if (need('auth') && !['key', 'password', 'agent'].includes(input.auth as string)) errs.push('auth: key, password or agent');
  if (input.keyPath !== undefined && input.keyPath !== '' && !path.isAbsolute(input.keyPath.replace(/^~/, '/'))) errs.push('keyPath must be absolute or start with ~');
  return errs;
}

export async function listHosts(): Promise<HostRecord[]> {
  return [...(await load())];
}

export async function getHost(id: string): Promise<HostRecord | undefined> {
  return (await load()).find((h) => h.id === id);
}

export async function createHost(input: HostInput): Promise<HostRecord> {
  const list = await load();
  const rec: HostRecord = {
    ...(clean(input) as HostInput), id: crypto.randomBytes(6).toString('hex'), createdAt: new Date().toISOString(), sudo: !!input.sudo,
  };
  await save([...list, rec]);
  return rec;
}

export async function updateHost(id: string, patch: Partial<HostInput>): Promise<HostRecord | undefined> {
  const list = await load();
  const idx = list.findIndex((h) => h.id === id);
  if (idx < 0) return undefined;
  const cur = list[idx];
  const next: HostRecord = { ...cur, ...clean(patch) } as HostRecord;
  // Blank secret fields mean "keep the stored value"; switching auth method drops the others.
  for (const k of ['privateKey', 'passphrase', 'password'] as const) if (!patch[k]) next[k] = cur[k];
  if (next.auth !== 'key') { delete next.privateKey; delete next.passphrase; delete next.keyPath; }
  if (next.auth !== 'password') delete next.password;
  // A changed endpoint invalidates the pinned host key unless a new one was verified.
  if ((patch.host && patch.host !== cur.host) || (patch.port && patch.port !== cur.port)) next.hostKey = patch.hostKey;
  const copy = [...list];
  copy[idx] = next;
  await save(copy);
  return next;
}

export async function pinHostKey(id: string, fingerprint: string): Promise<void> {
  const list = await load();
  const h = list.find((x) => x.id === id);
  if (h && !h.hostKey) { h.hostKey = fingerprint; await save([...list]); }
}

export async function deleteHost(id: string): Promise<boolean> {
  const list = await load();
  const next = list.filter((h) => h.id !== id);
  if (next.length === list.length) return false;
  await save(next);
  return true;
}

function clean(input: Partial<HostInput>): Partial<HostInput> {
  const out: Partial<HostInput> = {};
  for (const k of ['name', 'host', 'port', 'username', 'auth', 'privateKey', 'keyPath', 'passphrase', 'password', 'sudo', 'hostKey'] as const) {
    if (input[k] !== undefined) (out as Record<string, unknown>)[k] = input[k];
  }
  if (typeof out.privateKey === 'string') out.privateKey = out.privateKey.trim() ? out.privateKey.trim() + '\n' : undefined;
  for (const k of ['passphrase', 'password', 'keyPath'] as const) if (out[k] === '') out[k] = undefined;
  return out;
}
