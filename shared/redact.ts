// Hides secret values when a command is shown in the UI or written to the
// activity log. The real arguments are still sent to the host unchanged.

const MASK = '•••';

export function redactArgs(args: string[]): string[] {
  const i = args.findIndex((a) => !a.startsWith('--'));
  if (i < 0) return args;
  const sub = args[i];
  const out = [...args];
  const rest = (n: number) => i + n; // nth token after the subcommand

  if (sub === 'config:set') {
    for (let k = i + 1; k < out.length; k++) {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(out[k]);
      if (m) out[k] = `${m[1]}=${MASK}`;
    }
  } else if (/:backup-auth$/.test(sub)) {
    // <service> <aws-access-key-id> <aws-secret-access-key> ...
    if (out[rest(2)] !== undefined) out[rest(2)] = MASK;
    if (out[rest(3)] !== undefined) out[rest(3)] = MASK;
  } else if (/:backup-set-encryption$/.test(sub)) {
    if (out[rest(2)] !== undefined) out[rest(2)] = MASK;
  } else if (sub === 'registry:login') {
    const pos = out.slice(i + 1).filter((a) => !a.startsWith('--'));
    if (pos.length >= 3) out[out.lastIndexOf(pos[2])] = MASK;
  } else if (/:create$/.test(sub)) {
    for (let k = i + 1; k < out.length - 1; k++) {
      if (/^(-p|--password|-r|--root-password)$/.test(out[k])) out[k + 1] = MASK;
    }
  } else if (sub === 'letsencrypt:set' && /^dns-provider-/.test(out[rest(2)] ?? '') && out[rest(3)] !== undefined) {
    out[rest(3)] = MASK;
  }
  return out;
}
