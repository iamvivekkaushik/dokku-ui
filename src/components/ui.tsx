import * as Dialog from '@radix-ui/react-dialog';
import { Check, Copy, X } from 'lucide-react';
import { forwardRef, useState, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';
import { copy } from '../lib/format';

export const cx = (...c: (string | false | null | undefined)[]) => c.filter(Boolean).join(' ');

// ---------------------------------------------------------------- tones
export type Tone = 'ok' | 'warn' | 'info' | 'bad' | 'mute' | 'soft';
export const TONE: Record<Tone, string> = { ok: '#22c55e', warn: '#f59e0b', info: '#3b82f6', bad: '#ef4444', mute: '#9ca3af', soft: '#c9c9cc' };
export const tint = (tone: Tone) => ({ color: TONE[tone], background: TONE[tone] + '1f', borderColor: TONE[tone] + '42' });

// ---------------------------------------------------------------- buttons
type BtnVariant = 'primary' | 'outline' | 'secondary' | 'ghost' | 'danger' | 'dangerGhost';
type BtnSize = 'xs' | 'sm' | 'md';
const BTN_BASE = 'inline-flex items-center justify-center gap-[7px] whitespace-nowrap font-[inherit] transition-[background,opacity,color,border-color] duration-150 disabled:opacity-45 active:scale-[.98]';
const BTN_VARIANT: Record<BtnVariant, string> = {
  primary: 'border-0 bg-fg text-bg font-semibold shadow-[0_1px_2px_rgba(0,0,0,.4)] hover:opacity-[.88] disabled:bg-white/12 disabled:text-muted disabled:opacity-100',
  outline: 'border border-white/10 bg-card text-fg font-medium hover:bg-elev',
  secondary: 'border border-white/10 bg-elev text-fg hover:bg-elev2',
  ghost: 'border-0 bg-transparent text-muted hover:bg-white/8 hover:text-fg',
  danger: 'border border-bad/35 bg-bad/10 text-bad font-medium hover:bg-bad/18',
  dangerGhost: 'border border-white/10 bg-elev text-muted hover:text-bad hover:border-bad/40',
};
const BTN_SIZE: Record<BtnSize, string> = {
  xs: 'h-6 px-2 rounded-md text-[11px]',
  sm: 'h-7 px-2.5 rounded-[7px] text-xs',
  md: 'h-8 px-3 rounded-lg text-[12.5px]',
};

export const Btn = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { variant?: BtnVariant; size?: BtnSize; loading?: boolean }>(
  function Btn({ variant = 'secondary', size = 'sm', loading, className, children, disabled, ...rest }, ref) {
    return (
      <button ref={ref} type="button" disabled={disabled || loading} className={cx(BTN_BASE, BTN_VARIANT[variant], BTN_SIZE[size], className)} {...rest}>
        {loading && <Spinner size={11} />}
        {children}
      </button>
    );
  },
);

export function IconBtn({ title, onClick, children, danger, className, disabled }: { title: string; onClick?: () => void; children: ReactNode; danger?: boolean; className?: string; disabled?: boolean }) {
  return (
    <button type="button" title={title} aria-label={title} onClick={onClick} disabled={disabled}
      className={cx('grid size-[26px] place-items-center rounded-md border-0 bg-transparent text-muted transition-colors disabled:opacity-40', danger ? 'hover:bg-bad/12 hover:text-bad' : 'hover:bg-white/8 hover:text-fg', className)}>
      {children}
    </button>
  );
}

export function CopyBtn({ text, label, size = 'sm' }: { text: string; label?: string; size?: BtnSize }) {
  const [done, setDone] = useState(false);
  const onClick = () => copy(text).then(() => { setDone(true); setTimeout(() => setDone(false), 1400); });
  if (!label) return <IconBtn title={done ? 'Copied' : 'Copy'} onClick={onClick}>{done ? <Check size={13} className="text-ok" /> : <Copy size={13} strokeWidth={1.6} />}</IconBtn>;
  return <Btn size={size} onClick={onClick}>{done ? 'Copied' : label}</Btn>;
}

// ---------------------------------------------------------------- status
export function Badge({ tone, children, dot = true, pulse, mono, className }: { tone: Tone; children: ReactNode; dot?: boolean; pulse?: boolean; mono?: boolean; className?: string }) {
  return (
    <span style={tint(tone)} className={cx('inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2 py-0.5', mono ? 'font-mono text-[10.5px]' : 'text-[11px] font-medium', className)}>
      {dot && <span className={cx('size-[5px] rounded-full', pulse && 'animate-pulse-dot')} style={{ background: TONE[tone] }} />}
      {children}
    </span>
  );
}

export function Dot({ tone, children, className }: { tone: Tone; children?: ReactNode; className?: string }) {
  return (
    <span className={cx('inline-flex items-center gap-1.5 whitespace-nowrap text-[11.5px]', className)} style={{ color: TONE[tone] }}>
      <span className="size-1.5 flex-none rounded-full" style={{ background: TONE[tone] }} />
      {children}
    </span>
  );
}

export function Spinner({ size = 12 }: { size?: number }) {
  return <span className="inline-block flex-none animate-spin rounded-full border-[1.5px] border-white/20 border-t-fg" style={{ width: size, height: size }} />;
}

// ---------------------------------------------------------------- layout
export function Card({ children, className, danger }: { children: ReactNode; className?: string; danger?: boolean }) {
  return <div className={cx('min-w-0 overflow-hidden rounded-xl border bg-card', danger ? 'border-bad/30' : 'border-white/8', className)}>{children}</div>;
}

export function CardHead({ title, right, danger, className }: { title: ReactNode; right?: ReactNode; danger?: boolean; className?: string }) {
  return (
    <div className={cx('flex flex-wrap items-center justify-between gap-2 border-b px-4 py-3', danger ? 'border-bad/20' : 'border-white/8', className)}>
      <span className={cx('text-[13.5px] font-semibold tracking-[-.01em]', danger && 'text-bad')}>{title}</span>
      {right !== undefined && <div className="flex flex-wrap items-center gap-1.5 text-[11.5px] text-muted">{right}</div>}
    </div>
  );
}

/** Mono footer strip that shows the exact Dokku command the UI will run. */
export function Cmd({ children, action, className }: { children: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={cx('flex items-center gap-2.5 border-t border-white/8 bg-white/2 px-4 py-2.5 font-mono text-[11px] text-muted [overflow-wrap:anywhere]', className)}>
      <span className="min-w-0 flex-1">{children}</span>
      {action}
    </div>
  );
}

export function Row({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cx('border-t border-white/6 px-4 py-2.5', className)}>{children}</div>;
}

export function THead({ cols, children, className }: { cols: string; children: ReactNode; className?: string }) {
  return (
    <div className={cx('grid gap-3 bg-white/3 px-4 py-2 font-mono text-[10.5px] uppercase tracking-[.04em] text-muted', className)} style={{ gridTemplateColumns: cols }}>
      {children}
    </div>
  );
}

export function KV({ k, v, mono = true, className }: { k: ReactNode; v: ReactNode; mono?: boolean; className?: string }) {
  return (
    <div className={cx('flex justify-between gap-3 border-b border-white/6 py-1.5 text-xs last:border-b-0', className)}>
      <span className="whitespace-nowrap text-muted">{k}</span>
      <span className={cx('min-w-0 text-right [overflow-wrap:anywhere]', mono && 'font-mono text-[11.5px]')}>{v}</span>
    </div>
  );
}

export function Empty({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cx('m-4 rounded-[10px] border border-dashed border-white/14 bg-white/2 px-5 py-6 text-center text-xs leading-relaxed text-muted', className)}>{children}</div>;
}

export function PageHead({ eyebrow, title, right, children }: { eyebrow?: ReactNode; title: ReactNode; right?: ReactNode; children?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-4">
      <div className="flex min-w-0 flex-col gap-2">
        <div>
          {eyebrow && <div className="mb-1.5 text-[10.5px] font-semibold uppercase tracking-[.05em] text-muted">{eyebrow}</div>}
          <h1 className="m-0 text-[26px] font-semibold leading-[1.15] tracking-[-.024em]">{title}</h1>
        </div>
        {children}
      </div>
      {right && <div className="flex flex-wrap items-center gap-2">{right}</div>}
    </div>
  );
}

export function Page({ children, narrow }: { children: ReactNode; narrow?: boolean }) {
  return <div className={cx('mx-auto flex animate-rise flex-col gap-4', narrow ? 'max-w-[1180px]' : 'max-w-[1280px]')}>{children}</div>;
}

export function Grid2({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cx('grid items-start gap-4 [grid-template-columns:repeat(auto-fit,minmax(min(100%,380px),1fr))]', className)}>{children}</div>;
}

export function Col({ children }: { children: ReactNode }) {
  return <div className="flex min-w-0 flex-col gap-4">{children}</div>;
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={cx('animate-skel rounded bg-white/8', className)} />;
}

export function Kbd({ children }: { children: ReactNode }) {
  return <span className="rounded border border-white/8 bg-white/6 px-[5px] py-px font-mono text-[10px] text-muted">{children}</span>;
}

// ---------------------------------------------------------------- inputs
export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & { mono?: boolean; h?: 'sm' | 'md' }>(
  function Input({ mono = true, h = 'sm', className, ...rest }, ref) {
    return <input ref={ref} className={cx('min-w-0 border border-white/10 bg-field px-2.5 text-fg', h === 'sm' ? 'h-[30px] rounded-[7px] text-[11.5px]' : 'h-8 rounded-lg text-xs', mono ? 'font-mono' : 'font-[inherit] text-[12.5px]', className)} {...rest} />;
  },
);

export function Textarea({ className, ...rest }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={cx('min-h-[84px] resize-y rounded-lg border border-white/10 bg-field p-3 font-mono text-[11px] leading-relaxed text-fg', className)} {...rest} />;
}

export function Select({ className, children, ...rest }: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select className={cx('h-[30px] min-w-0 rounded-[7px] border border-white/10 bg-field px-2 font-mono text-[11.5px] text-fg', className)} {...rest}>{children}</select>;
}

export function Field({ label, hint, children, className, hintTone }: { label: ReactNode; hint?: ReactNode; children: ReactNode; className?: string; hintTone?: 'warn' }) {
  return (
    <label className={cx('flex min-w-0 flex-col gap-[5px] text-xs text-muted', className)}>
      {label}
      {children}
      {hint && <span className={cx('text-[11px]', hintTone === 'warn' ? 'text-warn' : 'text-dim')}>{hint}</span>}
    </label>
  );
}

export function Switch({ checked, onChange, disabled, label }: { checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={() => onChange?.(!checked)}
      className={cx('relative h-[17px] w-[30px] flex-none rounded-full border border-white/10 p-0 transition-colors duration-150 disabled:opacity-45', checked ? 'bg-fg' : 'bg-white/8')}>
      <span className={cx('absolute top-px size-[13px] rounded-full transition-[left] duration-150', checked ? 'left-[14px] bg-bg' : 'left-px bg-muted')} />
    </button>
  );
}

export function SwitchRow({ title, desc, checked, onChange, disabled, busy }: { title: ReactNode; desc?: ReactNode; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; busy?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0"><div className="text-[12.5px]">{title}</div>{desc && <div className="mt-0.5 text-[11.5px] text-muted">{desc}</div>}</div>
      <div className="flex items-center gap-2">{busy && <Spinner size={11} />}<Switch checked={checked} onChange={onChange} disabled={disabled || busy} label={typeof title === 'string' ? title : undefined} /></div>
    </div>
  );
}

export function Seg<T extends string>({ value, options, onChange, mono, full, size = 'md', className }: { value: T; options: (T | { value: T; label: ReactNode })[]; onChange: (v: T) => void; mono?: boolean; full?: boolean; size?: 'sm' | 'md'; className?: string }) {
  return (
    <div role="tablist" className={cx('flex flex-wrap gap-0.5 rounded-lg bg-white/5 p-0.5', full ? 'w-full' : 'w-fit', className)}>
      {options.map((o) => {
        const v = typeof o === 'string' ? o : o.value;
        const label = typeof o === 'string' ? o : o.label;
        const on = v === value;
        return (
          <button key={v} type="button" role="tab" aria-selected={on} onClick={() => onChange(v)}
            className={cx('whitespace-nowrap rounded-md border px-2.5 font-medium transition-colors', size === 'sm' ? 'h-6 text-[11px]' : 'h-[26px] text-xs', mono && 'font-mono font-normal', full && 'flex-1',
              on ? 'border-white/10 bg-elev2 text-fg' : 'border-transparent bg-transparent text-muted hover:text-fg')}>
            {label}
          </button>
        );
      })}
    </div>
  );
}

export function Radio({ on }: { on: boolean }) {
  return (
    <span className="grid size-[15px] flex-none place-items-center rounded-full border" style={{ borderColor: on ? '#ededef' : 'rgba(255,255,255,.2)' }}>
      <span className="size-[7px] rounded-full" style={{ background: on ? '#ededef' : 'transparent' }} />
    </span>
  );
}

export function Checkbox({ checked, onChange, children }: { checked: boolean; onChange: (v: boolean) => void; children: ReactNode }) {
  return (
    <label className="flex cursor-pointer items-center gap-2 text-xs text-soft">
      <input type="checkbox" className="peer sr-only" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span className={cx('grid size-[15px] place-items-center rounded-[4.5px] border border-white/20 peer-focus-visible:ring-2 peer-focus-visible:ring-white/30', checked ? 'bg-fg' : 'bg-transparent')}>
        {checked && <Check size={10} strokeWidth={3} className="text-bg" />}
      </span>
      {children}
    </label>
  );
}

export function Stepper({ value, onChange, min = 0, max = 50 }: { value: number; onChange: (n: number) => void; min?: number; max?: number }) {
  return (
    <div className="flex items-center justify-end gap-0.5 rounded-lg bg-white/5 p-0.5">
      <button type="button" aria-label="Decrease" onClick={() => onChange(Math.max(min, value - 1))} className="size-[26px] rounded-md border-0 bg-transparent text-fg hover:bg-white/8">−</button>
      <span className="w-8 text-center font-mono text-[13px] tabular-nums">{value}</span>
      <button type="button" aria-label="Increase" onClick={() => onChange(Math.min(max, value + 1))} className="size-[26px] rounded-md border-0 bg-transparent text-fg hover:bg-white/8">+</button>
    </div>
  );
}

// ---------------------------------------------------------------- data viz
export function TickMeter({ pct, color = '#ededef' }: { pct: number; color?: string }) {
  return (
    <div className="flex h-1.5 gap-[3px]" role="meter" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}>
      {Array.from({ length: 22 }, (_, i) => <span key={i} className="flex-1 rounded-[1px]" style={{ background: i / 22 < pct / 100 ? color : 'rgba(255,255,255,.08)' }} />)}
    </div>
  );
}

export function Sparkbars({ values, max, opacity = 0.85, empty }: { values: number[]; max: number; opacity?: number; empty?: ReactNode }) {
  const bars = [...Array(Math.max(0, 30 - values.length)).fill(null), ...values.slice(-30)];
  return (
    <div className="relative flex h-14 items-end gap-0.5 border-b border-white/8">
      {bars.map((v, i) => (
        <span key={i} className="flex-1 rounded-t-[1px]" style={{ height: v == null ? 0 : `${Math.max(4, Math.min(100, (v / (max || 1)) * 100))}%`, background: `rgba(237,237,239,${opacity})` }} title={v == null ? undefined : String(Math.round(v * 10) / 10)} />
      ))}
      {values.length === 0 && empty && <div className="absolute inset-0 grid place-items-center text-[11px] text-dim">{empty}</div>}
    </div>
  );
}

// ---------------------------------------------------------------- dialog
export function Modal({ open, onOpenChange, title, subtitle, width = 480, children, footer, header }: {
  open: boolean; onOpenChange: (v: boolean) => void; title?: ReactNode; subtitle?: ReactNode; width?: number; children: ReactNode; footer?: ReactNode; header?: ReactNode;
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-bg/60 backdrop-blur-[3px]" />
        <div className="pointer-events-none fixed inset-0 z-50 grid place-items-center p-6">
          <Dialog.Content aria-describedby={undefined} className="pointer-events-auto flex max-h-[calc(100vh-48px)] w-full animate-pop flex-col overflow-hidden rounded-[14px] border border-white/10 bg-card shadow-[0_20px_60px_rgba(0,0,0,.5)]" style={{ maxWidth: width }}>
            {header ?? (
              <div className="flex flex-none items-center justify-between gap-3 border-b border-white/8 px-5 py-4">
                <div className="min-w-0">
                  <Dialog.Title className="m-0 text-[15px] font-semibold tracking-[-.01em]">{title}</Dialog.Title>
                  {subtitle && <div className="mt-0.5 text-xs text-muted">{subtitle}</div>}
                </div>
                <Dialog.Close asChild><IconBtn title="Close"><X size={13} strokeWidth={1.8} /></IconBtn></Dialog.Close>
              </div>
            )}
            {header && <Dialog.Title className="sr-only">{title}</Dialog.Title>}
            <div className="flex min-h-0 flex-1 flex-col gap-3.5 overflow-auto overflow-x-hidden p-5">{children}</div>
            {footer && <div className="flex flex-none flex-wrap items-center justify-end gap-2 border-t border-white/8 bg-white/2 px-5 py-3.5">{footer}</div>}
          </Dialog.Content>
        </div>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function Alert({ tone = 'warn', title, children, action, className }: { tone?: 'warn' | 'bad' | 'info'; title?: ReactNode; children?: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={cx('flex items-start gap-2.5 rounded-lg border px-3 py-2.5 text-xs leading-normal', className)} style={{ background: TONE[tone] + '14', borderColor: TONE[tone] + '42', color: TONE[tone] }}>
      <div className="min-w-0 flex-1">{title && <span className="font-semibold">{title} </span>}<span style={{ color: TONE[tone] + 'cc' }}>{children}</span></div>
      {action}
    </div>
  );
}

export function Mono({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={cx('font-mono', className)}>{children}</span>;
}

export function Pre({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cx('whitespace-pre-wrap rounded-lg border border-white/8 bg-term px-3 py-2.5 font-mono text-[11px] leading-[1.7] text-soft [overflow-wrap:anywhere]', className)}>{children}</div>;
}
