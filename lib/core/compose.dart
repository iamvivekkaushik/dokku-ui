/// Docker Compose files turned into Dokku apps. Each service with an image
/// becomes an app deployed from it with git:from-image. The apps share a
/// Docker network named after the project, on which each answers to its
/// service name, so they find each other as they do under Compose. Named
/// volumes stay Docker volumes, a directory beside the compose file becomes a
/// storage directory, the environment is set as config, and published ports
/// go behind the proxy, onto the host, or nowhere. Every step is an ordinary
/// Dokku command, shown before it runs.
library;

import 'package:yaml/yaml.dart';

import 'command.dart';
import 'parse.dart';
import 'templates.dart';

/// A variable the file refers to as `${NAME}`, or names in `environment`
/// without a value, which Compose takes from the shell.
class ComposeVariable {
  const ComposeVariable(this.name, {this.fallback, this.required = false, this.message = '', this.fromShell = false});
  final String name;

  /// What `${NAME:-fallback}` gives while it is not set, from the first
  /// reference that has one.
  final String? fallback;

  /// `${NAME:?message}` or `${NAME?message}`: Compose refuses the file without it.
  final bool required;
  final String message;

  /// Only named in `environment`: unset, it is left out of the config.
  final bool fromShell;

  /// A password or key with no default, given a random value at the start so
  /// the services that share it agree.
  bool get generated => fallback == null && _generatable(name);

  ComposeVariable merge(ComposeVariable o) => ComposeVariable(name,
      fallback: fallback ?? o.fallback,
      required: required || o.required,
      message: message.isEmpty ? o.message : message,
      fromShell: fromShell && o.fromShell);
}

const _secretWords = {'PASSWORD', 'PASSWD', 'PASS', 'SECRET', 'TOKEN', 'KEY', 'SALT'};
const _notSecretEnds = {'URL', 'URI', 'DSN', 'FILE', 'PATH', 'USER', 'USERNAME', 'NAME', 'HOST', 'PORT', 'ID', 'TYPE'};

bool _generatable(String name) {
  final words = name.toUpperCase().split('_');
  return words.any(_secretWords.contains) && !_notSecretEnds.contains(words.last);
}

final _name = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');
final _modifier = RegExp(r'^:?[-?+]');

/// Substitutes `$NAME`, `${NAME}`, and `${NAME:-default}` and its kin, the way
/// Compose does; `$$` is a literal `$`. A name missing from [values] is unset.
/// [refer] hears of every reference, those in a default that is not used as
/// well, and [missing] of every required variable that is not set.
String interpolate(String s, Map<String, String> values,
    {void Function(ComposeVariable v)? refer, void Function(ComposeVariable v)? missing}) {
  if (!s.contains(r'$')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s[i] != r'$' || i + 1 == s.length) {
      out.write(s[i++]);
      continue;
    }
    final next = s[i + 1];
    if (next == r'$') {
      out.write(r'$');
      i += 2;
    } else if (next == '{') {
      final end = _closing(s, i + 2);
      if (end < 0) {
        out.write(s.substring(i));
        break;
      }
      out.write(_braced(s.substring(i + 2, end), values, refer, missing));
      i = end + 1;
    } else {
      final m = _name.matchAsPrefix(s, i + 1);
      if (m == null) {
        out.write(s[i++]);
        continue;
      }
      refer?.call(ComposeVariable(m[0]!));
      out.write(values[m[0]!] ?? '');
      i = m.end;
    }
  }
  return out.toString();
}

/// Where the `}` is that closes a `${` whose body starts at [from], or -1.
int _closing(String s, int from) {
  var depth = 0;
  for (var i = from; i < s.length; i++) {
    if (s[i] == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      depth++;
      i++;
    } else if (s[i] == '}') {
      if (depth == 0) return i;
      depth--;
    }
  }
  return -1;
}

String _braced(String body, Map<String, String> values, void Function(ComposeVariable v)? refer, void Function(ComposeVariable v)? missing) {
  final m = _name.matchAsPrefix(body);
  final rest = m == null ? body : body.substring(m.end);
  final op = _modifier.firstMatch(rest)?[0] ?? '';
  // Not a variable Compose would read: kept as written.
  if (m == null || (rest.isNotEmpty && op.isEmpty)) return '\${$body}';
  final name = m[0]!, arg = rest.substring(op.length);
  final v = ComposeVariable(name,
      fallback: op.endsWith('-') ? arg : null, required: op.endsWith('?'), message: op.endsWith('?') ? arg.trim() : '');
  refer?.call(v);
  // Read for the names it holds, whether or not it is used.
  if (op.isNotEmpty) interpolate(arg, values, refer: refer);
  final set = values.containsKey(name), value = values[name] ?? '';
  final full = set && value.isNotEmpty;
  String use() => interpolate(arg, values, missing: missing);
  switch (op) {
    case ':-':
      return full ? value : use();
    case '-':
      return set ? value : use();
    case ':+':
      return full ? use() : '';
    case '+':
      return set ? use() : '';
    case ':?':
      if (!full) missing?.call(v);
    case '?':
      if (!set) missing?.call(v);
  }
  return value;
}

/// What becomes of a service's ports.
enum Exposure {
  /// Behind Dokku's proxy on its domain; any other published port goes on
  /// the host directly.
  web,

  /// Every published port on the host directly, as Compose does; no proxy.
  host,

  /// Reached only by the other services, on the project's network.
  internal;

  String get label => switch (this) { web => 'Web', host => 'Host ports', internal => 'Internal' };
}

/// A port in `ports` or `expose`.
class ComposePort {
  const ComposePort(this.target, {this.published, this.hostIp, this.protocol = 'tcp'});

  /// The container's port, or a range such as `8000-8010`.
  final String target;

  /// The host's port or range; null publishes on a port Docker picks.
  final String? published;
  final String? hostIp;
  final String protocol;

  /// The container's port when it is one TCP port, which the proxy can carry.
  int? get http => protocol == 'tcp' ? int.tryParse(target) : null;

  bool get loopback => const {'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(hostIp);

  /// The host's port when it is one TCP port.
  int? get hostPort => protocol == 'tcp' ? int.tryParse(published ?? '') : null;

  /// As docker's `-p` takes it.
  String get publish =>
      '${hostIp == null ? '' : '$hostIp:'}${published ?? ''}${published != null || hostIp != null ? ':' : ''}$target${protocol == 'tcp' ? '' : '/$protocol'}';
}

final _portRange = RegExp(r'^\d+(-\d+)?$');

ComposePort? _port(Object? v) {
  if (v is Map) {
    final target = _str(v['target']);
    if (target == null || !_portRange.hasMatch(target)) return null;
    final published = _str(v['published']);
    return ComposePort(target,
        published: published == null || published.isEmpty ? null : published,
        hostIp: _str(v['host_ip']),
        protocol: (_str(v['protocol']) ?? 'tcp').toLowerCase());
  }
  var s = _str(v)?.trim() ?? '';
  var protocol = 'tcp';
  final slash = s.lastIndexOf('/');
  if (slash >= 0) {
    protocol = s.substring(slash + 1).toLowerCase();
    s = s.substring(0, slash);
  }
  String? hostIp;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end < 0) return null;
    hostIp = s.substring(0, end + 1);
    s = s.substring(end + 1).replaceFirst(RegExp('^:'), '');
  }
  final parts = s.split(':');
  if (hostIp == null && parts.length == 3) hostIp = parts.removeAt(0);
  if (parts.length > 2) return null;
  final target = parts.last;
  final published = parts.length == 2 && parts.first.isNotEmpty ? parts.first : null;
  if (!_portRange.hasMatch(target) || (published != null && !_portRange.hasMatch(published))) return null;
  return ComposePort(target, published: published, hostIp: hostIp == null || hostIp.isEmpty ? null : hostIp, protocol: protocol);
}

enum MountKind {
  /// A named volume: a Docker volume, as under Compose.
  volume,

  /// An absolute path on the host, mounted as it is.
  host,

  /// A path beside the compose file, which is not on the server: a storage
  /// directory takes its place.
  project,

  /// A volume without a name, which Compose recreates with the container:
  /// left out.
  anonymous,

  /// Memory only, through docker's `--tmpfs`.
  tmpfs,
}

/// One entry of a service's `volumes`.
class ComposeMount {
  const ComposeMount(this.service, this.kind, this.target, {this.source = '', this.readOnly = false});
  final String service;
  final MountKind kind;

  /// The volume's name in the file, or the path on the host.
  final String source;
  final String target;
  final bool readOnly;

  String get id => '$service:$target';

  String get _base => source.split('/').where((p) => p.isNotEmpty).lastOrNull ?? '';

  /// `.` or `..`: the project itself, usually source code for development.
  bool get root => kind == MountKind.project && (_base == '.' || _base == '..' || _base == '~');

  /// Whether a path beside the compose file names a file, judged by its
  /// name: a config file to copy over, not data to keep.
  bool get file => kind == MountKind.project && !root && RegExp(r'^\.[^.]+$|.\.[A-Za-z0-9]{1,5}$').hasMatch(_base);

  /// Whether docker's `-v`, which Dokku runs through the shell, can take it.
  bool get usable => _safePath.hasMatch(target) && (kind != MountKind.host || _safePath.hasMatch(source));

  /// What a fresh dialog keeps: volumes, host paths and data directories,
  /// but not a file to copy, the project itself or something read-only.
  bool get keptByDefault => usable && switch (kind) {
        MountKind.volume || MountKind.host => true,
        MountKind.project => !file && !root && !readOnly,
        _ => false,
      };
}

final _safePath = RegExp(r'^/[A-Za-z0-9_./@%+,=-]*$');

ComposeMount? _mount(String service, Object? v) {
  if (v is Map) {
    final target = _str(v['target']);
    if (target == null) return null;
    final source = _str(v['source']) ?? '';
    final ro = v['read_only'] == true;
    return switch (_str(v['type']) ?? 'volume') {
      'volume' => ComposeMount(service, source.isEmpty ? MountKind.anonymous : MountKind.volume, target, source: source, readOnly: ro),
      'bind' => ComposeMount(service, source.startsWith('/') ? MountKind.host : MountKind.project, target, source: source, readOnly: ro),
      'tmpfs' => ComposeMount(service, MountKind.tmpfs, target),
      _ => null,
    };
  }
  final parts = (_str(v) ?? '').split(':');
  if (parts.first.isEmpty) return null;
  if (parts.length == 1) return ComposeMount(service, MountKind.anonymous, parts.first);
  final source = parts[0], target = parts[1];
  final ro = parts.length > 2 && parts[2].split(',').contains('ro');
  final kind = source.startsWith('/')
      ? MountKind.host
      : source.startsWith('.') || source.startsWith('~')
          ? MountKind.project
          : MountKind.volume;
  return ComposeMount(service, kind, target, source: source, readOnly: ro);
}

/// A docker flag added with docker-options:add, for the phases it names.
typedef DockerOption = ({String phases, String flag});

/// A volume declared at the top of the file.
class ComposeVolume {
  const ComposeVolume({this.name, this.external = false});

  /// The Docker volume's own name, when the file gives one.
  final String? name;

  /// Made outside Compose, and used by its name as it is.
  final bool external;
}

const _datastoreImages = {
  'postgres', 'postgresql', 'postgis', 'pgvector', 'timescaledb', 'timescaledb-ha', 'mysql', 'mariadb', 'percona-server', //
  'redis', 'redis-stack-server', 'valkey', 'keydb', 'dragonfly', 'mongo', 'mongodb', 'memcached', 'rabbitmq', 'nats',
  'eclipse-mosquitto', 'cassandra', 'etcd', 'zookeeper', 'kafka', 'clickhouse-server', 'elasticsearch', 'opensearch',
};

/// Images whose job Dokku's proxy does: they route and terminate TLS.
const _proxyImages = {'caddy', 'traefik', 'nginx-proxy', 'haproxy', 'envoy', 'nginx-proxy-manager', 'swag'};

const _restartPolicies = {'no', 'always', 'unless-stopped', 'on-failure'};

/// One service of the file, with its variables already substituted.
class ComposeService {
  const ComposeService({
    required this.name,
    this.image,
    this.build = false,
    this.environment = const {},
    this.envFiles = const [],
    this.command,
    this.entrypoint,
    this.ports = const [],
    this.expose = const [],
    this.mounts = const [],
    this.dependsOn = const [],
    this.aliases = const [],
    this.restart,
    this.memory,
    this.cpus,
    this.replicas = 1,
    this.options = const [],
    this.init = false,
    this.profiles = const [],
    this.leftOut = const [],
    this.variables = const {},
    this.missing = const [],
  });

  final String name;
  final String? image;

  /// Built from source by Compose; the server cannot do that from the file.
  final bool build;

  /// A null value is taken from the shell under Compose.
  final Map<String, String?> environment;
  final List<String> envFiles;

  /// Null keeps the image's own.
  final List<String>? command;
  final List<String>? entrypoint;
  final List<ComposePort> ports;
  final List<String> expose;
  final List<ComposeMount> mounts;

  /// Services that start first: `depends_on` and `links`.
  final List<String> dependsOn;

  /// Names it answers to besides its own: `container_name`, network aliases,
  /// and aliases other services give it in `links`.
  final List<String> aliases;

  /// For `ps:set restart-policy`.
  final String? restart;

  /// For `resource:limit`.
  final String? memory;
  final String? cpus;
  final int replicas;
  final List<DockerOption> options;

  /// Whether docker's `--init` wraps the command. Compose leaves it out
  /// unless asked, and images such as s6-overlay need to be PID 1.
  final bool init;
  final List<String> profiles;

  /// Keys that are not carried over.
  final List<String> leftOut;

  /// What it refers to, by name.
  final Map<String, ComposeVariable> variables;

  /// Required variables that are not set.
  final List<ComposeVariable> missing;

  bool get deployable => (image ?? '').isNotEmpty;

  /// Whether the file names an image, which may still come out empty while
  /// a variable it is made of is not set.
  bool get hasImage => image != null;

  /// The image with a tag, as git:from-image needs it.
  String get imageRef {
    final i = image ?? '';
    return i.contains('@') || i.split('/').last.contains(':') ? i : '$i:latest';
  }

  /// A database, cache or queue, which nothing outside the project should reach.
  bool get datastore => _datastoreImages.contains(_repo);

  String get _repo => (image ?? '').split('@').first.split('/').last.split(':').first.toLowerCase();

  /// A reverse proxy bundled with the project, which Dokku's proxy replaces:
  /// one that publishes 443, or a proxy image that publishes 80 or 443. Left
  /// out by default, since it would take the host's ports from Dokku's own.
  bool get bundledProxy =>
      ports.any((p) => p.hostPort == 443) || (_proxyImages.contains(_repo) && ports.any((p) => p.hostPort == 80 || p.hostPort == 443));

  /// Ports the proxy could send HTTP to: one TCP port each, published first.
  List<int> get httpPorts => {
        for (final p in ports)
          if (p.http != null) p.http!,
        for (final e in expose)
          if (int.tryParse(e.split('/').first) != null && !e.endsWith('/udp')) int.parse(e.split('/').first),
      }.toList();

  /// Where a fresh dialog puts it: on the web when it publishes a port,
  /// unless it is a datastore or published on the loopback only.
  Exposure get defaultExposure {
    if (ports.isEmpty || datastore || ports.every((p) => p.loopback)) return Exposure.internal;
    return httpPorts.isEmpty ? Exposure.host : Exposure.web;
  }

  /// What DOKKU_DOCKERFILE_START_CMD is set to, which Dokku appends after the
  /// image, each word quoted: Dokku evaluates it with the shell. A new
  /// entrypoint drops the image's command, as with docker.
  String? get startCommand {
    final args = [...?entrypoint?.skip(1), ...?command];
    return args.isEmpty ? null : args.map(shq).join(' ');
  }
}

/// Keys Dokku has an answer for. `x-` extensions are skipped without a word.
const _handled = {
  'image', 'build', 'environment', 'env_file', 'command', 'entrypoint', 'ports', 'expose', 'volumes', 'depends_on', //
  'links', 'networks', 'hostname', 'container_name', 'restart', 'mem_limit', 'cpus', 'deploy', 'scale', 'user',
  'working_dir', 'cap_add', 'cap_drop', 'privileged', 'devices', 'shm_size', 'extra_hosts', 'tmpfs', 'sysctls',
  'security_opt', 'ulimits', 'init', 'tty', 'stdin_open', 'stop_signal', 'group_add', 'profiles',
};

String? _str(Object? v) => v == null ? null : '$v';

List<String> _list(Object? v) => switch (v) {
      List l => [for (final x in l) if (x != null) '$x'],
      Map m => [for (final k in m.keys) '$k'],
      null => const [],
      _ => ['$v'],
    };

/// `KEY: value` or `KEY=value`, from a map or a list.
Map<String, String?> _pairs(Object? v, {String sep = '='}) {
  if (v is Map) return {for (final e in v.entries) '${e.key}': _str(e.value)};
  return {
    for (final x in _list(v))
      if (x.contains(sep)) x.substring(0, x.indexOf(sep)).trim(): x.substring(x.indexOf(sep) + 1) else x.trim(): null,
  };
}

/// `extra_hosts` as host to address: a map, or `host=ip` or `host:ip` in a list.
Map<String, String> _hosts(Object? v) {
  if (v is Map) return {for (final e in v.entries) if (e.value != null) '${e.key}': '${e.value is List ? (e.value as List).first : e.value}'};
  return {
    for (final x in _list(v))
      if (x.contains('=') || x.contains(':'))
        x.substring(0, x.indexOf(x.contains('=') ? '=' : ':')).trim(): x.substring(x.indexOf(x.contains('=') ? '=' : ':') + 1).trim(),
  };
}

/// A command as a list, or as a string split the way a shell would.
List<String>? _words(Object? v) {
  if (v == null) return null;
  if (v is List) return _list(v);
  try {
    return splitArgs('$v');
  } on ArgError {
    return '$v'.trim().split(RegExp(r'\s+'));
  }
}

final _size = RegExp(r'^(\d+(?:\.\d+)?)\s*([bkmg])?b?$', caseSensitive: false);

/// A Compose memory size (`512M`, `1.5g`, bytes) as resource:limit takes it.
String? _memory(Object? v) {
  final m = _size.firstMatch(_str(v)?.trim() ?? '');
  if (m == null) return null;
  final bytes = double.parse(m[1]!) * switch ((m[2] ?? 'b').toLowerCase()) { 'k' => 1 << 10, 'm' => 1 << 20, 'g' => 1 << 30, _ => 1 };
  final mb = (bytes / (1 << 20)).ceil();
  return mb == 0 ? null : (mb % 1024 == 0 ? '${mb ~/ 1024}g' : '${mb}m');
}

String? _cpus(Object? v) {
  final s = _str(v)?.trim() ?? '';
  return RegExp(r'^\d+(\.\d+)?$').hasMatch(s) && double.parse(s) > 0 ? s : null;
}

String? _restart(Object? v) {
  final s = _str(v)?.trim() ?? '';
  return _restartPolicies.contains(s) || RegExp(r'^on-failure:\d+$').hasMatch(s) ? s : null;
}

Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : const {};

/// Plain maps and lists, with YAML merge keys (`<<: *defaults`) applied, which
/// the yaml package leaves to the reader. Explicit keys win, then the merged
/// maps in the order given.
Object? _plain(Object? node) {
  if (node is Map) {
    final out = <String, Object?>{};
    final merge = node['<<'];
    for (final m in merge is List ? merge.reversed : [merge]) {
      final p = _plain(m);
      if (p is Map<String, Object?>) out.addAll(p);
    }
    for (final e in node.entries) {
      if (e.key != '<<') out['${e.key}'] = _plain(e.value);
    }
    return out;
  }
  if (node is List) return [for (final x in node) _plain(x)];
  return node;
}

Object? _substitute(Object? node, String Function(String s) f) => switch (node) {
      String s => f(s),
      Map<String, Object?> m => {for (final e in m.entries) e.key: _substitute(e.value, f)},
      List l => [for (final x in l) _substitute(x, f)],
      _ => node,
    };

/// A compose file as read, before its variables are substituted.
class ComposeSource {
  const ComposeSource._(this._root);
  final Map<String, Object?> _root;

  /// Throws a [FormatException] for text that is not YAML or has no services.
  factory ComposeSource.parse(String text) {
    final Object? doc;
    try {
      doc = _plain(loadYaml(text));
    } on YamlException catch (e) {
      final line = e.span == null ? '' : 'Line ${e.span!.start.line + 1}: ';
      throw FormatException('$line${e.message}');
    }
    final services = doc is Map<String, Object?> ? doc['services'] : null;
    if (services is! Map<String, Object?> || services.isEmpty) throw const FormatException('It has no services.');
    final source = ComposeSource._(doc as Map<String, Object?>);
    // A shape no compose file has should fail here, not while the dialog draws.
    try {
      source.resolve();
    } on Object catch (e) {
      throw FormatException('It does not read as a compose file: $e');
    }
    return source;
  }

  /// The file with [values] substituted for its variables.
  ComposeFile resolve([Map<String, String> values = const {}]) {
    final top = <String, ComposeVariable>{};
    String sub(String s, Map<String, ComposeVariable> refs, List<ComposeVariable> missing) => interpolate(s, values, refer: (v) {
          refs[v.name] = refs[v.name]?.merge(v) ?? v;
        }, missing: (v) {
          if (!missing.any((m) => m.name == v.name)) missing.add(v);
        });
    final topMissing = <ComposeVariable>[];
    final name = _str(_substitute(_root['name'], (s) => sub(s, top, topMissing)));
    final volumes = {
      for (final e in _map(_substitute(_root['volumes'], (s) => sub(s, top, topMissing))).entries)
        e.key: ComposeVolume(
          name: _str(_map(e.value)['name']) ?? _str(_map(_map(e.value)['external'])['name']),
          external: _map(e.value)['external'] == true || _map(e.value)['external'] is Map,
        ),
    };
    final services = [
      for (final e in _map(_root['services']).entries)
        () {
          final refs = <String, ComposeVariable>{...top};
          final missing = <ComposeVariable>[...topMissing];
          final m = _map(_substitute(e.value, (s) => sub(s, refs, missing)));
          return _service(e.key, m, refs, missing);
        }(),
    ];
    // An alias one service gives another in `links` belongs to the other.
    final linked = <String, List<String>>{};
    for (final s in _map(_root['services']).entries) {
      for (final l in _list(_map(s.value)['links'])) {
        final parts = l.split(':');
        if (parts.length == 2 && parts[1] != parts[0]) (linked[parts[0]] ??= []).add(parts[1]);
      }
    }
    return ComposeFile(
      name: name,
      volumes: volumes,
      leftOut: [for (final k in _root.keys) if (const {'secrets', 'configs', 'include', 'models'}.contains(k)) k],
      services: [
        for (final s in services)
          linked[s.name] == null ? s : s._withAliases([...s.aliases, for (final a in linked[s.name]!) if (!s.aliases.contains(a)) a]),
      ],
    );
  }
}

ComposeService _service(String name, Map<String, Object?> m, Map<String, ComposeVariable> refs, List<ComposeVariable> missing) {
  final deploy = _map(m['deploy']);
  final limits = _map(_map(deploy['resources'])['limits']);
  final policy = _map(deploy['restart_policy']);
  final environment = _pairs(m['environment']);
  for (final e in environment.entries) {
    if (e.value == null) refs[e.key] = refs[e.key]?.merge(ComposeVariable(e.key, fromShell: true)) ?? ComposeVariable(e.key, fromShell: true);
  }
  final networks = m['networks'];
  final entrypoint = _words(m['entrypoint']);
  final ulimits = _map(m['ulimits']);
  final condition = _str(policy['condition']);
  final attempts = _str(policy['max_attempts']);
  final options = <DockerOption>[
    if (entrypoint != null) (phases: 'deploy,run', flag: '--entrypoint ${shq(entrypoint.firstOrNull ?? '')}'),
    if (_str(m['user']) case final u?) (phases: 'deploy,run', flag: '--user ${shq(u)}'),
    if (_str(m['working_dir']) case final w?) (phases: 'deploy,run', flag: '--workdir ${shq(w)}'),
    if (_str(m['hostname']) case final h?) (phases: 'deploy', flag: '--hostname ${shq(h)}'),
    for (final c in _list(m['cap_add'])) (phases: 'deploy', flag: '--cap-add ${shq(c)}'),
    for (final c in _list(m['cap_drop'])) (phases: 'deploy', flag: '--cap-drop ${shq(c)}'),
    if (m['privileged'] == true) (phases: 'deploy', flag: '--privileged'),
    for (final d in _list(m['devices'])) (phases: 'deploy', flag: '--device ${shq(d)}'),
    if (_str(m['shm_size']) case final s?) (phases: 'deploy', flag: '--shm-size ${shq(s)}'),
    for (final h in _hosts(m['extra_hosts']).entries) (phases: 'deploy,run', flag: '--add-host ${shq('${h.key}:${h.value}')}'),
    for (final t in _list(m['tmpfs'])) (phases: 'deploy', flag: '--tmpfs ${shq(t)}'),
    for (final s in _pairs(m['sysctls']).entries)
      if (s.value != null) (phases: 'deploy', flag: '--sysctl ${shq('${s.key}=${s.value}')}'),
    for (final s in _list(m['security_opt'])) (phases: 'deploy', flag: '--security-opt ${shq(s)}'),
    for (final u in ulimits.entries)
      (
        phases: 'deploy',
        flag: '--ulimit ${shq('${u.key}=${u.value is Map ? '${_map(u.value)['soft']}:${_map(u.value)['hard']}' : u.value}')}',
      ),
    if (m['tty'] == true) (phases: 'deploy', flag: '--tty'),
    if (m['stdin_open'] == true) (phases: 'deploy', flag: '--interactive'),
    if (_str(m['stop_signal']) case final s?) (phases: 'deploy', flag: '--stop-signal ${shq(s)}'),
    for (final g in _list(m['group_add'])) (phases: 'deploy', flag: '--group-add ${shq(g)}'),
  ];
  final mounts = [for (final v in m['volumes'] is List ? m['volumes'] as List : const []) ?_mount(name, v)];
  return ComposeService(
    name: name,
    image: _str(m['image'])?.trim(),
    build: m.containsKey('build'),
    environment: environment,
    envFiles: [for (final f in m['env_file'] is List ? m['env_file'] as List : [m['env_file']]) ?(f is Map ? _str(f['path']) : _str(f))],
    command: _words(m['command']),
    entrypoint: entrypoint,
    ports: [for (final p in m['ports'] is List ? m['ports'] as List : const []) ?_port(p)],
    expose: _list(m['expose']),
    mounts: [for (final x in mounts) if (x.kind != MountKind.tmpfs) x],
    dependsOn: {..._list(m['depends_on']), for (final l in _list(m['links'])) l.split(':').first}.toList(),
    aliases: {
      ?_str(m['container_name']),
      if (networks is Map)
        for (final n in networks.values) ..._list(_map(n)['aliases']),
    }.where((a) => a != name).toList(),
    restart: _restart(m['restart']) ??
        switch (condition) {
          'none' => 'no',
          'any' => 'always',
          'on-failure' => attempts == null ? 'on-failure' : 'on-failure:$attempts',
          _ => null,
        },
    memory: _memory(m['mem_limit']) ?? _memory(limits['memory']),
    cpus: _cpus(m['cpus']) ?? _cpus(limits['cpus']),
    replicas: int.tryParse(_str(deploy['replicas']) ?? _str(m['scale']) ?? '') ?? 1,
    options: [
      ...options,
      for (final t in mounts)
        if (t.kind == MountKind.tmpfs) (phases: 'deploy', flag: '--tmpfs ${shq(t.target)}'),
    ],
    init: m['init'] == true,
    profiles: _list(m['profiles']),
    leftOut: [
      for (final k in m.keys)
        if (!_handled.contains(k) && !k.startsWith('x-')) k,
      for (final k in deploy.keys)
        if (!const {'resources', 'restart_policy', 'replicas'}.contains(k)) 'deploy.$k',
    ],
    variables: refs,
    missing: missing,
  );
}

extension on ComposeService {
  ComposeService _withAliases(List<String> aliases) => ComposeService(
        name: name,
        image: image,
        build: build,
        environment: environment,
        envFiles: envFiles,
        command: command,
        entrypoint: entrypoint,
        ports: ports,
        expose: expose,
        mounts: mounts,
        dependsOn: dependsOn,
        aliases: aliases,
        restart: restart,
        memory: memory,
        cpus: cpus,
        replicas: replicas,
        options: options,
        init: init,
        profiles: profiles,
        leftOut: leftOut,
        variables: variables,
        missing: missing,
      );
}

/// A compose file with its variables substituted.
class ComposeFile {
  const ComposeFile({this.name, required this.services, this.volumes = const {}, this.leftOut = const []});

  /// The project's name, when the file gives one.
  final String? name;

  /// In the order of the file.
  final List<ComposeService> services;
  final Map<String, ComposeVolume> volumes;

  /// Top-level keys that are not carried over, such as `secrets`.
  final List<String> leftOut;

  ComposeService? service(String name) => services.where((s) => s.name == name).firstOrNull;

  /// Dependencies first, otherwise in the order of the file. A cycle is
  /// broken where it is found.
  List<ComposeService> get ordered {
    final byName = {for (final s in services) s.name: s};
    final seen = <String>{};
    final out = <ComposeService>[];
    void visit(ComposeService s) {
      if (!seen.add(s.name)) return;
      for (final d in s.dependsOn) {
        if (byName[d] case final t?) visit(t);
      }
      out.add(s);
    }

    services.forEach(visit);
    return out;
  }

  /// What the [selected] services refer to, in the order first met.
  Map<String, ComposeVariable> variablesOf(Set<String> selected) {
    final out = <String, ComposeVariable>{};
    for (final s in services) {
      if (!selected.contains(s.name)) continue;
      for (final v in s.variables.values) {
        out[v.name] = out[v.name]?.merge(v) ?? v;
      }
    }
    return out;
  }

  /// Every env_file the [selected] services read, with the services reading it.
  Map<String, List<String>> envFilesOf(Set<String> selected) {
    final out = <String, List<String>>{};
    for (final s in services) {
      if (!selected.contains(s.name)) continue;
      for (final f in s.envFiles) {
        (out[f] ??= []).add(s.name);
      }
    }
    return out;
  }

  /// The name of the project's network and the prefix of its apps: the
  /// file's own, or else the first service that publishes a port.
  String get defaultProject {
    final from = name ?? services.where((s) => s.deployable && s.ports.isNotEmpty).firstOrNull?.name ?? services.first.name;
    final slug = composeSlug(from);
    return slug.isEmpty ? 'compose' : slug;
  }
}

/// [s] as Dokku takes it in an app name: lowercase, with a dash for anything else.
String composeSlug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// `<project>-<service>`, or the project alone for the service named after it.
String composeAppName(String project, String service) {
  final s = composeSlug(service);
  return s == project || project.isEmpty ? s : '$project-$s';
}

/// The Docker volume a named volume becomes: its own name when the file gives
/// one or it is external, `<project>_<name>` otherwise, as Compose names it,
/// so a project Compose ran on this host finds its data.
String composeVolumeName(ComposeFile f, String project, String key) {
  final v = f.volumes[key];
  return v?.name ?? (v?.external == true ? key : '${project}_$key');
}

/// The storage directory a path beside the compose file becomes, under
/// [storageRoot]: `<project>-<path>`, in the characters Dokku allows.
String composeStorageName(String project, ComposeMount m) {
  final path = m.source.replaceFirst(RegExp(r'^(~/|(\.\.?/)+)'), '');
  final slug = path.toLowerCase().replaceAll(RegExp(m.file ? r'[^a-z0-9_.]+' : r'[^a-z0-9_]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return '$project-${slug.isEmpty ? 'data' : slug}';
}

/// What `storage:mount` is given for [m].
String composeMountSource(ComposeFile f, String project, ComposeMount m) => switch (m.kind) {
      MountKind.volume => composeVolumeName(f, project, m.source),
      MountKind.project => '$storageRoot/${composeStorageName(project, m)}',
      _ => m.source,
    };

/// What the user decided in the compose dialog.
class ComposeChoices {
  const ComposeChoices({
    required this.project,
    required this.services,
    this.exposure = const {},
    this.ports = const {},
    this.domains = const {},
    required this.mounts,
    this.values = const {},
    this.generated = const {},
    this.dotenv = '',
    this.envFiles = const {},
    this.letsencrypt = false,
    this.email = '',
  });

  /// The network's name, and the prefix of every app.
  final String project;

  /// Names of the services to deploy.
  final Set<String> services;

  /// By service; one missing here gets its [ComposeService.defaultExposure].
  final Map<String, Exposure> exposure;

  /// The container port the proxy sends HTTP to, by service.
  final Map<String, int> ports;

  /// A custom domain, by service; empty means the host's default.
  final Map<String, String> domains;

  /// [ComposeMount.id]s of the mounts to keep.
  final Set<String> mounts;

  /// The variables typed in, by name; an empty one is left out.
  final Map<String, String> values;

  /// Random values for the passwords the file names without a default.
  final Map<String, String> generated;

  /// The `.env` beside the compose file, which Compose reads for variables.
  final String dotenv;

  /// What each env_file holds, by its path in the file, besides `.env`.
  final Map<String, String> envFiles;
  final bool letsencrypt;
  final String email;

  Exposure exposureOf(ComposeService s) => exposure[s.name] ?? s.defaultExposure;

  /// The variables that are set: one typed in wins over the `.env`, which
  /// wins over a generated value. A name missing here is unset.
  Map<String, String> get effective => {
        ...generated,
        for (final e in parseEnvFile(dotenv)) e.key: e.value,
        for (final e in values.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      };

  /// What an env_file holds: the `.env` beside the compose file, or what was
  /// pasted for it.
  String envFile(String path) => isDotenv(path) ? dotenv : envFiles[path] ?? '';

  ComposeChoices copyWith({
    String? project,
    Set<String>? services,
    Map<String, Exposure>? exposure,
    Map<String, int>? ports,
    Map<String, String>? domains,
    Set<String>? mounts,
    Map<String, String>? values,
    String? dotenv,
    Map<String, String>? envFiles,
    bool? letsencrypt,
    String? email,
  }) =>
      ComposeChoices(
        project: project ?? this.project,
        services: services ?? this.services,
        exposure: exposure ?? this.exposure,
        ports: ports ?? this.ports,
        domains: domains ?? this.domains,
        mounts: mounts ?? this.mounts,
        values: values ?? this.values,
        generated: generated,
        dotenv: dotenv ?? this.dotenv,
        envFiles: envFiles ?? this.envFiles,
        letsencrypt: letsencrypt ?? this.letsencrypt,
        email: email ?? this.email,
      );
}

/// Whether an env_file is the `.env` beside the compose file.
bool isDotenv(String path) => path == '.env' || path == './.env';

/// The file as it comes: every service with an image, no profile and no
/// reverse proxy of its own, the mounts that hold data, and a random value
/// for each password it names without a default.
ComposeChoices defaultComposeChoices(ComposeSource source) {
  final bare = source.resolve();
  final all = {for (final s in bare.services) s.name};
  final generated = {for (final v in bare.variablesOf(all).values) if (v.generated) v.name: generateSecret()};
  final f = source.resolve(generated);
  return ComposeChoices(
    project: f.defaultProject,
    services: {for (final s in f.services) if (s.hasImage && s.profiles.isEmpty && !s.bundledProxy) s.name},
    mounts: {for (final s in f.services) for (final m in s.mounts) if (m.keptByDefault) m.id},
    generated: generated,
  );
}

/// One service as it is deployed.
class ComposeApp {
  const ComposeApp(this.service, this.app,
      {required this.exposure,
      this.port,
      this.published = const [],
      this.domain = '',
      this.url = '',
      required this.env,
      this.hidden = const {},
      required this.steps});
  final ComposeService service;
  final String app;
  final Exposure exposure;

  /// The container port behind the proxy; null leaves it to Dokku, which takes
  /// the one the image exposes.
  final int? port;

  /// Ports published on the host directly.
  final List<ComposePort> published;

  /// Where it answers on the web, custom or default. Empty when it is not on it.
  final String domain;
  final String url;

  /// What `config:set` sets before the deploy, decoded.
  final Map<String, String> env;

  /// The keys of [env] the preview masks.
  final Set<String> hidden;
  final List<PlanStep> steps;
}

class ComposePlan {
  const ComposePlan(this.project, {required this.apps, required this.steps});

  /// Also the network's name.
  final String project;

  /// In the order they are deployed.
  final List<ComposeApp> apps;

  /// Every command, in order.
  final List<PlanStep> steps;
}

/// Every command the deploy runs, in order: the network, then each service
/// after the ones it depends on, created, configured and deployed in turn.
/// [vhost] is the host's global domain, which a service on the web gets a
/// subdomain of when no domain is chosen.
ComposePlan planCompose(ComposeFile f, ComposeChoices c, {required String vhost}) {
  final project = c.project.trim();
  // Masked in the preview wherever they turn up.
  final secrets = {
    for (final e in c.effective.entries)
      if (isSecretKey(e.key) && e.value.length >= 6) e.value,
    for (final text in c.envFiles.values)
      for (final e in parseEnvFile(text))
        if (isSecretKey(e.key) && e.value.length >= 6) e.value,
  };
  final apps = [
    for (final s in f.ordered)
      if (c.services.contains(s.name) && s.deployable) _planApp(f, c, s, project, vhost, secrets),
  ];
  return ComposePlan(project, apps: apps, steps: [
    RunStep(['network:create', project], unless: ['network:exists', project]),
    for (final a in apps) ...a.steps,
    if (c.letsencrypt && apps.any((a) => a.exposure == Exposure.web)) RunStep(['letsencrypt:cron-job', '--add'], quiet: true),
  ]);
}

/// The container port behind the proxy, for a service on the web, and the
/// ports published on the host directly: every one for host ports, the others
/// for the web.
({int? port, List<ComposePort> published}) _exposed(ComposeService s, ComposeChoices c) {
  final exposure = c.exposureOf(s);
  final port = exposure == Exposure.web ? c.ports[s.name] ?? s.httpPorts.firstOrNull : null;
  return (
    port: port,
    published: switch (exposure) {
      Exposure.web => [for (final p in s.ports) if (p.http == null || p.http != port) p],
      Exposure.host => s.ports,
      Exposure.internal => const <ComposePort>[],
    },
  );
}

ComposeApp _planApp(ComposeFile f, ComposeChoices c, ComposeService s, String project, String vhost, Set<String> secrets) {
  final app = composeAppName(project, s.name);
  final exposure = c.exposureOf(s);
  final web = exposure == Exposure.web;
  final (:port, :published) = _exposed(s, c);
  final custom = (c.domains[s.name] ?? '').trim();
  final domain = web ? (custom.isEmpty ? '$app.$vhost' : custom) : '';
  final url = web ? '${c.letsencrypt ? 'https' : 'http'}://$domain' : '';
  final mounts = [for (final m in s.mounts) if (m.usable && c.mounts.contains(m.id) && (m.kind != MountKind.anonymous)) m];
  final start = s.startCommand;
  final shell = c.effective;
  final env = <String, String>{
    for (final file in s.envFiles)
      for (final e in parseEnvFile(c.envFile(file))) e.key: e.value,
    for (final e in s.environment.entries)
      if (e.value != null) e.key: e.value! else if (shell.containsKey(e.key)) e.key: shell[e.key]!,
    'DOKKU_DOCKERFILE_START_CMD': ?start,
  };
  // Dokku sets PORT from the first port mapping, over the config: one that
  // the file sets is kept by mapping it.
  final envPort = web ? null : int.tryParse(env['PORT'] ?? '');
  return ComposeApp(s, app,
      exposure: exposure,
      port: port,
      published: published,
      domain: domain,
      url: url,
      env: env,
      hidden: {for (final e in env.entries) if (isSecretKey(e.key) || secrets.any(e.value.contains)) e.key},
      steps: [
        RunStep(['apps:create', app]),
        RunStep(['network:set', app, 'initial-network', project]),
        for (final a in {s.name, ...s.aliases}) RunStep(['docker-options:add', app, 'deploy', '--network-alias ${shq(a)}']),
        for (final m in mounts) ...[
          if (m.kind == MountKind.project && !m.file) RunStep(['storage:ensure-directory', '--chown', 'false', composeStorageName(project, m)]),
          RunStep(['storage:mount', app, '${composeMountSource(f, project, m)}:${m.target}${m.readOnly ? ':ro' : ''}']),
        ],
        if (env.isNotEmpty) RunStep(configSetArgs(app, env)),
        if (port != null) RunStep(['ports:set', app, 'http:80:$port']) else if (envPort != null) RunStep(['ports:set', app, 'http:$envPort:$envPort']),
        for (final p in published) RunStep(['docker-options:add', app, 'deploy', '-p ${p.publish}']),
        // Two containers cannot hold one host port, nor should two write to
        // one volume: Dokku then stops the old container before the new one.
        if (published.isNotEmpty || mounts.any((m) => !m.readOnly)) RunStep(['checks:disable', app, 'web']),
        if (!web) RunStep(['proxy:disable', app]),
        for (final o in s.options) RunStep(['docker-options:add', app, o.phases, o.flag]),
        if (!s.init) RunStep(['scheduler-docker-local:set', app, 'init-process', 'false']),
        if (s.restart != null) RunStep(['ps:set', app, 'restart-policy', s.restart!]),
        if (s.memory != null || s.cpus != null)
          RunStep(['resource:limit', if (s.memory != null) ...['--memory', s.memory!], if (s.cpus != null) ...['--cpu', s.cpus!], app]),
        if (s.replicas > 1 && published.isEmpty) RunStep(['ps:scale', '--skip-deploy', app, 'web=${s.replicas}']),
        if (web && custom.isNotEmpty) RunStep(['domains:set', app, custom]),
        RunStep(['git:from-image', app, s.imageRef]),
        if (web && c.letsencrypt) ...[
          RunStep(['letsencrypt:set', app, 'email', c.email.trim()]),
          RunStep(['letsencrypt:enable', app], timeout: const Duration(minutes: 10)),
        ],
      ]);
}

const _mask = '•••';

/// The commands as they will run, for reading: config values decoded and
/// secrets hidden, each service's commands under its name.
String describeComposePlan(ComposePlan p) {
  String line(PlanStep s) => '\$ ${s.unless == null ? '' : '${displayCommand(s.unless!)} || '}${displayCommand(s.args)}';
  final first = p.apps.isEmpty ? p.steps.length : p.steps.indexOf(p.apps.first.steps.first);
  final last = p.apps.isEmpty ? first : p.steps.indexOf(p.apps.last.steps.last) + 1;
  return [
    for (final s in p.steps.take(first)) line(s),
    for (final a in p.apps) ...[
      '',
      '# ${a.service.name}: ${a.service.imageRef}',
      for (final s in a.steps)
        if (s.args.first == 'config:set')
          '\$ dokku config:set --no-restart ${a.app} ${[for (final e in a.env.entries) '${e.key}=${a.hidden.contains(e.key) ? _mask : shq(e.value)}'].join(' ')}'
        else
          line(s),
    ],
    if (last < p.steps.length) '',
    for (final s in p.steps.skip(last)) line(s),
  ].join('\n');
}

const _dockerNetworks = {'bridge', 'host', 'none'};

/// Why the deploy cannot start yet, in the order to fix things.
List<String> composeProblems(ComposeFile f, ComposeChoices c, {required Set<String> plugins, required Iterable<String> apps}) {
  final project = c.project.trim();
  final selected = [for (final s in f.services) if (c.services.contains(s.name) && s.deployable) s];
  final names = [for (final s in selected) composeAppName(project, s.name)];
  final web = [for (final s in selected) if (c.exposureOf(s) == Exposure.web) s];
  final existing = apps.toSet();
  final seen = <String>{};
  final chosen = [for (final s in f.services) if (c.services.contains(s.name) && s.hasImage) s];
  final missing = <String, ComposeVariable>{for (final s in chosen) for (final v in s.missing) v.name: v};
  return [
    if (!appNamePattern.hasMatch(project)) 'Name the project with lowercase letters, digits and dashes.',
    if (_dockerNetworks.contains(project)) "$project is one of Docker's own networks. Choose another project name.",
    if (chosen.isEmpty) 'Choose at least one service to deploy.',
    if (appNamePattern.hasMatch(project))
      for (final n in names)
        if (!appNamePattern.hasMatch(n))
          '$n is too long for an app name. Shorten the project name.'
        else if (existing.contains(n))
          'An app named $n already exists.'
        else if (!seen.add(n))
          'Two services would both be the app $n.',
    for (final s in selected)
      if (_exposed(s, c).published.where((p) => p.hostPort == 80 || p.hostPort == 443).firstOrNull case final p?)
        "${s.name} publishes port ${p.hostPort} on the host, which Dokku's proxy holds. Put it on the web, or keep it internal.",
    for (final v in missing.values) 'Set ${v.name}${v.message.isEmpty ? '' : ': ${v.message}'}.',
    for (final s in chosen)
      if (s.hasImage && !s.deployable && s.missing.isEmpty) 'The image of ${s.name} comes out empty. Set the variables it is made of.',
    for (final s in web)
      if ((c.domains[s.name] ?? '').trim().isNotEmpty && !domainPattern.hasMatch(c.domains[s.name]!.trim()))
        'That does not look like a domain: ${c.domains[s.name]!.trim()}.',
    if (c.letsencrypt && web.isNotEmpty && !plugins.contains('letsencrypt')) 'The letsencrypt plugin is not installed.',
    if (c.letsencrypt && web.isNotEmpty && !emailPattern.hasMatch(c.email.trim())) "Let's Encrypt needs an email address.",
  ];
}
