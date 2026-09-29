import { Download } from 'lucide-react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Console } from '../../components/Terminal';
import { Btn, cx, Input, Seg, TONE } from '../../components/ui';
import { streams, type StreamHandle } from '../../lib/api';
import { useDokku } from '../../lib/dokku';
import { download } from '../../lib/format';
import { useCurrentHost } from '../../lib/host';
import { isKeyEvent, parseEvent, parseLogLine, parseScale, type LogLine } from '../../lib/parse';
import { useUi } from '../../lib/uictx';

type Mode = 'live' | 'failed' | 'events';
const PROC_COLORS = ['#3b82f6', '#a78bfa', '#f59e0b', '#22c55e', '#ec4899', '#14b8a6'];
const LEVEL: Record<LogLine['level'], string> = { info: '#c9c9cc', warn: TONE.warn, error: TONE.bad };

export function useLogStream(hostId: string | null, args: string[] | null, parse: (line: string) => LogLine | null, deps: unknown[]) {
  const [lines, setLines] = useState<LogLine[]>([]);
  const [state, setState] = useState<'idle' | 'live' | 'ended' | 'error'>('idle');
  const [error, setError] = useState('');
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!hostId || !args) return;
    // A reconnect keeps what is already on screen; a new command starts clean.
    if (attempt === 0) setLines([]);
    setState('idle'); setError('');
    let retry: number | null = null;
    let active = true; // output that arrives after cancelling (e.g. the ^C echo) is dropped
    let buf = '';
    let pending: LogLine[] = [];
    let flush: number | null = null;
    const push = (d: string) => {
      if (!active) return;
      buf += d;
      const parts = buf.split('\n');
      buf = parts.pop() ?? '';
      for (const p of parts) { const l = parse(p); if (l) pending.push(l); }
      if (flush == null) flush = window.setTimeout(() => { flush = null; const add = pending; pending = []; setLines((ls) => [...ls, ...add].slice(-3000)); }, 80);
    };
    const h: StreamHandle = streams.start({ hostId, kind: 'dokku', args }, {
      onStart: () => { if (active) setState('live'); },
      onData: (d) => push(d),
      onExit: () => { if (!active) return; if (buf) push('\n'); setState('ended'); },
      // The console server or SSH session dropped: try again shortly.
      onError: (m) => { if (!active) return; setError(m); setState('error'); retry = window.setTimeout(() => setAttempt((a) => a + 1), 4000); },
    });
    return () => { active = false; h.kill(); if (flush != null) clearTimeout(flush); if (retry != null) clearTimeout(retry); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hostId, attempt, ...deps]);
  // Changing the command resets the reconnect counter.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => setAttempt(0), [hostId, ...deps]);
  return { lines, state, error };
}

export function LogsTab({ app }: { app: string }) {
  const host = useCurrentHost();
  const ui = useUi();
  const scale = useDokku(['ps:scale', app], (r) => Object.keys(parseScale(r.stdout)));
  const [mode, setMode] = useState<Mode>('live');
  const [filter, setFilter] = useState('all');
  const [query, setQuery] = useState('');
  const [auto, setAuto] = useState(true);
  const [num, setNum] = useState(200);
  const scroller = useRef<HTMLDivElement>(null);

  const args = mode === 'live' ? ['logs', app, '-t', '-n', String(num), ...(filter !== 'all' ? ['-p', filter] : [])] : mode === 'failed' ? ['logs:failed', app] : ['events', '-t'];
  const parse = mode === 'events' ? (l: string) => { const e = parseEvent(l); return e && isKeyEvent(e.kind) && e.text.split(/\s+/).includes(app) ? { ts: e.ts, proc: e.kind, msg: `${e.text}${e.user ? `  by ${e.user}` : ''}`, level: /fail|error/i.test(e.kind) ? 'error' as const : 'info' as const } : null; } : parseLogLine;
  const { lines, state, error } = useLogStream(host.id, args, parse, [app, mode, filter, num]);

  const procColor = useMemo(() => {
    const map = new Map<string, string>();
    (scale.data ?? []).forEach((t, i) => map.set(t, PROC_COLORS[i % PROC_COLORS.length]));
    return (proc: string) => map.get(proc.split('.')[0]) ?? (proc === 'router' || proc === 'events' ? '#8a8a90' : PROC_COLORS[[...proc].reduce((a, c) => a + c.charCodeAt(0), 0) % PROC_COLORS.length]);
  }, [scale.data]);

  const q = query.trim().toLowerCase();
  const shown = q ? lines.filter((l) => l.msg.toLowerCase().includes(q) || l.proc.toLowerCase().includes(q)) : lines;
  useEffect(() => { if (auto && scroller.current) scroller.current.scrollTop = scroller.current.scrollHeight; }, [shown.length, auto]);
  const onScroll = () => {
    const el = scroller.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (!atBottom && auto) setAuto(false);
    if (atBottom && !auto) setAuto(true);
  };
  const cmd = `dokku ${args.join(' ')}`;

  return (
    <div className="grid h-[600px] min-h-0 gap-4 [grid-template-columns:minmax(0,1.5fr)_minmax(0,1fr)] max-lg:h-auto max-lg:[grid-template-columns:1fr]">
      <div className="flex min-w-0 flex-col overflow-hidden rounded-xl border border-white/8 bg-term max-lg:h-[520px]">
        <div className="flex flex-wrap items-center gap-2 border-b border-white/8 bg-card px-3 py-2.5">
          {mode === 'live' && <Seg size="sm" mono value={filter} onChange={setFilter} options={['all', ...(scale.data ?? [])]} />}
          <Seg size="sm" value={mode} onChange={setMode} options={[{ value: 'live', label: 'live' }, { value: 'failed', label: 'logs:failed' }, { value: 'events', label: 'events' }]} />
          <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search logs" className="h-7 min-w-[120px] flex-1" />
          {mode === 'live' && <select value={num} onChange={(e) => setNum(Number(e.target.value))} className="h-7 rounded-[7px] border border-white/10 bg-field px-1.5 font-mono text-[10.5px] text-muted">{[100, 200, 500, 1000, 5000].map((n) => <option key={n} value={n}>-n {n}</option>)}</select>}
          <button type="button" onClick={() => setAuto(!auto)} className={cx('flex h-7 items-center gap-1.5 rounded-[7px] border border-white/10 px-2.5 text-[11.5px]', auto ? 'bg-elev2 text-fg' : 'bg-elev text-muted')}>
            <span className="size-1.5 rounded-full" style={{ background: auto ? TONE.ok : '#5f5f66' }} />Autoscroll
          </button>
          <Btn size="sm" className="size-7 px-0" title="Download shown lines" onClick={() => download(`${app}-${mode}.log`, shown.map((l) => `${l.ts} ${l.proc} ${l.msg}`).join('\n'))}><Download size={13} strokeWidth={1.6} /></Btn>
        </div>
        <div ref={scroller} onScroll={onScroll} className="min-h-0 flex-1 overflow-auto px-3 py-2.5 font-mono text-[11.5px] leading-[1.7]">
          {shown.map((l, i) => (
            <div key={i} className="grid gap-3 whitespace-pre-wrap break-words" style={{ gridTemplateColumns: '70px 90px 1fr' }}>
              <span className="text-dim tabular-nums">{l.ts}</span>
              <span className="truncate" style={{ color: procColor(l.proc) }}>{l.proc}</span>
              <span style={{ color: LEVEL[l.level] }}>{l.msg}</span>
            </div>
          ))}
          {state === 'error' && <div className="py-5 text-center text-bad">{error} Reconnecting…</div>}
          {shown.length === 0 && state !== 'error' && <div className="py-5 text-center text-dim">{state === 'live' ? (q ? 'No lines match.' : 'Waiting for output…') : state === 'ended' ? 'No output.' : 'Connecting…'}</div>}
        </div>
        <div className="flex justify-between gap-3 border-t border-white/8 bg-card px-3 py-1.5 font-mono text-[10.5px] text-muted">
          <span className="truncate">$ {cmd}</span>
          <span className="flex flex-none items-center gap-2">{state === 'live' && <span className="flex items-center gap-1.5 text-ok"><span className="size-[5px] animate-pulse-dot rounded-full bg-ok" />live</span>}{shown.length} lines</span>
        </div>
      </div>
      <Console app={app} className="max-lg:h-[420px]" onInteractive={(a) => ui.openTerminal({ kind: 'dokku', args: a })} />
    </div>
  );
}
