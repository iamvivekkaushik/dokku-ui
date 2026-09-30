/// Renders screens against a fake SSH layer fed with output captured from a
/// real Dokku 0.35.20 server (`dokku_0_35.json`).
///
/// Layout overflow fails a Flutter test, so pumping a screen at phone and
/// desktop widths is an automatic check that nothing is cut off.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dokku_console/core/command.dart';
import 'package:dokku_console/core/host_scripts.dart';
import 'package:dokku_console/core/updates.dart';
import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/self_update.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:dokku_console/data/stores.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/queries.dart';
import 'package:dokku_console/state/updates.dart';
import 'package:dokku_console/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const phone = Size(375, 812);
const tablet = Size(820, 1180);
const desktop = Size(1440, 900);

/// Every size a screen has to look right at.
const allSizes = {'phone': phone, 'tablet': tablet, 'desktop': desktop};

final dokkuHost = Host(id: 'h-dokku', name: 'prod-01', host: '203.0.113.10', username: 'dokku', createdAt: DateTime(2026));
final rootHost = Host(id: 'h-root', name: 'prod-01', host: '203.0.113.10', username: 'root', createdAt: DateTime(2026));

Map<String, ExecResult> loadFixtures() {
  final raw = jsonDecode(File('test/support/dokku_0_35.json').readAsStringSync()) as Map<String, dynamic>;
  return raw.map((k, v) => MapEntry(
        k,
        ExecResult(
          code: (v['code'] as num).toInt(),
          stdout: v['stdout'] as String,
          stderr: v['stderr'] as String,
          durationMs: 40,
          command: k.startsWith('@') ? k : 'dokku $k',
        ),
      ));
}

ExecResult ok(String stdout, {String command = ''}) =>
    ExecResult(code: 0, stdout: stdout, stderr: '', durationMs: 40, command: command);

ExecResult failed(String stderr, {int code = 1}) =>
    ExecResult(code: code, stdout: '', stderr: stderr, durationMs: 40, command: '');

/// What Dokku prints for a command it does not have.
ExecResult unknownCommand(String args) => failed(' !     `$args` is not a dokku command.\n !     See `dokku help` for a list of available commands.\n');

class FakeStream implements RemoteStream {
  final _done = Completer<StreamExit>();
  final written = <String>[];
  var killed = false;

  void finish([int code = 0]) {
    if (!_done.isCompleted) _done.complete(StreamExit(code, null, 120));
  }

  @override
  Future<StreamExit> get done => _done.future;
  @override
  void write(String data) => written.add(data);
  @override
  void writeBytes(List<int> data) => written.add(utf8.decode(data, allowMalformed: true));
  @override
  void resize(int cols, int rows) {}
  @override
  void kill() {
    killed = true;
    if (!_done.isCompleted) _done.complete(const StreamExit(null, 'KILLED', 120));
  }
}

class FakeSsh extends SshService {
  FakeSsh(this.fixtures) : super(loadSecrets: (_) async => const HostSecrets());

  /// Command line (arguments joined by spaces) to what the server answers.
  final Map<String, ExecResult> fixtures;

  /// Every Dokku command that was run, in order.
  final ran = <List<String>>[];

  /// Read-only commands a screen asked for that have no fixture.
  final missing = <String>{};
  final streams = <FakeStream>[];

  /// What was sent on standard input, for the commands that were given any.
  final inputs = <({List<String> args, String stdin})>[];

  List<List<String>> get changes => [for (final c in ran) if (!isReadOnly(c)) c];

  ExecResult _answer(List<String> args) {
    final key = args.join(' ');
    final hit = fixtures[key];
    if (hit != null) return hit;
    // Changes succeed quietly; an unknown lookup is a gap in the fixtures.
    if (!isReadOnly(args)) return ok('-----> done\n', command: displayCommand(args));
    missing.add(key);
    return failed(' !     no fixture for: $key\n');
  }

  @override
  Future<ExecResult> dokku(Host h, List<String> args, {List<int>? stdin, Duration timeout = const Duration(minutes: 2)}) async {
    validateDokkuArgs(args);
    ran.add(args);
    return _answer(args);
  }

  @override
  Future<List<ExecResult>> dokkuAll(Host h, List<List<String>> commands) async => [for (final c in commands) await dokku(h, c)];

  @override
  Future<ExecResult> exec(Host h, String cmd, {List<int>? stdin, Duration timeout = const Duration(minutes: 2), String? display}) async {
    final key = cmd == metricsScript
        ? '@metrics'
        : cmd == systemScript
            ? '@system'
            : cmd == preflightScript
                ? '@preflight'
                : null;
    return key == null ? ok('') : fixtures[key] ?? failed('no fixture for $key');
  }

  @override
  Future<RemoteStream> dokkuStream(Host h, List<String> args,
      {Pty? pty, List<int>? stdin, required void Function(String chunk, bool isStderr) onData}) async {
    validateDokkuArgs(args);
    ran.add(args);
    if (stdin != null) inputs.add((args: args, stdin: utf8.decode(stdin, allowMalformed: true)));
    final r = _answer(args);
    final s = FakeStream();
    streams.add(s);
    scheduleMicrotask(() {
      if (r.stdout.isNotEmpty) onData(r.stdout, false);
      if (r.stderr.isNotEmpty) onData(r.stderr, true);
      // Follow-mode commands stay open until they are stopped, and so does an
      // interactive one unless a fixture scripts how it ends.
      final follows = args.contains('-t') || args.contains('--tail');
      final scripted = fixtures.containsKey(args.join(' '));
      if (!follows && (pty == null || scripted)) s.finish(r.code ?? 1);
    });
    return s;
  }

  @override
  Future<RemoteStream> stream(Host h, String cmd,
      {Pty? pty, List<int>? stdin, bool shell = false, required void Function(String chunk, bool isStderr) onData}) async {
    final s = FakeStream();
    streams.add(s);
    if (!shell && pty == null) scheduleMicrotask(s.finish);
    return s;
  }

  @override
  Future<ConnStatus> ping(Host h) async => const ConnStatus(ConnState.connected, rttMs: 38);

  @override
  Stream<HandshakeStep> test(Host h, HostSecrets secrets) => Stream.fromIterable(const [
        HandshakeStep(0, StepStatus.ok, 'ssh -p 22 dokku@203.0.113.10', detail: '38 ms'),
        HandshakeStep(1, StepStatus.ok, 'host key SHA256:kYt4RQ9cw2Jt8kE1hZ0mV3pXqL7nB5dC6fA8sD9gH0c',
            detail: 'will be remembered', hostKey: 'SHA256:kYt4RQ9cw2Jt8kE1hZ0mV3pXqL7nB5dC6fA8sD9gH0c', hostKeyType: 'ssh-ed25519'),
        HandshakeStep(2, StepStatus.ok, 'publickey authentication ok'),
        HandshakeStep(3, StepStatus.ok, 'dokku version → 0.35.20', dokkuVersion: '0.35.20'),
      ]);
}

var _fontsLoaded = false;

/// Tests measure text with a placeholder font by default, which is much wider
/// than the real one and would report overflow that users never see.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<ByteData> bytes(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Geist')
    ..addFont(bytes('assets/fonts/Geist-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Geist-Medium.ttf'))
    ..addFont(bytes('assets/fonts/Geist-SemiBold.ttf'));
  final mono = FontLoader('GeistMono')
    ..addFont(bytes('assets/fonts/GeistMono-Regular.ttf'))
    ..addFont(bytes('assets/fonts/GeistMono-Medium.ttf'));
  await Future.wait([sans.load(), mono.load()]);
}

/// Pumps [child] at [size] with live-looking data and returns the fake SSH
/// layer so the test can inspect what was run.
///
/// [answers] adds to or replaces the captured fixtures, for branches the
/// capture does not cover (a newer Dokku, an installed plugin, an error).
/// [hosts] replaces the saved hosts; pass an empty list for a fresh install.
/// [fake] builds the SSH layer, for tests that need one that misbehaves.
/// [latestDokku] is the newest Dokku release as GitHub reports it, or null when
/// GitHub cannot be reached.
/// [release] is what GitHub answers about the newest build (none by default),
/// [platform] the operating system to pretend to be, [updater] the self-updater.
Future<FakeSsh> pumpScreen(
  WidgetTester tester,
  Widget child, {
  Size size = desktop,
  Host? host,
  List<Host>? hosts,
  Map<String, ExecResult> answers = const {},
  FakeSsh Function(Map<String, ExecResult> fixtures)? fake,
  bool scroll = true,
  String? latestDokku = 'v0.38.31',
  AppRelease? release,
  String? platform,
  SelfUpdater? updater,
}) async {
  await tester.runAsync(loadAppFonts);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fixtures = {...loadFixtures(), ...answers};
  final ssh = fake?.call(fixtures) ?? FakeSsh(fixtures);
  // Saved the way the app saves them, so that editing and removing a host work.
  final saved = MemoryStore()..data['hosts.v1'] = jsonEncode([for (final h in hosts ?? [host ?? dokkuHost]) h.toJson()]);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      plainStoreProvider.overrideWithValue(saved),
      secureStoreProvider.overrideWithValue(MemoryStore()),
      sshServiceProvider.overrideWithValue(ssh),
      latestDokkuProvider.overrideWith((ref) async => latestDokku),
      appReleaseProvider.overrideWith((ref) async => release),
      if (platform != null) platformProvider.overrideWithValue(platform),
      if (updater != null) selfUpdaterProvider.overrideWithValue(updater),
      dnsProvider.overrideWith((ref, q) async => {
            for (final n in q.names) n: DnsCheck(n, const ['203.0.113.10'], true),
          }),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(body: child),
    ),
  ));
  await settle(tester);
  return ssh;
}

/// Lets pending lookups finish. `pumpAndSettle` never returns here because
/// spinners and pulsing dots animate forever.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Call at the end of every test: disposes providers and lets their timers run out.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 30));
}

/// Runs [body] once per screen size.
void testAtAllSizes(String description, Future<void> Function(WidgetTester tester, Size size) body) {
  allSizes.forEach((name, size) {
    testWidgets('$description ($name)', (tester) async {
      await body(tester, size);
      await finish(tester);
    });
  });
}
