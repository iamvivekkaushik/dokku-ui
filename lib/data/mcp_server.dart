/// A Model Context Protocol server on this device, so an agent (Claude Code,
/// Claude Desktop, Cursor…) can drive the saved Dokku hosts directly.
///
/// It speaks the Streamable HTTP transport with JSON responses only, listens on
/// the loopback interface alone and answers nothing without the bearer token.
/// Commands still go out over the app's own SSH connections.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/command.dart';
import '../core/parse.dart';
import 'models.dart';

const mcpProtocolVersion = '2025-06-18';
const _supportedVersions = {'2025-06-18', '2025-03-26', '2024-11-05'};

typedef McpHosts = Future<List<Host>> Function();
typedef McpRunDokku = Future<ExecResult> Function(Host host, List<String> args);

class McpServer {
  McpServer({
    required this.token,
    required this.hosts,
    required this.runDokku,
    required this.allowWrites,
    this.version = '',
  });

  final String token;
  final McpHosts hosts;
  final McpRunDokku runDokku;

  /// Read whenever a command arrives, so the switch applies at once.
  final bool Function() allowWrites;
  final String version;

  HttpServer? _server;

  int? get port => _server?.port;

  Future<void> start(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen((req) => unawaited(_handle(req).catchError((_) {})));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // A web page may not reach this server: browsers always send an Origin.
    final origin = req.headers.value('origin');
    if (origin != null && !_localOrigin(origin)) return _status(res, HttpStatus.forbidden);
    if (req.uri.path != '/mcp') return _status(res, HttpStatus.notFound);
    if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $token') {
      res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
      return _status(res, HttpStatus.unauthorized);
    }
    if (req.method == 'DELETE') return _status(res, HttpStatus.ok);
    if (req.method != 'POST') {
      res.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
      return _status(res, HttpStatus.methodNotAllowed);
    }

    Object? body;
    try {
      body = jsonDecode(await utf8.decodeStream(req));
    } on FormatException {
      return _json(res, _error(null, -32700, 'Parse error'));
    }

    if (body is List) {
      final replies = [for (final m in body) await _message(m)].whereType<Map<String, Object?>>().toList();
      if (replies.isEmpty) return _status(res, HttpStatus.accepted);
      return _json(res, replies);
    }
    final reply = await _message(body);
    if (reply == null) return _status(res, HttpStatus.accepted);
    return _json(res, reply);
  }

  static bool _localOrigin(String origin) {
    final host = Uri.tryParse(origin)?.host;
    return host == 'localhost' || host == '127.0.0.1' || host == '[::1]' || host == '::1';
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    await res.close();
  }

  static Future<void> _json(HttpResponse res, Object body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  static Map<String, Object?> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  static Map<String, Object?> _result(Object? id, Object result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  /// Handles one JSON-RPC message; null for a notification or a response.
  Future<Map<String, Object?>?> _message(Object? m) async {
    if (m is! Map || m['jsonrpc'] != '2.0') return _error(null, -32600, 'Invalid Request');
    final id = m['id'];
    final method = m['method'];
    if (method is! String) return null;
    if (!m.containsKey('id')) return null;
    final params = m['params'] is Map ? (m['params'] as Map).cast<String, Object?>() : const <String, Object?>{};

    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'];
        return _result(id, {
          'protocolVersion': asked is String && _supportedVersions.contains(asked) ? asked : mcpProtocolVersion,
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'dokku-console', 'version': version},
          'instructions': 'Runs dokku commands on the Dokku hosts saved in Dokku Console, over its SSH connections. '
              'Call list_hosts first, then dokku with a host and the arguments that would follow `dokku`.',
        });
      case 'ping':
        return _result(id, const <String, Object?>{});
      case 'tools/list':
        return _result(id, {'tools': _tools});
      case 'tools/call':
        return _result(id, await _call(params['name'], params['arguments']));
      default:
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  static final _tools = [
    {
      'name': 'list_hosts',
      'description': 'Lists the Dokku hosts saved in Dokku Console.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
      'annotations': {'readOnlyHint': true},
    },
    {
      'name': 'dokku',
      'description': 'Runs one dokku command on a saved host and returns its output. '
          '`args` are the words after `dokku`, e.g. ["apps:list"] or ["config:set", "myapp", "KEY=value"]. '
          'Interactive commands (enter, run without --detach, logs -t) are not supported. '
          'Commands that change something are refused unless the user allowed changes in Dokku Console.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'host': {'type': 'string', 'description': 'Host id or name from list_hosts. Optional when only one is saved.'},
          'args': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'The dokku subcommand and its arguments.',
          },
        },
        'required': ['args'],
      },
      'annotations': {'destructiveHint': true, 'openWorldHint': true},
    },
  ];

  static Map<String, Object?> _text(String text, {bool error = false}) => {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'isError': error,
      };

  Future<Map<String, Object?>> _call(Object? name, Object? arguments) async {
    final a = arguments is Map ? arguments.cast<String, Object?>() : const <String, Object?>{};
    try {
      switch (name) {
        case 'list_hosts':
          final list = await hosts();
          return _text(jsonEncode([
            for (final h in list)
              {'id': h.id, 'name': h.name, 'address': '${h.username}@${h.host}:${h.port}'},
          ]));
        case 'dokku':
          final raw = a['args'];
          if (raw is! List || raw.any((x) => x is! String)) return _text('`args` must be a list of strings.', error: true);
          final args = validateDokkuArgs(raw.cast<String>());
          final host = await _pick(a['host']);
          if (!allowWrites() && !isReadOnly(args)) {
            return _text(
              'Refused: `${displayCommand(args)}` changes the server, and Dokku Console only allows read-only '
              'commands from agents. The user can allow changes under Server › Agent access.',
              error: true,
            );
          }
          final r = await runDokku(host, args);
          final out = stripAnsi(r.output).trim();
          return _text(
            '${out.isEmpty ? '(no output)' : out}${r.ok ? '' : '\n\nexit code ${r.code ?? r.signal ?? '?'}'}',
            error: !r.ok,
          );
        default:
          return _text('Unknown tool: $name', error: true);
      }
    } on Object catch (e) {
      return _text('$e', error: true);
    }
  }

  Future<Host> _pick(Object? wanted) async {
    final list = await hosts();
    if (list.isEmpty) throw ArgError('No hosts are saved in Dokku Console.');
    if (wanted is! String || wanted.isEmpty) {
      if (list.length == 1) return list.single;
      throw ArgError('Several hosts are saved; pass `host` (see list_hosts).');
    }
    final w = wanted.toLowerCase();
    return list.firstWhere(
      (h) => h.id == wanted || h.name.toLowerCase() == w || h.host.toLowerCase() == w,
      orElse: () => throw ArgError('No saved host called "$wanted".'),
    );
  }
}
