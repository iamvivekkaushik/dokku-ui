import { FitAddon } from '@xterm/addon-fit';
import { Terminal as XTerm } from '@xterm/xterm';
import * as Dialog from '@radix-ui/react-dialog';
import { useQueryClient } from '@tanstack/react-query';
import { TerminalSquare, X } from 'lucide-react';
import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { runStreamed, streams } from '../lib/api';
import { useHost } from '../lib/host';
import { stripAnsi } from '../lib/parse';
import { Badge, IconBtn, Kbd, TONE } from './ui';

export type TerminalSpec = { kind: 'shell' } | { kind: 'dokku'; args: string[] };

export function TerminalModal({ spec, title, onClose }: { spec: TerminalSpec; title: string; onClose: () => void }) {
  const { host } = useHost();
  const qc = useQueryClient();
  // The dialog body mounts through a portal a render later, so track the element in state.
  const [el, setEl] = useState<HTMLDivElement | null>(null);
  const [state, setState] = useState<'connecting' | 'live' | 'exited'>('connecting');
  const [exitCode, setExitCode] = useState<number | null>(null);

  useEffect(() => {
    if (!host || !el) return;
    const term = new XTerm({
      fontFamily: '"Geist Mono", ui-monospace, monospace', fontSize: 12, lineHeight: 1.35, cursorBlink: true, allowProposedApi: false,
      theme: { background: '#0c0c0e', foreground: '#c9c9cc', cursor: '#ededef', selectionBackground: 'rgba(255,255,255,.18)', black: '#0a0a0b', green: '#22c55e', red: '#ef4444', yellow: '#f59e0b', blue: '#3b82f6', magenta: '#a78bfa', brightBlack: '#5f5f66' },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(el);
    fit.fit();
    term.focus();
    // Radix moves focus into the dialog on open; take it back for the terminal afterwards.
    const focusTimer = setTimeout(() => term.focus(), 50);
    let active = true;
    const pty = { cols: term.cols, rows: term.rows };
    const handle = streams.start(spec.kind === 'shell' ? { hostId: host.id, kind: 'shell', pty } : { hostId: host.id, kind: 'dokku', args: spec.args, pty }, {
      onStart: (cmd) => { if (!active) return; setState('live'); term.write(`\x1b[90m$ ${cmd}\x1b[0m\r\n`); },
      onData: (d) => { if (active) term.write(d); },
      onExit: (code) => {
        if (!active) return;
        setState('exited'); setExitCode(code);
        term.write(`\r\n\x1b[90m[process exited${code != null ? ` with code ${code}` : ''}]\x1b[0m\r\n`);
        qc.invalidateQueries({ queryKey: ['dokku', host.id] });
      },
      onError: (m) => { if (!active) return; setState('exited'); term.write(`\r\n\x1b[31m${m}\x1b[0m\r\n`); },
    });
    const sub = term.onData((d) => handle.write(d));
    const ro = new ResizeObserver(() => {
      try { fit.fit(); handle.resize(term.cols, term.rows); } catch { /* disposed */ }
    });
    ro.observe(el);
    return () => { active = false; clearTimeout(focusTimer); ro.disconnect(); sub.dispose(); handle.kill(); term.dispose(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [host?.id, el]);

  return (
    <Dialog.Root open onOpenChange={(v) => !v && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-bg/60 backdrop-blur-[3px]" />
        <div className="pointer-events-none fixed inset-0 z-50 grid place-items-center p-6">
          <Dialog.Content aria-describedby={undefined} onEscapeKeyDown={(e) => e.preventDefault()} onOpenAutoFocus={(e) => e.preventDefault()}
            className="pointer-events-auto flex h-[min(620px,calc(100vh-48px))] w-full max-w-[980px] animate-pop flex-col overflow-hidden rounded-[14px] border border-white/10 bg-term shadow-[0_20px_60px_rgba(0,0,0,.5)]">
            <div className="flex flex-none items-center gap-2.5 border-b border-white/8 bg-card px-3 py-2.5">
              <TerminalSquare size={14} strokeWidth={1.6} />
              <Dialog.Title className="m-0 min-w-0 flex-1 truncate text-[12.5px] font-semibold">{title}</Dialog.Title>
              <span className="font-mono text-[10.5px] text-muted max-sm:hidden">{host?.username}@{host?.name}</span>
              {state === 'live' && <Badge tone="ok" mono pulse>live</Badge>}
              {state === 'connecting' && <Badge tone="info" mono>connecting</Badge>}
              {state === 'exited' && <Badge tone={exitCode === 0 ? 'mute' : 'bad'} mono>exited{exitCode != null ? ` ${exitCode}` : ''}</Badge>}
              <IconBtn title="Close terminal" onClick={onClose}><X size={13} /></IconBtn>
            </div>
            <div ref={setEl} className="min-h-0 flex-1" />
            <div className="flex-none border-t border-white/8 bg-card px-3 py-1.5 text-[10.5px] text-muted">Escape is sent to the remote program. Close with the × button.</div>
          </Dialog.Content>
        </div>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/** Shell-like word splitting that honours single/double quotes and backslashes. */
export function splitArgs(line: string): string[] {
  const out: string[] = [];
  let cur = '';
  let q: '"' | "'" | null = null;
  let has = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === q) q = null;
      else if (c === '\\' && q === '"' && i + 1 < line.length) cur += line[++i];
      else cur += c;
    } else if (c === '"' || c === "'") { q = c; has = true; }
    else if (c === '\\' && i + 1 < line.length) { cur += line[++i]; has = true; }
    else if (/\s/.test(c)) { if (cur || has) out.push(cur); cur = ''; has = false; }
    else { cur += c; has = true; }
  }
  if (q) throw new Error('unterminated quote');
  if (cur || has) out.push(cur);
  return out;
}

interface ConsoleLine { text: string; kind: 'prompt' | 'out' | 'err' | 'info' }

/** Line-oriented dokku console: each line is run as a dokku command. */
export function Console({ app, onInteractive, className }: { app?: string; onInteractive: (args: string[]) => void; className?: string }) {
  const { host } = useHost();
  const qc = useQueryClient();
  const [lines, setLines] = useState<ConsoleLine[]>([{ text: `Type a dokku command, e.g. ps:report${app ? ` ${app}` : ''}. "enter" and "run" open an interactive terminal.`, kind: 'info' }]);
  const [cmd, setCmd] = useState('');
  const [hist, setHist] = useState<string[]>([]);
  const [hIdx, setHIdx] = useState(-1);
  const [running, setRunning] = useState<(() => void) | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const prompt = `${host?.username ?? 'dokku'}@${host?.name ?? 'host'}:~$`;

  useEffect(() => { scroller.current?.scrollTo({ top: scroller.current.scrollHeight }); }, [lines]);

  const push = useCallback((l: ConsoleLine) => setLines((ls) => [...ls.slice(-2000), l]), []);

  const exec = () => {
    const line = cmd.trim();
    if (!line || !host || running) return;
    setHist((h) => [...h.filter((x) => x !== line), line].slice(-100));
    setHIdx(-1);
    setCmd('');
    push({ text: `${prompt} ${line}`, kind: 'prompt' });
    if (line === 'clear') { setLines([]); return; }
    let args: string[];
    try { args = splitArgs(line); } catch (e) { push({ text: (e as Error).message, kind: 'err' }); return; }
    if (args[0] === 'dokku') args = args.slice(1);
    const sub = args.find((a) => !a.startsWith('--'));
    if (!sub) { push({ text: 'missing command', kind: 'err' }); return; }
    if (sub === 'enter' || sub === 'shell' || (sub === 'run' && !args.includes('--no-tty') && !args.includes('--detach'))) {
      push({ text: 'Opening interactive terminal…', kind: 'info' });
      onInteractive(args);
      return;
    }
    const { handle, done } = runStreamed({ hostId: host.id, kind: 'dokku', args }, (d, s) => {
      for (const t of stripAnsi(d).replace(/\n$/, '').split('\n')) push({ text: t, kind: s === 'stderr' ? 'err' : 'out' });
    });
    setRunning(() => handle.kill);
    done.then((r) => {
      setRunning(null);
      if (r.code !== 0) push({ text: `exit ${r.code ?? '?'}`, kind: 'err' });
      qc.invalidateQueries({ queryKey: ['dokku', host.id] });
    });
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') exec();
    else if (e.key === 'ArrowUp' && hist.length) {
      e.preventDefault();
      const i = hIdx < 0 ? hist.length - 1 : Math.max(0, hIdx - 1);
      setHIdx(i); setCmd(hist[i]);
    } else if (e.key === 'ArrowDown' && hIdx >= 0) {
      e.preventDefault();
      const i = hIdx + 1;
      if (i >= hist.length) { setHIdx(-1); setCmd(''); } else { setHIdx(i); setCmd(hist[i]); }
    } else if (e.key === 'c' && e.ctrlKey && running) { running(); push({ text: '^C', kind: 'err' }); }
    else if (e.key === 'l' && e.ctrlKey) { e.preventDefault(); setLines([]); }
  };

  const color = { prompt: '#ededef', out: '#c9c9cc', err: TONE.bad, info: '#5f5f66' };
  return (
    <div className={`flex min-h-0 min-w-0 flex-col overflow-hidden rounded-xl border border-white/8 bg-term ${className ?? ''}`}>
      <div className="flex items-center justify-between border-b border-white/8 bg-card px-3 py-2.5">
        <span className="flex items-center gap-2 text-[12.5px] font-semibold"><TerminalSquare size={13} strokeWidth={1.6} />Console</span>
        <span className="font-mono text-[10.5px] text-muted">{host?.username}@{host?.name}{app ? ` · ${app}` : ''}</span>
      </div>
      <div ref={scroller} className="min-h-0 flex-1 overflow-auto p-3 font-mono text-[11.5px] leading-[1.7]" onClick={() => document.getElementById('dkc-console-input')?.focus()}>
        {lines.map((l, i) => <div key={i} className="whitespace-pre-wrap [overflow-wrap:anywhere]" style={{ color: color[l.kind] }}>{l.text || ' '}</div>)}
      </div>
      <div className="flex items-center gap-2 border-t border-white/8 bg-card px-3 py-2">
        <span className="font-mono text-[11.5px] text-ok">$</span>
        <input id="dkc-console-input" value={cmd} onChange={(e) => setCmd(e.target.value)} onKeyDown={onKey} spellCheck={false} autoComplete="off"
          placeholder={running ? 'running… (ctrl-c to cancel)' : `ps:report ${app ?? '<app>'}`}
          className="h-7 flex-1 border-0 bg-transparent px-1.5 font-mono text-[11.5px] text-fg focus:shadow-none" />
        <Kbd>↵</Kbd>
      </div>
    </div>
  );
}
