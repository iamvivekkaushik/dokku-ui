export type AuthMethod = 'key' | 'password' | 'agent';

/** Host as exposed to the browser: secrets are never sent back. */
export interface HostInfo {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  auth: AuthMethod;
  keyPath?: string;
  hasPrivateKey: boolean;
  hasPassword: boolean;
  hasPassphrase: boolean;
  hostKey?: string;
  sudo: boolean;
  /** 'dokku' when logged in as the dokku user (commands are sent bare); 'shell' otherwise. */
  mode: 'dokku' | 'shell';
  createdAt: string;
}

export interface HostInput {
  name: string;
  host: string;
  port: number;
  username: string;
  auth: AuthMethod;
  privateKey?: string;
  keyPath?: string;
  passphrase?: string;
  password?: string;
  sudo?: boolean;
  hostKey?: string;
}

export interface ExecResult {
  code: number | null;
  signal?: string | null;
  stdout: string;
  stderr: string;
  durationMs: number;
  command: string;
}

export interface ConnStatus {
  state: 'connected' | 'connecting' | 'disconnected' | 'idle';
  rttMs?: number;
  error?: string;
  since?: string;
}

export interface ActivityEntry {
  id: number;
  hostId: string;
  ts: string;
  command: string;
  code: number | null;
  durationMs: number;
  ok: boolean;
  stderr?: string;
}

export interface HandshakeStep {
  step: number;
  status: 'running' | 'ok' | 'fail' | 'warn';
  text: string;
  detail?: string;
  hostKey?: string;
  dokkuVersion?: string;
}

// WebSocket protocol
export type WsClientMsg =
  | { op: 'start'; id: string; hostId: string; kind: 'dokku'; args: string[]; pty?: { cols: number; rows: number }; stdin?: string }
  | { op: 'start'; id: string; hostId: string; kind: 'shell'; pty: { cols: number; rows: number } }
  | { op: 'start'; id: string; hostId: string; kind: 'install'; options: import('./install-script').InstallOptions }
  | { op: 'start'; id: string; hostId: string; kind: 'upgrade' }
  | { op: 'stdin'; id: string; data: string }
  | { op: 'resize'; id: string; cols: number; rows: number }
  | { op: 'kill'; id: string };

export type WsServerMsg =
  | { op: 'started'; id: string; command: string }
  | { op: 'data'; id: string; stream: 'stdout' | 'stderr'; data: string }
  | { op: 'exit'; id: string; code: number | null; signal?: string | null; durationMs: number }
  | { op: 'error'; id: string; message: string };
