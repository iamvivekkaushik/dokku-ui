// Argument handling for commands sent to a remote host.
//
// Every argument is single-quoted before it reaches the remote shell (or
// Dokku's sshcommand wrapper, which eval-splits SSH_ORIGINAL_COMMAND), so user
// input can never break out into shell syntax.

export { shq } from '../shared/shq';

const GLOBAL_FLAG = /^--[a-z][a-z-]*$/;
const SUBCOMMAND = /^[a-z0-9][a-z0-9-]*(:[a-z0-9][a-z0-9-]*)*$/;

export class ArgError extends Error {}

/** Validates a Dokku invocation: optional global flags, then a subcommand, then free-form args. */
export function validateDokkuArgs(args: unknown): string[] {
  if (!Array.isArray(args) || args.length === 0) throw new ArgError('args must be a non-empty array');
  if (args.length > 512) throw new ArgError('too many arguments');
  const out: string[] = [];
  let seenCommand = false;
  for (const a of args) {
    if (typeof a !== 'string') throw new ArgError('every argument must be a string');
    if (a.length > 64 * 1024) throw new ArgError('argument too long');
    if (a.includes('\0')) throw new ArgError('NUL byte in argument');
    if (!seenCommand) {
      if (GLOBAL_FLAG.test(a)) { out.push(a); continue; }
      if (!SUBCOMMAND.test(a)) throw new ArgError(`invalid dokku subcommand: ${a}`);
      seenCommand = true;
    }
    out.push(a);
  }
  if (!seenCommand) throw new ArgError('missing dokku subcommand');
  return out;
}

/** Subcommands that must run as root (via sudo when connected as a shell user). */
export function isPrivileged(args: string[]): boolean {
  const cmd = args.find((a) => !a.startsWith('--')) ?? '';
  return /^plugin:(install|install-dependencies|uninstall|update|enable|disable)$/.test(cmd)
    || /^ssh-keys:(add|remove)$/.test(cmd);
}
