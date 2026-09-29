/// Argument handling for commands sent to a remote host.
///
/// Every argument is single-quoted before it reaches the remote shell (or
/// Dokku's sshcommand wrapper, which re-splits SSH_ORIGINAL_COMMAND), so user
/// input can never break out into shell syntax.
library;

final _safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');
final _globalFlag = RegExp(r'^--[a-z][a-z-]*$');
final _subcommand = RegExp(r'^[a-z0-9][a-z0-9-]*(:[a-z0-9][a-z0-9-]*)*$');

/// POSIX single-quotes [arg] for safe interpolation into a shell command line.
String shq(String arg) {
  if (arg.isEmpty) return "''";
  if (_safe.hasMatch(arg)) return arg;
  return "'${arg.replaceAll("'", r"'\''")}'";
}

class ArgError implements Exception {
  ArgError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The first argument that is not a global flag, e.g. `apps:create`.
String subcommandOf(List<String> args) =>
    args.firstWhere((a) => !a.startsWith('--'), orElse: () => '');

/// Validates a Dokku invocation: optional global flags, a subcommand, then
/// free-form arguments.
List<String> validateDokkuArgs(List<String> args) {
  if (args.isEmpty) throw ArgError('missing dokku command');
  if (args.length > 512) throw ArgError('too many arguments');
  var seenCommand = false;
  for (final a in args) {
    if (a.length > 64 * 1024) throw ArgError('argument too long');
    if (a.contains('\u0000')) throw ArgError('NUL byte in argument');
    if (seenCommand) continue;
    if (_globalFlag.hasMatch(a)) continue;
    if (!_subcommand.hasMatch(a)) throw ArgError('invalid dokku subcommand: $a');
    seenCommand = true;
  }
  if (!seenCommand) throw ArgError('missing dokku subcommand');
  return args;
}

final _privileged = RegExp(
    r'^(plugin:(install|install-dependencies|uninstall|update|enable|disable)|ssh-keys:(add|remove))$');

/// Subcommands Dokku only allows for root.
bool isPrivileged(List<String> args) => _privileged.hasMatch(subcommandOf(args));

final _readOnly = RegExp(
    r'(^|:)(report|list|info|show|get|keys|export|exists|locked|links|app-links|help|version|output|active|inspect)$|^(logs|logs:failed|events|version|help|url|urls)$');
final _scalePair = RegExp(r'^[\w-]+=\d+$');

/// Read-only commands are not recorded in the activity log.
bool isReadOnly(List<String> args) {
  final sub = subcommandOf(args);
  if (sub == 'ps:scale') return !args.any(_scalePair.hasMatch);
  return _readOnly.hasMatch(sub);
}

const _mask = '•••';
final _configPair = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)=');
final _passwordFlag = RegExp(r'^(-p|--password|-r|--root-password)$');

final _urlPassword = RegExp(r'^([a-z][a-z0-9+.-]*://[^/\s:@]*):[^/\s@]+@', caseSensitive: false);
final _urlToken = RegExp(r'^(https?://)[^/\s:@]+@', caseSensitive: false);

/// Hides the password in `https://user:password@host/…`, and a token given in
/// place of the user name. `ssh://git@host` keeps its user name.
String redactUrl(String value) {
  final password = _urlPassword.firstMatch(value);
  if (password != null) return '${password[1]}:$_mask@${value.substring(password.end)}';
  final token = _urlToken.firstMatch(value);
  if (token != null) return '${token[1]}$_mask@${value.substring(token.end)}';
  return value;
}

/// Hides secret values when a command is shown on screen or written to the
/// activity log. The real arguments are still sent to the host unchanged.
List<String> redactArgs(List<String> args) {
  final i = args.indexWhere((a) => !a.startsWith('--'));
  if (i < 0) return args;
  final sub = args[i];
  final out = args.map(redactUrl).toList();
  void maskAt(int index) {
    if (index < out.length) out[index] = _mask;
  }

  if (sub == 'config:set') {
    for (var k = i + 1; k < out.length; k++) {
      final m = _configPair.firstMatch(out[k]);
      if (m != null) out[k] = '${m[1]}=$_mask';
    }
  } else if (sub.endsWith(':backup-auth')) {
    maskAt(i + 2);
    maskAt(i + 3);
  } else if (sub.endsWith(':backup-set-encryption')) {
    maskAt(i + 2);
  } else if (sub == 'registry:login') {
    final positional = <int>[
      for (var k = i + 1; k < out.length; k++)
        if (!out[k].startsWith('--')) k
    ];
    if (positional.length >= 3) out[positional[2]] = _mask;
  } else if (sub.endsWith(':create')) {
    for (var k = i + 1; k < out.length - 1; k++) {
      if (_passwordFlag.hasMatch(out[k])) out[k + 1] = _mask;
    }
  } else if (sub == 'letsencrypt:set' &&
      i + 3 < out.length &&
      out[i + 2].startsWith('dns-provider-')) {
    out[i + 3] = _mask;
  }
  return out;
}

/// What the user sees for a Dokku invocation.
String displayCommand(List<String> args) =>
    'dokku ${redactArgs(args).map((a) => a.endsWith(_mask) ? a : shq(a)).join(' ')}';

/// Builds the remote command line for a Dokku invocation.
///
/// When logged in as the `dokku` user the SSH forced command prepends `dokku`
/// itself, so only the arguments are sent.
String remoteCommand(List<String> args, {required String username, required bool sudo}) {
  final quoted = args.map(shq).join(' ');
  if (username == 'dokku') return quoted;
  final useSudo = sudo || (isPrivileged(args) && username != 'root');
  // Run from / so the dokku user, which cannot read the login user's home,
  // does not print working-directory warnings.
  return 'cd / && ${useSudo ? 'sudo -n ' : ''}dokku $quoted';
}

/// Shell-like word splitting that honours quotes and backslashes.
List<String> splitArgs(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  String? quote;
  var has = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
        cur.write(line[++i]);
      } else {
        cur.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      has = true;
    } else if (c == r'\' && i + 1 < line.length) {
      cur.write(line[++i]);
      has = true;
    } else if (c.trim().isEmpty) {
      if (cur.isNotEmpty || has) out.add(cur.toString());
      cur.clear();
      has = false;
    } else {
      cur.write(c);
      has = true;
    }
  }
  if (quote != null) throw ArgError('unterminated quote');
  if (cur.isNotEmpty || has) out.add(cur.toString());
  return out;
}
