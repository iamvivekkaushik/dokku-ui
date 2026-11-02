/// Agent access: the MCP server, its settings and whether it is running.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/command.dart';
import '../core/parse.dart';
import '../core/version.dart';
import '../data/mcp_server.dart';
import '../data/stores.dart';
import 'core.dart';

const defaultMcpPort = 7319;

class McpSettings {
  const McpSettings({this.enabled = false, this.port = defaultMcpPort, this.allowWrites = false, this.token = ''});
  final bool enabled;
  final int port;

  /// Off: agents may only run commands that change nothing.
  final bool allowWrites;
  final String token;

  String get url => 'http://127.0.0.1:$port/mcp';

  McpSettings copyWith({bool? enabled, int? port, bool? allowWrites, String? token}) => McpSettings(
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        allowWrites: allowWrites ?? this.allowWrites,
        token: token ?? this.token,
      );

  static const _key = 'mcp.v1';
  static const _tokenKey = 'mcp.token';

  static String newToken() {
    final r = Random.secure();
    return base64Url.encode([for (var i = 0; i < 32; i++) r.nextInt(256)]).replaceAll('=', '');
  }

  static Future<McpSettings> load(KeyValueStore plain, KeyValueStore secure) async {
    var token = await secure.read(_tokenKey) ?? '';
    if (token.isEmpty) {
      token = newToken();
      await secure.write(_tokenKey, token);
    }
    try {
      final j = jsonDecode(await plain.read(_key) ?? '{}') as Map<String, dynamic>;
      return McpSettings(
        enabled: j['enabled'] as bool? ?? false,
        port: j['port'] as int? ?? defaultMcpPort,
        allowWrites: j['allowWrites'] as bool? ?? false,
        token: token,
      );
    } on Object {
      return McpSettings(token: token);
    }
  }

  Future<void> save(KeyValueStore plain, KeyValueStore secure) async {
    await plain.write(_key, jsonEncode({'enabled': enabled, 'port': port, 'allowWrites': allowWrites}));
    await secure.write(_tokenKey, token);
  }
}

/// Whether the server is listening, and why not when it should be.
class McpStatus {
  const McpStatus({this.running = false, this.error});
  final bool running;
  final String? error;
}

class McpNotifier extends AsyncNotifier<McpSettings> {
  McpServer? _server;

  @override
  Future<McpSettings> build() async {
    ref.onDispose(() => unawaited(_server?.stop()));
    final s = await McpSettings.load(ref.read(plainStoreProvider), ref.read(secureStoreProvider));
    await _apply(s);
    return s;
  }

  Future<void> change(McpSettings Function(McpSettings) f) async {
    final before = state.value;
    if (before == null) return;
    final next = f(before);
    state = AsyncData(next);
    await next.save(ref.read(plainStoreProvider), ref.read(secureStoreProvider));
    // The write switch is read per command; anything else needs a restart.
    if (next.enabled != before.enabled || next.port != before.port || next.token != before.token) await _apply(next);
  }

  Future<void> _apply(McpSettings s) async {
    await _server?.stop();
    _server = null;
    if (!s.enabled) {
      _setStatus(const McpStatus());
      return;
    }
    final server = McpServer(
      token: s.token,
      version: appVersion,
      allowWrites: () => state.value?.allowWrites ?? false,
      hosts: () => ref.read(hostsProvider.future),
      runDokku: (host, args) async {
        final r = await ref.read(sshServiceProvider).dokku(host, args, timeout: const Duration(minutes: 5));
        if (!isReadOnly(args)) {
          await ref.read(activityLogProvider).add(
                hostId: host.id,
                command: '${displayCommand(args)}  # agent',
                code: r.code,
                durationMs: r.durationMs,
                stderr: stripAnsi(r.stderr.isEmpty ? r.stdout : r.stderr),
              );
          if (ref.mounted) ref.read(generationProvider(host.id).notifier).bump();
        }
        return r;
      },
    );
    try {
      await server.start(s.port);
      _server = server;
      _setStatus(const McpStatus(running: true));
    } on Object catch (e) {
      _setStatus(McpStatus(error: 'Could not listen on port ${s.port}: $e'));
    }
  }

  void _setStatus(McpStatus s) => Future.microtask(() {
        if (ref.mounted) ref.read(mcpStatusProvider.notifier).set(s);
      });
}

final mcpProvider = AsyncNotifierProvider<McpNotifier, McpSettings>(McpNotifier.new);

class _McpStatusNotifier extends Notifier<McpStatus> {
  @override
  McpStatus build() => const McpStatus();

  void set(McpStatus value) => state = value;
}

final mcpStatusProvider = NotifierProvider<_McpStatusNotifier, McpStatus>(_McpStatusNotifier.new);
