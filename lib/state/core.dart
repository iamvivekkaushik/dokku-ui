/// App-wide services and the saved hosts.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/platform.dart';
import '../data/ssh_service.dart';
import '../data/stores.dart';

/// Overridden in `main` with the real stores, and in tests with memory stores.
final plainStoreProvider = Provider<KeyValueStore>((_) => throw UnimplementedError('plainStoreProvider'));
final secureStoreProvider = Provider<KeyValueStore>((_) => throw UnimplementedError('secureStoreProvider'));

final hostRepositoryProvider = Provider<HostRepository>(
  (ref) => HostRepository(plain: ref.watch(plainStoreProvider), secure: ref.watch(secureStoreProvider)),
);

final activityLogProvider = Provider<ActivityLog>((ref) => ActivityLog(ref.watch(plainStoreProvider)));

final sshServiceProvider = Provider<SshService>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  final service = SshService(
    loadSecrets: (h) => repo.secrets(h.id),
    readKeyFile: keyFilesSupported ? readKeyFile : null,
    pinHostKey: (h, type, fingerprint) async {
      await repo.pinHostKey(h.id, type, fingerprint);
      ref.invalidate(hostsProvider);
    },
    onStatus: (hostId, status) => ref.read(connStatusProvider.notifier).set(hostId, status),
  );
  ref.onDispose(service.dispose);
  return service;
});

class HostsNotifier extends AsyncNotifier<List<Host>> {
  @override
  Future<List<Host>> build() => ref.watch(hostRepositoryProvider).load();

  Future<Host> add(Host draft, HostSecrets secrets) async {
    final host = await ref.read(hostRepositoryProvider).create(draft, secrets);
    ref.invalidateSelf();
    await future;
    return host;
  }

  Future<Host> edit(Host host, HostSecrets secrets) async {
    final saved = await ref.read(hostRepositoryProvider).update(host, secrets);
    ref.read(sshServiceProvider).drop(saved.id);
    ref.invalidateSelf();
    await future;
    ref.read(generationProvider(saved.id).notifier).bump();
    return saved;
  }

  Future<void> remove(String id) async {
    ref.read(sshServiceProvider).drop(id);
    await ref.read(hostRepositoryProvider).delete(id);
    await ref.read(activityLogProvider).forgetHost(id);
    ref.invalidateSelf();
    await future;
  }
}

final hostsProvider = AsyncNotifierProvider<HostsNotifier, List<Host>>(HostsNotifier.new);

/// Display preferences. Loaded once at startup so reads are synchronous.
class Prefs {
  const Prefs({this.hostId, this.appsGrid = true, this.sidebarOpen = true, this.lastApp});
  final String? hostId;
  final bool appsGrid;
  final bool sidebarOpen;
  final String? lastApp;

  Prefs copyWith({String? Function()? hostId, bool? appsGrid, bool? sidebarOpen, String? Function()? lastApp}) => Prefs(
        hostId: hostId != null ? hostId() : this.hostId,
        appsGrid: appsGrid ?? this.appsGrid,
        sidebarOpen: sidebarOpen ?? this.sidebarOpen,
        lastApp: lastApp != null ? lastApp() : this.lastApp,
      );

  Map<String, dynamic> toJson() =>
      {'hostId': hostId, 'appsGrid': appsGrid, 'sidebarOpen': sidebarOpen, 'lastApp': lastApp};

  static const _key = 'prefs.v1';

  static Future<Prefs> load(KeyValueStore store) async {
    try {
      final j = jsonDecode(await store.read(_key) ?? '{}') as Map<String, dynamic>;
      return Prefs(
        hostId: j['hostId'] as String?,
        appsGrid: j['appsGrid'] as bool? ?? true,
        sidebarOpen: j['sidebarOpen'] as bool? ?? true,
        lastApp: j['lastApp'] as String?,
      );
    } on Object {
      return const Prefs();
    }
  }
}

/// Overridden in `main` with what was loaded from storage.
final initialPrefsProvider = Provider<Prefs>((_) => const Prefs());

class PrefsNotifier extends Notifier<Prefs> {
  @override
  Prefs build() => ref.watch(initialPrefsProvider);

  void update(Prefs Function(Prefs) change) {
    state = change(state);
    unawaited(ref.read(plainStoreProvider).write(Prefs._key, jsonEncode(state.toJson())));
  }
}

final prefsProvider = NotifierProvider<PrefsNotifier, Prefs>(PrefsNotifier.new);

/// The host every screen is looking at, or null when none is saved.
final currentHostProvider = Provider<Host?>((ref) {
  final hosts = ref.watch(hostsProvider).value ?? const <Host>[];
  if (hosts.isEmpty) return null;
  final id = ref.watch(prefsProvider.select((p) => p.hostId));
  return hosts.firstWhere((h) => h.id == id, orElse: () => hosts.first);
});

class ConnStatusNotifier extends Notifier<Map<String, ConnStatus>> {
  @override
  Map<String, ConnStatus> build() => const {};

  void set(String hostId, ConnStatus status) {
    final before = state[hostId];
    // Providers cannot be modified while the tree is building, and the SSH
    // layer reports status from inside requests the UI has just started.
    Future.microtask(() {
      if (!ref.mounted) return;
      state = {...state, hostId: status};
      // Coming back from a dropped connection: whatever is on screen is stale.
      if (before?.state == ConnState.disconnected && status.state == ConnState.connected) {
        ref.read(generationProvider(hostId).notifier).bump();
      }
    });
  }
}

final connStatusProvider = NotifierProvider<ConnStatusNotifier, Map<String, ConnStatus>>(ConnStatusNotifier.new);

/// Connection state of the current host, refreshed by [connectionMonitorProvider].
final currentStatusProvider = Provider<ConnStatus>((ref) {
  final host = ref.watch(currentHostProvider);
  if (host == null) return ConnStatus.idle;
  return ref.watch(connStatusProvider.select((m) => m[host.id])) ?? const ConnStatus(ConnState.connecting);
});

/// Pings the current host so the indicator and the alert stay truthful.
final connectionMonitorProvider = Provider<void>((ref) {
  final host = ref.watch(currentHostProvider);
  if (host == null) return;
  final ssh = ref.watch(sshServiceProvider);
  Timer? timer;
  var disposed = false;

  Future<void> tick() async {
    final status = await ssh.ping(host);
    if (disposed) return;
    timer = Timer(Duration(seconds: status.state == ConnState.connected ? 20 : 6), tick);
  }

  unawaited(tick());
  ref.onDispose(() {
    disposed = true;
    timer?.cancel();
  });
});

/// Bumped after every change so cached command output for that host is refetched.
class Generation extends Notifier<int> {
  Generation(this.hostId);
  final String hostId;

  @override
  int build() => 0;

  void bump() => state++;
}

final generationProvider = NotifierProvider.family<Generation, int, String>(Generation.new);
