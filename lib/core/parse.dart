/// Parsers for Dokku's human-readable CLI output.
library;

import 'dart:convert';

import 'format.dart';

// Also drops carriage returns: PTY streams end lines with CRLF.
final _ansi = RegExp('\x1b\\[[0-9;?]*[A-Za-z]|\x1b\\][^\x07]*\x07|\r');

String stripAnsi(String s) => s.replaceAll(_ansi, '');

typedef Report = Map<String, String>;

final _sectionHeader = RegExp(r'^=====>\s+(\S+)\s');
final _row = RegExp(r'^\s+([^:]+?):\s*(.*?)\s*$');

/// Parses `=====> <name> <plugin> information` sections with `Key:   value`
/// rows. Keys are lower-cased. Returns section name → key/value map.
Map<String, Report> parseReports(String text) {
  final out = <String, Report>{};
  Report? cur;
  for (final raw in stripAnsi(text).split('\n')) {
    final h = _sectionHeader.firstMatch(raw);
    if (h != null) {
      cur = out.putIfAbsent(h[1]!, () => {});
      continue;
    }
    if (cur == null) continue;
    final m = _row.firstMatch(raw);
    if (m != null) cur[m[1]!.trim().toLowerCase()] = m[2]!;
  }
  return out;
}

Report parseReport(String text) {
  final all = parseReports(text);
  return all.isEmpty ? {} : all.values.first;
}

/// Dokku prints booleans as the strings "true" and "false".
bool isYes(String? v) => v == 'true';

final _noise = RegExp(r'^(=====>|----->|!\s)');

/// Plain list output: drops `=====>`/`----->` headers and warnings.
List<String> parseLines(String text) => stripAnsi(text)
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !_noise.hasMatch(l))
    .toList();

List<String> words(String? v) => (v ?? '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

final _scaleRow = RegExp(r'^\s*([\w-]+):\s+(\d+)\s*$');

/// `ps:scale <app>` without arguments.
Map<String, int> parseScale(String text) {
  final out = <String, int>{};
  for (final l in stripAnsi(text).split('\n')) {
    final m = _scaleRow.firstMatch(l);
    if (m != null && m[1] != 'proctype') out[m[1]!] = int.parse(m[2]!);
  }
  return out;
}

class ProcStatus {
  const ProcStatus({required this.type, required this.index, required this.state, required this.cid});
  final String type;
  final int index;
  final String state;
  final String cid;

  String get name => '$type.$index';
  bool get running => state == 'running';

  @override
  bool operator ==(Object other) =>
      other is ProcStatus && other.type == type && other.index == index && other.state == state && other.cid == cid;
  @override
  int get hashCode => Object.hash(type, index, state, cid);
  @override
  String toString() => 'ProcStatus($type.$index $state $cid)';
}

final _statusKey = RegExp(r'^status (\S+) (\d+)$');
final _statusValue = RegExp(r'^(\S+)(?:\s+\(CID:\s*(\w+)\))?');

/// "Status web 1: running (CID: 03ea8977f37)" rows from ps:report.
List<ProcStatus> procStatuses(Report r) {
  final out = <ProcStatus>[];
  r.forEach((k, v) {
    final m = _statusKey.firstMatch(k);
    if (m == null) return;
    final s = _statusValue.firstMatch(v);
    out.add(ProcStatus(type: m[1]!, index: int.parse(m[2]!), state: s?[1] ?? v, cid: s?[2] ?? ''));
  });
  out.sort((a, b) {
    final t = a.type.compareTo(b.type);
    return t != 0 ? t : a.index.compareTo(b.index);
  });
  return out;
}

enum AppHealth { running, degraded, stopped, undeployed }

AppHealth appHealth(Report? ps) {
  if (ps == null) return AppHealth.stopped;
  if (ps['deployed'] != 'true') return AppHealth.undeployed;
  final procs = procStatuses(ps);
  final up = procs.where((p) => p.running).length;
  if (procs.isEmpty) return ps['running'] == 'true' ? AppHealth.running : AppHealth.stopped;
  if (up == 0) return AppHealth.stopped;
  return up < procs.length ? AppHealth.degraded : AppHealth.running;
}

final _optionBoundary = RegExp(r'\s+(?=-{1,2}[A-Za-z])');

/// `docker-options:report` joins all options with spaces; split on option boundaries.
List<String> splitDockerOptions(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return [];
  return s.split(_optionBoundary).map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
}

class Mount {
  const Mount({required this.host, required this.container, this.options = ''});
  final String host;
  final String container;
  final String options;

  @override
  bool operator ==(Object other) =>
      other is Mount && other.host == host && other.container == container && other.options == options;
  @override
  int get hashCode => Object.hash(host, container, options);
  @override
  String toString() => 'Mount($host:$container:$options)';
}

List<Mount> parseStorage(String text) {
  final t = text.trim();
  if (t.startsWith('[')) {
    try {
      return [
        for (final m in (jsonDecode(t) as List).cast<Map<String, dynamic>>())
          Mount(
            host: '${m['host_path']}',
            container: '${m['container_path']}',
            options: '${m['volume_options'] ?? ''}',
          ),
      ];
    } on FormatException {
      // fall through to the text format
    }
  }
  return [
    for (final l in parseLines(text).where((l) => l.contains(':')))
      () {
        final p = l.split(':');
        return Mount(host: p[0], container: p.length > 1 ? p[1] : '', options: p.length > 2 ? p[2] : '');
      }(),
  ];
}

class SshKey {
  const SshKey({required this.fingerprint, required this.name, this.allowed = '', this.publicKey});
  final String fingerprint;
  final String name;
  final String allowed;
  final String? publicKey;

  String? get keyType => publicKey?.split(' ').first;
  String? get comment {
    final p = publicKey?.split(' ');
    return p != null && p.length > 2 ? p.sublist(2).join(' ') : null;
  }
}

final _nameAttr = RegExp(r'NAME="([^"]*)"');
final _allowedAttr = RegExp(r'SSHCOMMAND_ALLOWED_KEYS="([^"]*)"');

List<SshKey> parseSshKeys(String text) {
  final t = text.trim();
  if (t.startsWith('[')) {
    try {
      return [
        for (final k in (jsonDecode(t) as List).cast<Map<String, dynamic>>())
          SshKey(
            fingerprint: '${k['fingerprint']}',
            name: '${k['name']}',
            allowed: '${k['SSHCOMMAND_ALLOWED_KEYS'] ?? ''}',
            publicKey: k['public-key'] as String?,
          ),
      ];
    } on FormatException {
      // fall through to the text format
    }
  }
  return [
    for (final l in parseLines(text))
      if (l.split(RegExp(r'\s+')).first.contains(':'))
        SshKey(
          fingerprint: l.split(RegExp(r'\s+')).first,
          name: _nameAttr.firstMatch(l)?[1] ?? '',
          allowed: _allowedAttr.firstMatch(l)?[1] ?? '',
        ),
  ];
}

class PluginInfo {
  const PluginInfo({required this.name, required this.version, required this.enabled, required this.description});
  final String name;
  final String version;
  final bool enabled;
  final String description;

  bool get core => description.startsWith('dokku core ');
}

final _pluginRow = RegExp(r'^\s*(\S+)\s+(\S+)\s+(enabled|disabled)\s+(.*)$');

List<PluginInfo> parsePlugins(String text) => [
      for (final l in stripAnsi(text).split('\n'))
        if (_pluginRow.firstMatch(l) case final m?)
          PluginInfo(name: m[1]!, version: m[2]!, enabled: m[3] == 'enabled', description: m[4]!.trim()),
    ];

class CronTask {
  const CronTask({required this.id, required this.schedule, required this.command});
  final String id;
  final String schedule;
  final String command;

  @override
  bool operator ==(Object other) =>
      other is CronTask && other.id == id && other.schedule == schedule && other.command == command;
  @override
  int get hashCode => Object.hash(id, schedule, command);
  @override
  String toString() => 'CronTask($id, $schedule, $command)';
}

final _cronHeader = RegExp(r'^ID\s+Schedule', caseSensitive: false);
final _cronRow = RegExp(r'^(\S+)\s+((?:\S+\s+){4}\S+|@\S+)\s+(.*)$');

List<CronTask> parseCron(String text) {
  final t = text.trim();
  if (t.startsWith('[')) {
    try {
      return [
        for (final c in (jsonDecode(t) as List).cast<Map<String, dynamic>>())
          CronTask(
            id: '${c['id'] ?? c['ID']}',
            schedule: '${c['schedule'] ?? c['Schedule']}',
            command: '${c['command'] ?? c['Command']}',
          ),
      ];
    } on FormatException {
      // fall through to the text format
    }
  }
  return [
    for (final l in parseLines(text))
      if (!_cronHeader.hasMatch(l))
        if (_cronRow.firstMatch(l) case final m?) CronTask(id: m[1]!, schedule: m[2]!, command: m[3]!),
  ];
}

enum LogLevel { info, warn, error }

class LogLine {
  const LogLine({required this.ts, required this.proc, required this.msg, required this.level});
  final String ts;
  final String proc;
  final String msg;
  final LogLevel level;
}

final _logRow = RegExp(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s+(?:[\w.-]+)\[([\w.-]+)\]:\s?(.*)$');
final _errorWords = RegExp(r'\b(error|err|fatal|panic|exception|failed|failure)\b|^\s*!', caseSensitive: false);
final _warnWords = RegExp(r'\b(warn|warning|deprecated|retry|retrying)\b|\s(4\d\d)\s', caseSensitive: false);

LogLevel levelOf(String msg) {
  if (_errorWords.hasMatch(msg)) return LogLevel.error;
  if (_warnWords.hasMatch(msg)) return LogLevel.warn;
  return LogLevel.info;
}

/// Dart only parses up to microseconds; Docker prints nanoseconds.
DateTime? _parseTimestamp(String s) =>
    DateTime.tryParse(s.replaceFirstMapped(RegExp(r'\.(\d{6})\d+'), (m) => '.${m[1]}'));

LogLine parseLogLine(String line) {
  final clean = stripAnsi(line);
  final m = _logRow.firstMatch(clean);
  if (m == null) return LogLine(ts: '', proc: '', msg: clean, level: levelOf(clean));
  final d = _parseTimestamp(m[1]!);
  return LogLine(
    ts: d == null ? m[1]!.substring(11, 19) : clock(d.toLocal()),
    proc: m[2]!,
    msg: m[3]!,
    level: levelOf(m[3]!),
  );
}

class EventLine {
  const EventLine({required this.ts, required this.date, required this.kind, required this.text, required this.user});
  final String ts;
  final DateTime? date;
  final String kind;
  final String text;
  final String user;
}

// 2026-09-29T11:05:45.678873+00:00 host dokku-event[25606]: INVOKED: proxy-type( demo-app ) NAME=tester FINGERPRINT=...
final _eventRow =
    RegExp(r'^(\S+(?:\s+\d+\s+[\d:]+)?)\s+\S+\s+dokku(?:-event)?\[\d+\]:\s*(?:INVOKED:\s*)?([\w:-]+)\(\s*(.*?)\s*\)\s*(.*)$');
final _eventUser = RegExp(r'NAME=(\S+)');

EventLine? parseEvent(String line) {
  final l = stripAnsi(line).trim();
  if (l.isEmpty) return null;
  final m = _eventRow.firstMatch(l);
  if (m == null) return EventLine(ts: '', date: null, kind: 'event', text: l, user: '');
  final d = _parseTimestamp(m[1]!);
  return EventLine(
    ts: d == null ? m[1]! : clock(d.toLocal()),
    date: d,
    kind: m[2]!,
    text: m[3]!,
    user: _eventUser.firstMatch(m[4]!)?[1] ?? '',
  );
}

/// Dokku logs every plugin trigger, including the read-only lookups this app
/// makes. These are the ones that record an actual change.
final _keyEvent = RegExp(
    r'^(receive-app|receive-branch|deploy-source-set|(pre|post)-(deploy|delete|create|stop|start|restart|build\w*|release\w*|extract)|post-(config-update|domains-update|certs-update|certs-remove|app-clone\w*|app-rename\w*|proxy-ports-update|registry-login|container-create)|storage-(mount|unmount)\w*|scheduler-(deploy|stop|run)|network-(create|destroy)\w*)$');

bool isKeyEvent(String kind) => _keyEvent.hasMatch(kind);

final _serviceHeader = RegExp(r'^NAME\s+VERSION', caseSensitive: false);
final _serviceName = RegExp(r'^[\w.-]+$');

/// `<svc>:list` output. Newer plugins print one name per line, older ones a table.
List<String> parseServiceNames(String text) => parseLines(text)
    .where((l) => !_serviceHeader.hasMatch(l))
    .map((l) => l.split(RegExp(r'\s+')).first)
    .where(_serviceName.hasMatch)
    .toList();

final _resourceKey = RegExp(r'^(\S+) (limit|reserve) (\S+)$');

/// Groups `resource:report` keys such as "web reserve memory" by process type.
Map<String, Map<String, String>> parseResource(Report r) {
  final out = <String, Map<String, String>>{};
  r.forEach((k, v) {
    final m = _resourceKey.firstMatch(k);
    if (m != null) out.putIfAbsent(m[1]!, () => {})['${m[2]}-${m[3]}'] = v;
  });
  return out;
}

final _letsencryptRow = RegExp(r'^\s+Letsencrypt (.+?):\s*(.*?)\s*$', caseSensitive: false);

Report parseLetsencrypt(String text) => {
      for (final l in stripAnsi(text).split('\n'))
        if (_letsencryptRow.firstMatch(l) case final m?) m[1]!.toLowerCase(): m[2]!,
    };

/// Config variables Dokku sets itself, as opposed to those the user set.
const dokkuConfigKeys = {
  'DOKKU_APP_TYPE',
  'DOKKU_PROXY_PORT',
  'DOKKU_PROXY_SSL_PORT',
  'GIT_REV',
  'DOKKU_APP_RESTORE',
  'DOKKU_DOCKERFILE_START_CMD',
};

final _envPair = RegExp(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$');

List<MapEntry<String, String>> parseEnvFile(String text) {
  final out = <MapEntry<String, String>>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.replaceFirst(RegExp(r'^\s*export\s+'), '');
    if (line.trim().isEmpty || line.trim().startsWith('#')) continue;
    final m = _envPair.firstMatch(line);
    if (m == null) continue;
    var v = m[2]!;
    final doubleQuoted = v.length >= 2 && v.startsWith('"') && v.endsWith('"');
    final singleQuoted = v.length >= 2 && v.startsWith("'") && v.endsWith("'");
    if (doubleQuoted || singleQuoted) {
      v = v.substring(1, v.length - 1);
      if (doubleQuoted) v = v.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    } else {
      v = v.replaceFirst(RegExp(r'\s+#.*$'), '');
    }
    out.add(MapEntry(m[1]!, v));
  }
  return out;
}

String envQuote(String v) => RegExp(r'^[\w./:@-]*$').hasMatch(v) ? v : "'${v.replaceAll("'", r"'\''")}'";

final _secretKey =
    RegExp(r'(SECRET|TOKEN|PASSWORD|PASSWD|PASS\b|_KEY|KEY_|PRIVATE|CREDENTIAL|_URL$|DSN|AUTH|SALT|COOKIE)', caseSensitive: false);
final _notSecret = RegExp(r'^(DOKKU_PROXY_PORT|PORT)$');

bool isSecretKey(String k) => _secretKey.hasMatch(k) && !_notSecret.hasMatch(k);

final _every = RegExp(r'^\*/(\d+)$');
final _digits = RegExp(r'^\d+$');

String cronHuman(String expr) {
  if (expr.startsWith('@')) return expr.substring(1);
  final p = expr.trim().split(RegExp(r'\s+'));
  if (p.length != 5) return expr;
  final m = p[0], h = p[1], dom = p[2], mon = p[3], dow = p[4];
  final rest = dom == '*' && mon == '*' && dow == '*';
  if (_every.hasMatch(m) && h == '*' && rest) return 'every ${_every.firstMatch(m)![1]} min';
  if (m == '0' && _every.hasMatch(h) && rest) return 'every ${_every.firstMatch(h)![1]} h';
  if (_digits.hasMatch(m) && h == '*' && dom == '*') return 'hourly at :${m.padLeft(2, '0')}';
  if (_digits.hasMatch(m) && _digits.hasMatch(h) && dom == '*' && mon == '*') {
    final t = '${h.padLeft(2, '0')}:${m.padLeft(2, '0')}';
    return dow == '*' ? 'daily at $t' : 'weekly ($dow) at $t';
  }
  return expr;
}

final _versionNumber = RegExp(r'^v?\d+(\.\d+)*');

/// True when [latest] is a newer dotted version than [current]. False when
/// either is not a version, so an unknown version never looks out of date.
bool isNewerVersion(String? latest, String? current) {
  if (latest == null || current == null) return false;
  if (!_versionNumber.hasMatch(latest.trim()) || !_versionNumber.hasMatch(current.trim())) return false;
  List<int> parts(String v) =>
      v.replaceFirst(RegExp(r'^v'), '').split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Recognises output from a Dokku that lacks a command or flag.
///
/// Dokku 0.35 still lists `git:unlock` but the function behind it is gone, so
/// the shell reports `cmd-git-unlock: command not found` instead.
bool notSupported(String output) =>
    RegExp(r'is not a dokku command|Invalid flag passed|unknown flag|\bcmd-[\w-]+: command not found', caseSensitive: false)
        .hasMatch(output);
