import { useCallback, useEffect, useRef, useSyncExternalStore, type ReactNode } from 'react';
import { streams, type StreamHandle } from '../lib/api';
import { stripAnsi } from '../lib/parse';
import { TONE } from './ui';

type Spec = Parameters<typeof streams.start>[0];
export type RunState = 'idle' | 'running' | 'done' | 'failed';

interface Snapshot { state: RunState; lines: string[]; code: number | null }

/** Holds one long-running command and its output outside of React. */
class RunStore {
  snapshot: Snapshot = { state: 'idle', lines: [], code: null };
  private handle: StreamHandle | null = null;
  private listeners = new Set<() => void>();

  subscribe = (fn: () => void) => { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; };
  get = () => this.snapshot;

  private set(patch: Partial<Snapshot>) {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const l of this.listeners) l();
  }

  start(spec: Spec) {
    if (this.snapshot.state === 'running') return;
    this.set({ state: 'running', lines: [], code: null });
    let buf = '';
    const push = (d: string) => {
      buf += stripAnsi(d);
      const parts = buf.split('\n');
      buf = parts.pop() ?? '';
      if (parts.length) this.set({ lines: [...this.snapshot.lines, ...parts].slice(-5000) });
    };
    const flush = () => { if (buf) { this.set({ lines: [...this.snapshot.lines, buf] }); buf = ''; } };
    this.handle = streams.start(spec, {
      onData: push,
      onExit: (code) => { flush(); this.handle = null; this.set({ code, state: code === 0 ? 'done' : 'failed' }); },
      onError: (m) => { flush(); this.handle = null; this.set({ lines: [...this.snapshot.lines, ` !     ${m}`], state: 'failed' }); },
    });
  }

  kill() { this.handle?.kill(); }
  reset() { if (this.snapshot.state !== 'running') this.set({ state: 'idle', lines: [], code: null }); }
}

const persistent = new Map<string, RunStore>();

/**
 * Runs a long streamed command (installer, upgrade) and keeps its output.
 * With a `key` the run lives outside the component, so leaving the page and
 * coming back shows the same run instead of cancelling it.
 */
export function useStreamRun(key?: string) {
  const local = useRef<RunStore | null>(null);
  let store: RunStore;
  if (key) {
    store = persistent.get(key) ?? new RunStore();
    persistent.set(key, store);
  } else {
    store = local.current ??= new RunStore();
  }
  const snap = useSyncExternalStore(store.subscribe, store.get);

  useEffect(() => {
    if (key) return;
    const s = store;
    return () => s.kill();
  }, [key, store]);

  // Closing the tab mid-run is almost always a mistake.
  useEffect(() => {
    if (snap.state !== 'running') return;
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [snap.state]);

  const start = useCallback((spec: Spec) => store.start(spec), [store]);
  const kill = useCallback(() => store.kill(), [store]);
  const reset = useCallback(() => store.reset(), [store]);
  return { ...snap, start, kill, reset };
}

export function lineColor(l: string): string {
  if (/^=====>/.test(l)) return TONE.ok;
  if (/^\s*!\s/.test(l) || /\b(error|failed|fatal)\b/i.test(l)) return TONE.bad;
  if (/\b(warning|warn)\b|^-----> Note/i.test(l)) return TONE.warn;
  if (/^----->/.test(l)) return '#c9c9cc';
  return '#8a8a90';
}

export function StreamOutput({ lines, idle, className }: { lines: string[]; idle?: ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => { const el = ref.current; if (el && stick.current) el.scrollTop = el.scrollHeight; }, [lines.length]);
  return (
    <div ref={ref} onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40; }}
      className={`min-h-0 flex-1 overflow-auto p-3 font-mono text-[11.5px] leading-[1.7] text-soft ${className ?? ''}`}>
      {lines.map((l, i) => <div key={i} className="whitespace-pre-wrap [overflow-wrap:anywhere]" style={{ color: lineColor(l) }}>{l || ' '}</div>)}
      {lines.length === 0 && idle && <div className="text-dim">{idle}</div>}
    </div>
  );
}
