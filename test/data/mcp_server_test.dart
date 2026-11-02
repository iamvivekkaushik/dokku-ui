import 'dart:convert';
import 'dart:io';

import 'package:dokku_console/data/mcp_server.dart';
import 'package:dokku_console/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

final prod = Host(id: 'h1', name: 'prod', host: '203.0.113.10', createdAt: DateTime(2026));

void main() {
  late McpServer server;
  late List<List<String>> ran;
  var writes = false;

  setUp(() async {
    ran = [];
    writes = false;
    server = McpServer(
      token: 'secret',
      hosts: () async => [prod],
      allowWrites: () => writes,
      runDokku: (h, args) async {
        ran.add(args);
        return ExecResult(code: 0, stdout: '=====> My Apps\nweb', stderr: '', durationMs: 1, command: '');
      },
    );
    await server.start(0);
  });
  tearDown(() => server.stop());

  Future<(int, Object?)> post(Object body, {String token = 'secret', String? origin}) async {
    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', server.port!, '/mcp');
      req.headers.set('authorization', 'Bearer $token');
      if (origin != null) req.headers.set('origin', origin);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close();
    }
  }

  Map<String, Object?> call(String name, Map<String, Object?> args) =>
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}};

  String text(Object? reply) => ((reply as Map)['result']['content'] as List).first['text'] as String;
  bool isError(Object? reply) => (reply as Map)['result']['isError'] as bool;

  test('needs the token', () async {
    final (code, _) = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}, token: 'wrong');
    expect(code, 401);
  });

  test('refuses web pages from elsewhere', () async {
    final (code, _) = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}, origin: 'https://evil.example');
    expect(code, 403);
  });

  test('initializes and lists its tools', () async {
    final (_, init) = await post({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}},
    });
    expect((init as Map)['result']['protocolVersion'], '2025-03-26');
    final (code, _) = await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    expect(code, 202);
    final (_, list) = await post({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    expect([for (final t in (list as Map)['result']['tools'] as List) t['name']], ['list_hosts', 'dokku']);
  });

  test('runs read-only commands on the only host', () async {
    final (_, reply) = await post(call('dokku', {'args': ['apps:list']}));
    expect(isError(reply), isFalse);
    expect(text(reply), contains('web'));
    expect(ran, [['apps:list']]);
  });

  test('refuses changes until they are allowed', () async {
    final (_, refused) = await post(call('dokku', {'host': 'prod', 'args': ['apps:destroy', 'web', '--force']}));
    expect(isError(refused), isTrue);
    expect(ran, isEmpty);
    writes = true;
    final (_, done) = await post(call('dokku', {'host': 'prod', 'args': ['apps:destroy', 'web', '--force']}));
    expect(isError(done), isFalse);
    expect(ran.single.first, 'apps:destroy');
  });

  test('rejects a bad subcommand and an unknown host', () async {
    final (_, bad) = await post(call('dokku', {'args': ['; rm -rf /']}));
    expect(isError(bad), isTrue);
    final (_, missing) = await post(call('dokku', {'host': 'staging', 'args': ['apps:list']}));
    expect(text(missing), contains('No saved host'));
    expect(ran, isEmpty);
  });
}
