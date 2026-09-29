import type { ActivityEntry, ConnStatus, ExecResult, HandshakeStep, HostInfo, HostInput, WsClientMsg, WsServerMsg } from '../../shared/types';
import type { InstallOptions } from '../../shared/install-script';
import type { Metrics } from '../../server/scripts';

export class ApiError extends Error {
  constructor(message: string, public status: number, public body?: Record<string, unknown>) { super(message); }
}

async function req<T>(method: string, url: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: { 'X-Dokku-Console': '1', ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    credentials: 'same-origin',
  });
  const text = await res.text();
  let json: unknown = undefined;
  try { json = text ? JSON.parse(text) : undefined; } catch { /* non-json */ }
  if (!res.ok) {
    if (res.status === 401) window.dispatchEvent(new Event('dkc:unauthorized'));
    const j = json as Record<string, unknown> | undefined;
    throw new ApiError(String(j?.error ?? (text || res.statusText)), res.status, j);
  }
  return json as T;
}

export type HostWithStatus = HostInfo & { status: ConnStatus };
export type SystemInfo = Record<string, string | null>;
export type { Metrics };

export const api = {
  session: () => req<{ authRequired: boolean; authenticated: boolean }>('GET', '/api/session'),
  login: (password: string) => req<{ ok: true }>('POST', '/api/login', { password }),
  logout: () => req<{ ok: true }>('POST', '/api/logout', {}),

  hosts: () => req<HostWithStatus[]>('GET', '/api/hosts'),
  createHost: (h: HostInput) => req<HostInfo>('POST', '/api/hosts', h),
  updateHost: (id: string, h: Partial<HostInput>) => req<HostInfo>('PATCH', `/api/hosts/${id}`, h),
  deleteHost: (id: string) => req<{ ok: boolean }>('DELETE', `/api/hosts/${id}`),
  status: (id: string) => req<ConnStatus>('GET', `/api/hosts/${id}/status`),

  exec: (id: string, args: string[], opts: { stdin?: string; stdinFiles?: Record<string, string>; timeoutMs?: number } = {}) =>
    req<ExecResult>('POST', `/api/hosts/${id}/exec`, { args, ...opts }),
  batch: (id: string, commands: string[][]) => req<ExecResult[]>('POST', `/api/hosts/${id}/batch`, { commands }),

  metrics: (id: string) => req<Metrics & { at: number }>('GET', `/api/hosts/${id}/metrics`),
  system: (id: string) => req<SystemInfo>('GET', `/api/hosts/${id}/system`),
  preflight: (id: string) => req<Record<string, string>>('GET', `/api/hosts/${id}/preflight`),
  activity: (id: string) => req<ActivityEntry[]>('GET', `/api/hosts/${id}/activity`),
  dns: (hostId: string, names: string[]) =>
    req<{ hostIps: string[]; results: { name: string; addresses: string[]; cname: string | null; matches: boolean | null }[] }>('GET', `/api/dns?hostId=${encodeURIComponent(hostId)}&names=${encodeURIComponent(names.join(','))}`),
  latestDokku: () => req<{ version: string | null }>('GET', '/api/dokku-latest'),

  async testConnection(h: HostInput & { id?: string }, onStep: (s: HandshakeStep) => void): Promise<void> {
    const res = await fetch('/api/test-connection', {
      method: 'POST', headers: { 'X-Dokku-Console': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(h),
    });
    if (!res.ok || !res.body) {
      const t = await res.text();
      let msg = t;
      try { msg = JSON.parse(t).error; } catch { /* keep text */ }
      throw new ApiError(msg, res.status);
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) onStep(JSON.parse(line));
      }
    }
  },
};

// ---------------------------------------------------------------- websocket streams

export interface StreamHandlers {
  onStart?: (command: string) => void;
  onData?: (data: string, stream: 'stdout' | 'stderr') => void;
  onExit?: (code: number | null, durationMs: number, signal?: string | null) => void;
  onError?: (message: string) => void;
}

export interface StreamHandle {
  id: string;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void;
}

type StartSpec =
  | { hostId: string; kind: 'dokku'; args: string[]; pty?: { cols: number; rows: number }; stdin?: string }
  | { hostId: string; kind: 'shell'; pty: { cols: number; rows: number } }
  | { hostId: string; kind: 'install'; options: InstallOptions }
  | { hostId: string; kind: 'upgrade' };

class StreamClient {
  private ws: WebSocket | null = null;
  private opening: Promise<WebSocket> | null = null;
  private handlers = new Map<string, StreamHandlers>();
  private seq = 0;

  private connect(): Promise<WebSocket> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return Promise.resolve(this.ws);
    if (this.opening) return this.opening;
    this.opening = new Promise((resolve, reject) => {
      const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
      ws.onopen = () => { this.ws = ws; this.opening = null; resolve(ws); };
      ws.onerror = () => { this.opening = null; reject(new Error('Could not open a stream to the console server.')); };
      ws.onclose = () => {
        if (this.ws === ws) this.ws = null;
        for (const [id, h] of this.handlers) { h.onError?.('Stream connection to the console server closed.'); this.handlers.delete(id); }
      };
      ws.onmessage = (ev) => {
        const m = JSON.parse(ev.data as string) as WsServerMsg;
        const h = this.handlers.get(m.id);
        if (!h) return;
        if (m.op === 'started') h.onStart?.(m.command);
        else if (m.op === 'data') h.onData?.(m.data, m.stream);
        else if (m.op === 'exit') { this.handlers.delete(m.id); h.onExit?.(m.code, m.durationMs, m.signal); }
        else if (m.op === 'error') { this.handlers.delete(m.id); h.onError?.(m.message); }
      };
    });
    return this.opening;
  }

  private send(m: WsClientMsg) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(m));
  }

  start(spec: StartSpec, handlers: StreamHandlers): StreamHandle {
    const id = `s${++this.seq}-${Date.now().toString(36)}`;
    let sent = false;
    let killed = false;
    this.handlers.set(id, handlers);
    this.connect().then(
      () => { if (killed) return; sent = true; this.send({ op: 'start', id, ...spec } as WsClientMsg); },
      (err: Error) => { this.handlers.delete(id); if (!killed) handlers.onError?.(err.message); },
    );
    return {
      id,
      write: (data) => { if (sent && !killed) this.send({ op: 'stdin', id, data }); },
      resize: (cols, rows) => { if (sent && !killed) this.send({ op: 'resize', id, cols, rows }); },
      kill: () => {
        if (killed) return;
        killed = true;
        if (sent) this.send({ op: 'kill', id });
        else this.handlers.delete(id); // cancelled before it ever started
      },
    };
  }
}

export const streams = new StreamClient();

/** Runs a streamed command to completion, collecting output. */
export function runStreamed(spec: StartSpec, onChunk?: (data: string, stream: 'stdout' | 'stderr') => void): { handle: StreamHandle; done: Promise<ExecResult> } {
  let stdout = '';
  let stderr = '';
  let command = '';
  let handle!: StreamHandle;
  const done = new Promise<ExecResult>((resolve) => {
    handle = streams.start(spec, {
      onStart: (c) => { command = c; },
      onData: (d, s) => { if (s === 'stdout') stdout += d; else stderr += d; onChunk?.(d, s); },
      onExit: (code, durationMs, signal) => resolve({ code, signal, stdout, stderr, durationMs, command }),
      onError: (message) => resolve({ code: -1, stdout, stderr: stderr + message, durationMs: 0, command }),
    });
  });
  return { handle, done };
}
