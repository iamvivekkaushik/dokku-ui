import 'dart:convert';

enum AuthMethod { key, keyFile, password }

/// A saved server. Secrets are stored separately, in the device keystore.
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    this.username = 'dokku',
    this.auth = AuthMethod.key,
    this.keyPath,
    this.sudo = false,
    this.hostKey,
    this.hostKeyType,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthMethod auth;

  /// Path to a private key file on this device (desktop only).
  final String? keyPath;
  final bool sudo;

  /// Pinned host key fingerprint, `SHA256:...`. Set on first connection.
  final String? hostKey;
  final String? hostKeyType;
  final DateTime createdAt;

  /// Logged in as the `dokku` user: commands are sent bare and only Dokku
  /// commands are available.
  bool get isDokkuUser => username == 'dokku';

  /// A shell user can also run host scripts, open a terminal and use root-only commands.
  bool get hasShell => !isDokkuUser;

  String get address => '$username@$host${port == 22 ? '' : ':$port'}';

  /// The git remote developers push to.
  String gitRemote(String app) => port == 22 ? 'dokku@$host:$app' : 'ssh://dokku@$host:$port/$app';

  Host copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    AuthMethod? auth,
    String? Function()? keyPath,
    bool? sudo,
    String? Function()? hostKey,
    String? Function()? hostKeyType,
  }) =>
      Host(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        auth: auth ?? this.auth,
        keyPath: keyPath != null ? keyPath() : this.keyPath,
        sudo: sudo ?? this.sudo,
        hostKey: hostKey != null ? hostKey() : this.hostKey,
        hostKeyType: hostKeyType != null ? hostKeyType() : this.hostKeyType,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (keyPath != null) 'keyPath': keyPath,
        'sudo': sudo,
        if (hostKey != null) 'hostKey': hostKey,
        if (hostKeyType != null) 'hostKeyType': hostKeyType,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Host.fromJson(Map<String, dynamic> j) => Host(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? 'dokku',
        auth: AuthMethod.values.firstWhere((a) => a.name == j['auth'], orElse: () => AuthMethod.key),
        keyPath: j['keyPath'] as String?,
        sudo: j['sudo'] as bool? ?? false,
        hostKey: j['hostKey'] as String?,
        hostKeyType: j['hostKeyType'] as String?,
        createdAt: DateTime.tryParse('${j['createdAt']}') ?? DateTime.now(),
      );

  static List<Host> listFromJson(String text) =>
      [for (final j in (jsonDecode(text) as List).cast<Map<String, dynamic>>()) Host.fromJson(j)];
}

class HostSecrets {
  const HostSecrets({this.privateKey, this.passphrase, this.password});
  final String? privateKey;
  final String? passphrase;
  final String? password;

  bool get hasPrivateKey => privateKey != null && privateKey!.trim().isNotEmpty;
  bool get hasPassphrase => passphrase != null && passphrase!.isNotEmpty;
  bool get hasPassword => password != null && password!.isNotEmpty;

  /// Blank fields in [update] mean "keep what is stored".
  HostSecrets merge(HostSecrets update) => HostSecrets(
        privateKey: update.hasPrivateKey ? update.privateKey : privateKey,
        passphrase: update.hasPassphrase ? update.passphrase : passphrase,
        password: update.hasPassword ? update.password : password,
      );
}

class ExecResult {
  const ExecResult({
    required this.code,
    this.signal,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
    required this.command,
  });
  final int? code;
  final String? signal;
  final String stdout;
  final String stderr;
  final int durationMs;
  final String command;

  bool get ok => code == 0;
  String get output => stdout + (stderr.isEmpty ? '' : '\n$stderr');
}

enum ConnState { idle, connecting, connected, disconnected }

class ConnStatus {
  const ConnStatus(this.state, {this.rttMs, this.error, this.since, this.hostKeyChanged = false});
  final ConnState state;
  final int? rttMs;
  final String? error;
  final DateTime? since;

  /// The connection was refused because the server sent a different key than
  /// the one saved. Retrying cannot fix that; the user has to review the key.
  final bool hostKeyChanged;

  static const idle = ConnStatus(ConnState.idle);
}

enum StepStatus { running, ok, fail, warn }

/// One line of the connection test shown in the connect dialog.
class HandshakeStep {
  const HandshakeStep(
    this.step,
    this.status,
    this.text, {
    this.detail,
    this.hostKey,
    this.hostKeyType,
    this.dokkuVersion,
    this.presentedKey,
  });
  final int step;
  final StepStatus status;
  final String text;
  final String? detail;
  final String? hostKey;
  final String? hostKeyType;
  final String? dokkuVersion;

  /// Set on a failed host key step: the key the server sent, which is not the saved one.
  final String? presentedKey;
}

class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.hostId,
    required this.at,
    required this.command,
    required this.code,
    required this.durationMs,
    this.stderr,
  });
  final int id;
  final String hostId;
  final DateTime at;
  final String command;
  final int? code;
  final int durationMs;
  final String? stderr;

  bool get ok => code == 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'at': at.toIso8601String(),
        'command': command,
        'code': code,
        'durationMs': durationMs,
        if (stderr != null) 'stderr': stderr,
      };

  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
        id: (j['id'] as num).toInt(),
        hostId: j['hostId'] as String,
        at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
        command: j['command'] as String,
        code: (j['code'] as num?)?.toInt(),
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        stderr: j['stderr'] as String?,
      );
}
