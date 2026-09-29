import 'dart:convert';
import 'dart:math';

import 'models.dart';

/// Minimal string storage, so the same code runs against the device keystore,
/// plain preferences, or memory in tests.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryStore implements KeyValueStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

String _newId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
}

final _hostName = RegExp(r'^[\w .-]{1,60}$');
final _hostAddress = RegExp(r'^[A-Za-z0-9.:\[\]-]{1,253}$');
final _userName = RegExp(r'^[a-z_][a-z0-9_-]{0,31}$', caseSensitive: false);

/// Returns what is wrong with a host's details, or an empty list.
List<String> validateHost({
  required String name,
  required String host,
  required int? port,
  required String username,
}) {
  final errs = <String>[];
  if (!_hostName.hasMatch(name)) errs.add('Name: 1 to 60 letters, digits, spaces, dots or dashes');
  if (!_hostAddress.hasMatch(host)) errs.add('Enter a hostname or IP address');
  if (port == null || port < 1 || port > 65535) errs.add('Port must be between 1 and 65535');
  if (!_userName.hasMatch(username)) errs.add('Enter a valid username');
  return errs;
}

/// Saved hosts. Addresses and settings go to plain storage; keys, passphrases
/// and passwords go to the device keystore and never anywhere else.
class HostRepository {
  HostRepository({required this.plain, required this.secure});
  final KeyValueStore plain;
  final KeyValueStore secure;

  static const _hostsKey = 'hosts.v1';
  static String _secretKey(String id) => 'host.$id.secrets';

  List<Host>? _cache;

  Future<List<Host>> load() async {
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);
    final text = await plain.read(_hostsKey);
    List<Host> hosts;
    try {
      hosts = text == null || text.isEmpty ? [] : Host.listFromJson(text);
    } on Object {
      hosts = [];
    }
    _cache = hosts;
    return List.unmodifiable(hosts);
  }

  Future<void> _save(List<Host> hosts) async {
    _cache = hosts;
    await plain.write(_hostsKey, jsonEncode([for (final h in hosts) h.toJson()]));
  }

  Future<Host?> find(String id) async {
    for (final h in await load()) {
      if (h.id == id) return h;
    }
    return null;
  }

  Future<HostSecrets> secrets(String id) async {
    final text = await secure.read(_secretKey(id));
    if (text == null || text.isEmpty) return const HostSecrets();
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      return HostSecrets(
        privateKey: j['privateKey'] as String?,
        passphrase: j['passphrase'] as String?,
        password: j['password'] as String?,
      );
    } on Object {
      return const HostSecrets();
    }
  }

  Future<void> _writeSecrets(Host h, HostSecrets s) async {
    // Only keep what the chosen sign-in method uses.
    final keep = <String, String>{
      if (h.auth == AuthMethod.key && s.hasPrivateKey) 'privateKey': '${s.privateKey!.trim()}\n',
      if (h.auth != AuthMethod.password && s.hasPassphrase) 'passphrase': s.passphrase!,
      if (h.auth == AuthMethod.password && s.hasPassword) 'password': s.password!,
    };
    if (keep.isEmpty) {
      await secure.delete(_secretKey(h.id));
    } else {
      await secure.write(_secretKey(h.id), jsonEncode(keep));
    }
  }

  Future<Host> create(Host draft, HostSecrets secrets) async {
    final host = Host(
      id: _newId(),
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      auth: draft.auth,
      keyPath: draft.keyPath,
      sudo: draft.sudo && !draft.isDokkuUser,
      hostKey: draft.hostKey,
      hostKeyType: draft.hostKeyType,
      createdAt: DateTime.now(),
    );
    await _writeSecrets(host, secrets);
    await _save([...await load(), host]);
    return host;
  }

  /// Saves changes to a host. Blank secret fields keep what is already stored.
  Future<Host> update(Host changed, HostSecrets secretUpdate) async {
    final hosts = [...await load()];
    final i = hosts.indexWhere((h) => h.id == changed.id);
    if (i < 0) throw StateError('host not found');
    final before = hosts[i];
    var next = changed.copyWith(sudo: changed.sudo && !changed.isDokkuUser);
    // A different address invalidates the remembered host key unless a new
    // one was verified along with the change.
    final moved = before.host != next.host || before.port != next.port;
    if (moved && next.hostKey == before.hostKey) {
      next = next.copyWith(hostKey: () => null, hostKeyType: () => null);
    }
    await _writeSecrets(next, (await secrets(next.id)).merge(secretUpdate));
    hosts[i] = next;
    await _save(hosts);
    return next;
  }

  Future<void> pinHostKey(String id, String type, String fingerprint) async {
    final hosts = [...await load()];
    final i = hosts.indexWhere((h) => h.id == id);
    if (i < 0 || (hosts[i].hostKey ?? '').isNotEmpty) return;
    hosts[i] = hosts[i].copyWith(hostKey: () => fingerprint, hostKeyType: () => type);
    await _save(hosts);
  }

  Future<void> delete(String id) async {
    await secure.delete(_secretKey(id));
    await _save([...await load()]..removeWhere((h) => h.id == id));
  }
}

/// What was changed from this app, newest first. Secrets are already redacted
/// from the command text before it gets here.
class ActivityLog {
  ActivityLog(this.store);
  final KeyValueStore store;

  static const _key = 'activity.v1';
  static const _limit = 300;
  List<ActivityEntry>? _cache;

  Future<List<ActivityEntry>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final text = await store.read(_key);
    try {
      return _cache = text == null || text.isEmpty
          ? []
          : [for (final j in (jsonDecode(text) as List).cast<Map<String, dynamic>>()) ActivityEntry.fromJson(j)];
    } on Object {
      return _cache = [];
    }
  }

  Future<ActivityEntry> add({
    required String hostId,
    required String command,
    required int? code,
    required int durationMs,
    String? stderr,
  }) async {
    final list = await load();
    final entry = ActivityEntry(
      id: list.fold<int>(0, (m, e) => max(m, e.id)) + 1,
      hostId: hostId,
      at: DateTime.now(),
      command: command,
      code: code,
      durationMs: durationMs,
      stderr: code == 0 || stderr == null || stderr.isEmpty
          ? null
          : (stderr.length > 2000 ? stderr.substring(stderr.length - 2000) : stderr),
    );
    final next = [entry, ...list];
    if (next.length > _limit) next.removeRange(_limit, next.length);
    _cache = next;
    await store.write(_key, jsonEncode([for (final e in next) e.toJson()]));
    return entry;
  }

  Future<void> forgetHost(String hostId) async {
    final next = [...await load()]..removeWhere((e) => e.hostId == hostId);
    _cache = next;
    await store.write(_key, jsonEncode([for (final e in next) e.toJson()]));
  }
}
