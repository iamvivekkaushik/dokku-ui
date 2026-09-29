import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dokku_console/core/parse.dart';
import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:dokku_console/data/stores.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/app/logs.dart';
import 'package:dokku_console/ui/screens/datastores.dart';
import 'package:dokku_console/ui/screens/monitoring.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A stream the test feeds by hand and can end in any way.
class _HandStream implements RemoteStream {
  _HandStream(this.send);
  final void Function(String chunk, bool isStderr) send;
  final _done = Completer<StreamExit>();
  var killed = false;

  void end(StreamExit exit) => _done.complete(exit);

  @override
  Future<StreamExit> get done => _done.future;
  @override
  void write(String data) {}
  @override
  void writeBytes(List<int> data) {}
  @override
  void resize(int cols, int rows) {}
  @override
  void kill() {
    killed = true;
    if (!_done.isCompleted) _done.complete(const StreamExit(null, 'KILLED', 1));
  }
}

class _HandSsh extends FakeSsh {
  _HandSsh([Map<String, ExecResult>? fixtures]) : super(fixtures ?? {});
  final opened = <_HandStream>[];
  var refuse = false;

  @override
  Future<RemoteStream> dokkuStream(Host h, List<String> args,
      {Pty? pty, List<int>? stdin, required void Function(String chunk, bool isStderr) onData}) async {
    ran.add(args);
    if (refuse) throw ConnectionFailed('Could not reach 203.0.113.10:22: timed out');
    final s = _HandStream(onData);
    opened.add(s);
    return s;
  }
}

class _SavedFiles extends FilePickerPlatform {
  final saved = <String, String>{};

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved[fileName] = utf8.decode(bytes);
    return Uri.file('/tmp/$fileName');
  }
}

class _OneHost extends HostsNotifier {
  @override
  Future<List<Host>> build() async => [dokkuHost];
}

/// Like `pumpScreen`, for a test that brings its own SSH layer.
Future<void> pumpWith(WidgetTester tester, FakeSsh ssh, Widget child) async {
  await tester.runAsync(loadAppFonts);
  tester.view
    ..physicalSize = desktop
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      plainStoreProvider.overrideWithValue(MemoryStore()),
      secureStoreProvider.overrideWithValue(MemoryStore()),
      sshServiceProvider.overrideWithValue(ssh),
      hostsProvider.overrideWith(_OneHost.new),
    ],
    child: MaterialApp(theme: buildTheme(), home: Scaffold(body: child)),
  ));
  await settle(tester);
}

ExecResult answer({String stdout = '', String stderr = '', int code = 0}) =>
    ExecResult(code: code, stdout: stdout, stderr: stderr, durationMs: 40, command: '');

String event(String kind, String text, {String at = '2026-09-29T13:30:00.000000+00:00'}) =>
    '$at 76b36e85bf8c dokku-event[1200]: INVOKED: $kind( $text ) NAME=test FINGERPRINT=SHA256:abc DOKKU_PID=1100\n';

Widget logsTab() => SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: LogsTab(host: dokkuHost, app: 'demo-app')),
    );

AppRoute routeOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PageBody))).read(routeProvider);

/// The text fields, without the read-only command previews.
Finder get inputs => find.descendant(of: find.byType(AppInput), matching: find.byType(EditableText));

/// Matches the list of commands when [args] was one of them.
Matcher includes(List<String> args) => contains(equals(args));

bool autoscrollOn(WidgetTester tester) => tester.widget<Btn>(find.widgetWithText(Btn, 'Autoscroll')).selected;

const follow = ['logs', 'demo-app', '-t', '-n', '200'];

void main() {
  group('LogTail', () {
    late _HandSsh ssh;
    late LogTail tail;
    var notified = 0;

    Future<void> start(WidgetTester tester, [List<String> args = follow]) async {
      tail.follow(dokkuHost, args, parseLogLine);
      await tester.pump();
    }

    List<String> messages() => [for (final l in tail.lines) l.msg];

    setUp(() {
      ssh = _HandSsh();
      notified = 0;
      tail = LogTail(ssh)..addListener(() => notified++);
    });

    testWidgets('keeps a partial last line until it completes', (tester) async {
      await start(tester);
      expect(tail.state, TailState.live);
      ssh.opened.single.send('one\ntw', false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(messages(), ['one']);
      ssh.opened.single.send('o\n', false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(messages(), ['one', 'two']);
      tail.dispose();
    });

    testWidgets('shows the unfinished line when the command ends', (tester) async {
      await start(tester, ['logs:failed', 'demo-app']);
      ssh.opened.single.send('first\nlast', false);
      ssh.opened.single.end(const StreamExit(0, null, 10));
      await tester.pump(const Duration(milliseconds: 100));
      expect(messages(), ['first', 'last']);
      expect(tail.state, TailState.ended);
      tail.dispose();
    });

    testWidgets('updates once for a burst of lines', (tester) async {
      await start(tester);
      final before = notified;
      for (var i = 0; i < 50; i++) {
        ssh.opened.single.send('line $i\n', false);
      }
      await tester.pump(const Duration(milliseconds: 40));
      expect(tail.lines, isEmpty);
      expect(notified, before);
      await tester.pump(const Duration(milliseconds: 60));
      expect(tail.lines, hasLength(50));
      expect(notified, before + 1);
      tail.dispose();
    });

    testWidgets('keeps the newest 3000 lines', (tester) async {
      await start(tester);
      ssh.opened.single.send([for (var i = 0; i < 3500; i++) 'line $i\n'].join(), false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tail.lines, hasLength(3000));
      expect(tail.lines.first.msg, 'line 500');
      expect(tail.lines.last.msg, 'line 3499');
      tail.dispose();
    });

    testWidgets('tries again 4 seconds after it cannot connect', (tester) async {
      ssh.refuse = true;
      await start(tester);
      expect(tail.state, TailState.error);
      expect(tail.error, 'Could not reach 203.0.113.10:22: timed out');
      ssh.refuse = false;
      await tester.pump(const Duration(milliseconds: 3900));
      expect(ssh.opened, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(ssh.ran, [follow, follow]);
      expect(tail.state, TailState.live);
      tail.dispose();
    });

    testWidgets('keeps what is on screen when the connection drops', (tester) async {
      await start(tester);
      ssh.opened.single.send('before\n', false);
      await tester.pump(const Duration(milliseconds: 100));
      ssh.opened.single.end(const StreamExit(null, null, 10));
      await tester.pump();
      expect(tail.state, TailState.error);
      expect(messages(), ['before']);
      await tester.pump(const Duration(seconds: 4));
      expect(ssh.opened, hasLength(2));
      expect(tail.state, TailState.live);
      ssh.opened.last.send('after\n', false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(messages(), ['before', 'after']);
      tail.dispose();
    });

    testWidgets('a new command stops the old one and starts clean', (tester) async {
      await start(tester);
      final old = ssh.opened.single;
      old.send('from the old command\n', false);
      await tester.pump(const Duration(milliseconds: 100));
      await start(tester, ['logs:failed', 'demo-app']);
      expect(old.killed, isTrue);
      expect(tail.lines, isEmpty);
      // A stopped terminal echoes ^C.
      old.send('^C\n', false);
      ssh.opened.last.send('from the new command\n', false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(messages(), ['from the new command']);
      tail.dispose();
    });

    testWidgets('asking for the same command again changes nothing', (tester) async {
      await start(tester);
      await start(tester);
      expect(ssh.ran, [follow]);
      expect(ssh.opened.single.killed, isFalse);
      tail.dispose();
    });

    testWidgets('following nothing stops the stream', (tester) async {
      await start(tester);
      tail.follow(dokkuHost, null, parseLogLine);
      await tester.pump();
      expect(ssh.opened.single.killed, isTrue);
      expect(tail.state, TailState.idle);
      tail.dispose();
    });

    testWidgets('dispose stops the stream and drops late output', (tester) async {
      await start(tester);
      final stream = ssh.opened.single..send('pending\n', false);
      tail.dispose();
      expect(stream.killed, isTrue);
      final before = notified;
      stream.send('^C\n', false);
      await tester.pump(const Duration(seconds: 5));
      expect(notified, before);
      expect(ssh.ran, [follow]);
    });

    testWidgets('a stream that opens after it was stopped is closed again', (tester) async {
      tail.follow(dokkuHost, follow, parseLogLine);
      tail.dispose();
      await tester.pump();
      expect(ssh.opened.single.killed, isTrue);
    });
  });

  group('Logs tab', () {
    testAtAllSizes('follows the app log beside a console', (tester, size) async {
      final ssh = await pumpScreen(tester, logsTab(), size: size);
      final first = parseLogLine(ssh.fixtures[follow.join(' ')]!.stdout.split('\n').first);
      expect(find.text('2026/09/29 13:25:37 Starting up on port 80'), findsOneWidget);
      expect(find.text('web.1'), findsOneWidget);
      expect(find.text('web.2'), findsOneWidget);
      expect(find.text(first.ts), size == phone ? findsNothing : findsOneWidget);
      expect(find.text('2 lines'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);
      expect(find.text('\$ dokku logs demo-app -t -n 200'), findsOneWidget);
      expect(ssh.ran, containsAll([follow, ['ps:scale', 'demo-app']]));
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('leaving the tab stops the stream', (tester) async {
      final ssh = await pumpScreen(tester, logsTab());
      expect(ssh.streams.single.killed, isFalse);
      await finish(tester);
      expect(ssh.streams.single.killed, isTrue);
    });

    testAtAllSizes('failed shows the crashed deploy containers', (tester, size) async {
      final ssh = await pumpScreen(tester, logsTab(), size: size);
      await tester.tap(find.text('failed'));
      await settle(tester);
      expect(ssh.ran, includes(['logs:failed', 'demo-app']));
      expect(ssh.streams.first.killed, isTrue);
      expect(find.text('=====> demo-app failed deploy logs'), findsOneWidget);
      expect(find.textContaining('No failed containers found'), findsOneWidget);
      expect(find.text('Starting up on port 80'), findsNothing);
      // The process filter and the line count only apply to the live log.
      expect(find.text('all'), findsNothing);
      expect(find.text('-n 200'), findsNothing);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('events shows only the changes made to this app', (tester) async {
      final ssh = await pumpScreen(tester, logsTab(), answers: {
        'events -t': ok([
          event('post-deploy', 'demo-app 5000 172.17.0.3 dokku/demo-app:latest'),
          event('post-deploy', 'demo-app-staging 5000 172.17.0.4 dokku/demo-app-staging:latest'),
          event('post-config-update', 'worker-app set KEY'),
          event('config-get', 'demo-app DOKKU_PROXY_PORT'),
        ].join()),
      });
      await tester.tap(find.text('events'));
      await settle(tester);
      expect(ssh.ran, includes(['events', '-t']));
      expect(find.text('post-deploy'), findsOneWidget);
      expect(find.text('demo-app 5000 172.17.0.3 dokku/demo-app:latest  by test'), findsOneWidget);
      expect(find.textContaining('demo-app-staging'), findsNothing);
      expect(find.text('post-config-update'), findsNothing);
      expect(find.text('config-get'), findsNothing);
      expect(find.text('1 line'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('events waits when nothing has changed on this app', (tester) async {
      final ssh = await pumpScreen(tester, logsTab());
      await tester.tap(find.text('events'));
      await settle(tester);
      expect(find.text('Waiting for output…'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('the process filter follows one process type', (tester) async {
      final ssh = await pumpScreen(tester, logsTab(), answers: {
        '${follow.join(' ')} -p web': ok('2026-09-29T13:25:37.150132922Z app[web.2]: only web\n'),
      });
      await tester.tap(find.text('web'));
      await settle(tester);
      expect(ssh.ran.last, [...follow, '-p', 'web']);
      expect(find.text('only web'), findsOneWidget);
      expect(find.text('\$ dokku logs demo-app -t -n 200 -p web'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('the line count asks for more history', (tester) async {
      final ssh = await pumpScreen(tester, logsTab(), answers: {
        'logs demo-app -t -n 500': ok('2026-09-29T13:25:37.150132922Z app[web.2]: older line\n'),
      });
      await tester.tap(find.text('-n 200'));
      await settle(tester);
      await tester.tap(find.text('-n 500').last);
      await settle(tester);
      expect(ssh.ran.last, ['logs', 'demo-app', '-t', '-n', '500']);
      expect(find.text('older line'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('search narrows the lines by message or process', (tester) async {
      await pumpScreen(tester, logsTab());
      await tester.enterText(inputs, 'WEB.1');
      await settle(tester);
      expect(find.text('web.1'), findsOneWidget);
      expect(find.text('web.2'), findsNothing);
      expect(find.text('1 line'), findsOneWidget);
      await tester.enterText(inputs, 'nothing like this');
      await settle(tester);
      expect(find.text('No lines match.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('search works on a long log that is scrolled to the end', (tester) async {
      await pumpScreen(tester, logsTab(), answers: {
        follow.join(' '): ok([for (var i = 0; i < 300; i++) '2026-09-29T13:25:37.150132922Z app[web.1]: request $i\n'].join()),
      });
      expect(find.text('300 lines'), findsOneWidget);
      await tester.enterText(inputs, 'request 12');
      await settle(tester);
      expect(find.text('11 lines'), findsOneWidget);
      // The search field holds the same text as the first match.
      expect(find.descendant(of: find.byType(ListView).first, matching: find.text('request 12')), findsOneWidget);
      expect(find.text('request 129'), findsOneWidget);
      await tester.enterText(inputs, '');
      await settle(tester);
      expect(find.text('300 lines'), findsOneWidget);
      await finish(tester);
    });

    testAtAllSizes('many process types and long lines fit', (tester, size) async {
      final ssh = await pumpScreen(tester, logsTab(), size: size, answers: {
        'ps:scale demo-app': ok('-----> Scaling for demo-app\nproctype: qty\n--------: ---\n'
            'web:  2\nworker: 1\nscheduler: 1\nrelease: 0\nbackground-jobs: 3\nvery-long-process-type-name: 1\n'),
        follow.join(' '): ok([
          for (var i = 0; i < 40; i++)
            '2026-09-29T13:25:37.150132922Z app[very-long-process-type-name.$i]: ${'word ' * (i + 1)}${'x' * 120}\n',
        ].join()),
      });
      expect(find.text('very-long-process-type-name'), findsOneWidget);
      expect(find.text('40 lines'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('autoscroll turns off when scrolled up and on again at the end', (tester) async {
      await pumpScreen(tester, logsTab(), answers: {
        follow.join(' '): ok([for (var i = 0; i < 300; i++) '2026-09-29T13:25:37.150132922Z app[web.1]: request $i\n'].join()),
      });
      expect(autoscrollOn(tester), isTrue);
      expect(find.text('request 299'), findsOneWidget);

      final list = find.byType(ListView).first;
      await tester.drag(list, const Offset(0, 300));
      await settle(tester);
      expect(autoscrollOn(tester), isFalse);
      expect(find.text('request 299'), findsNothing);

      await tester.drag(list, const Offset(0, -400));
      await settle(tester);
      expect(autoscrollOn(tester), isTrue);
      expect(find.text('request 299'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the autoscroll button pauses and resumes', (tester) async {
      await pumpScreen(tester, logsTab(), answers: {
        follow.join(' '): ok([for (var i = 0; i < 300; i++) '2026-09-29T13:25:37.150132922Z app[web.1]: request $i\n'].join()),
      });
      await tester.tap(find.text('Autoscroll'));
      await settle(tester);
      expect(autoscrollOn(tester), isFalse);
      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      await settle(tester);
      await tester.tap(find.text('Autoscroll'));
      await settle(tester);
      expect(autoscrollOn(tester), isTrue);
      expect(find.text('request 299'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('download saves the lines that are shown', (tester) async {
      final files = _SavedFiles();
      final before = FilePickerPlatform.instance;
      FilePickerPlatform.instance = files;
      addTearDown(() => FilePickerPlatform.instance = before);

      await pumpScreen(tester, logsTab());
      await tester.enterText(inputs, 'web.2');
      await settle(tester);
      await tester.tap(find.byTooltip('Download shown lines'));
      await settle(tester);
      expect(files.saved.keys, ['demo-app-live.log']);
      expect(files.saved.values.single, endsWith(' web.2 2026/09/29 13:25:37 Starting up on port 80'));
      expect(files.saved.values.single, isNot(contains('web.1')));
      await finish(tester);
    });

    testWidgets('says so when the connection fails, and keeps trying', (tester) async {
      // Only the stream is scripted; lookups still answer from the capture.
      final ssh = _HandSsh(loadFixtures())..refuse = true;
      await pumpWith(tester, ssh, logsTab());
      expect(find.text('Could not reach 203.0.113.10:22: timed out. Reconnecting…'), findsOneWidget);
      ssh.refuse = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      ssh.opened.single.send('2026-09-29T13:25:37.150132922Z app[web.1]: back again\n', false);
      await settle(tester);
      expect(find.text('back again'), findsOneWidget);
      expect(find.textContaining('Reconnecting'), findsNothing);
      await finish(tester);
    });
  });

  group('Monitoring', () {
    testAtAllSizes('shows events, failed deploys and health', (tester, size) async {
      final ssh = await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size);
      expect(find.text('Logs & monitoring'), findsOneWidget);
      expect(find.text('Platform events'), findsOneWidget);
      expect(find.text('events -t'), findsOneWidget);
      expect(find.text('No deploys or config changes in the last 59 logged triggers.'), findsOneWidget);
      expect(find.text('No crashed deploy containers.'), findsOneWidget);
      expect(find.text('passing'), findsOneWidget);
      expect(find.text('not deployed'), findsOneWidget);
      expect(find.text('2/2 up'), size == phone ? findsNothing : findsOneWidget);
      expect(ssh.ran, containsAll([['events', '-t'], ['events:list'], ['logs:failed', '--all']]));
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('all triggers lists every event, newest first', (tester, size) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size);
      await tester.tap(find.text('All triggers'));
      await settle(tester);
      final rows = tester.widgetList<Text>(find.descendant(of: find.byType(ListView), matching: find.byType(Text))).toList();
      expect(rows[1].textSpan!.toPlainText(), 'scheduler-logs docker-local demo-app  false false 100  by test');
    });

    testWidgets('the filter narrows the events', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost));
      await tester.tap(find.text('All triggers'));
      await tester.enterText(inputs, 'storage-list');
      await settle(tester);
      expect(find.textContaining('storage-list worker-app deploy json'), findsOneWidget);
      expect(find.textContaining('scheduler-logs'), findsNothing);
      await tester.enterText(inputs, 'no such event');
      await settle(tester);
      expect(find.text('No events match.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('changes only keeps the deploys and config changes', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost), answers: {
        'events -t': ok([
          event('config-get', 'demo-app DOKKU_PROXY_PORT'),
          event('post-deploy', 'demo-app 5000 172.17.0.3 dokku/demo-app:latest'),
          event('proxy-type', 'demo-app'),
        ].join()),
      });
      expect(find.textContaining('post-deploy demo-app 5000'), findsOneWidget);
      expect(find.textContaining('config-get'), findsNothing);
      expect(find.textContaining('proxy-type'), findsNothing);
      await finish(tester);
    });

    testAtAllSizes('offers to enable the logger when it is off', (tester, size) async {
      final ssh = await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size, answers: {
        'events:list': answer(stderr: ' !     Events logger disabled\n'),
      });
      expect(find.textContaining('The events logger is off.'), findsOneWidget);
      expect(ssh.ran, isNot(includes(['events', '-t'])));
      expect(ssh.streams, isEmpty);
      await tester.tap(find.text('Enable logger'));
      await settle(tester);
      expect(ssh.changes, [['events:on']]);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('lists the apps whose deploy crashed', (tester, size) async {
      final ssh = await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size, answers: {
        'logs:failed --all': answer(
          stdout: '-----> Running logs:failed against app demo-app\n'
              '=====> demo-app failed deploy logs\n'
              'npm warn using --force\n'
              'npm error Missing script: "start"\n'
              'Process finished\n'
              '-----> Running logs:failed against app worker-app\n'
              '=====> worker-app failed deploy logs\n',
          stderr: ' !     No failed containers found\n',
        ),
      });
      expect(find.text('npm error Missing script: "start"'), findsOneWidget);
      expect(find.text('3 lines'), findsOneWidget);
      expect(find.text('No crashed deploy containers.'), findsNothing);
      await tester.tap(find.text('npm error Missing script: "start"'));
      await tester.pump();
      expect(routeOf(tester), const AppDetailRoute('demo-app', AppTab.logs));
      expect(ssh.missing, isEmpty);
    });

    testWidgets('explains when this Dokku cannot list failed deploys', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost), answers: {
        'logs:failed --all': unknownCommand('logs:failed'),
      });
      expect(find.textContaining('cannot list failed deploys for every app'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('health shows a degraded app', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost), answers: {
        'ps:report': ok('=====> demo-app ps information\n'
            '       Deployed:                      true\n'
            '       Status web 1:                  running (CID: 32e0eed506d)\n'
            '       Status web 2:                  exited (CID: 64947aa00c5)\n'
            '=====> worker-app ps information\n'
            '       Deployed:                      true\n'
            '       Status worker 1:               exited (CID: 74947aa00c5)\n'),
        'checks:report': ok('=====> demo-app checks information\n'
            '       Checks disabled list:          none\n'
            '       Checks skipped list:           web\n'
            '=====> worker-app checks information\n'
            '       Checks disabled list:          none\n'
            '       Checks skipped list:           none\n'),
      });
      expect(find.text('degraded'), findsOneWidget);
      expect(find.text('1/2 up · skipped'), findsOneWidget);
      expect(find.text('down'), findsOneWidget);
      expect(find.text('no web'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('health says when checks are turned off', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost), answers: {
        'checks:report': ok('=====> demo-app checks information\n'
            '       Checks disabled list:          web\n'
            '       Checks skipped list:           none\n'),
      });
      expect(find.text('up · checks off'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the shortcuts open an app\'s logs and processes', (tester) async {
      await pumpScreen(tester, MonitoringScreen(host: dokkuHost));
      await tester.tap(find.text('worker-app logs'));
      await tester.pump();
      expect(routeOf(tester), const AppDetailRoute('worker-app', AppTab.logs));
      await tester.tap(find.text('demo-app'));
      await tester.pump();
      expect(routeOf(tester), const AppDetailRoute('demo-app', AppTab.processes));
      await finish(tester);
    });

    testAtAllSizes('many apps with long names fit', (tester, size) async {
      final names = [for (var i = 1; i <= 10; i++) 'an-application-with-a-very-long-name-$i'];
      final ssh = await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size, answers: {
        '--quiet apps:list': ok('${names.join('\n')}\n'),
        'events -t': ok([
          for (final n in names) event('post-config-update', '$n set ${'A_VERY_LONG_KEY' * 6}'),
        ].join()),
        'logs:failed --all': ok([
          for (final n in names) '=====> $n failed deploy logs\n${'the build failed because ' * 8}\n',
        ].join()),
      });
      // Only the first eight apps get a shortcut.
      expect(find.text('${names[7]} logs'), findsOneWidget);
      expect(find.text('${names[8]} logs'), findsNothing);
      expect(find.text('1 line'), findsNWidgets(10));
      expect(find.text('not deployed'), findsNWidgets(10));
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('has an empty state without apps', (tester, size) async {
      final ssh = await pumpScreen(tester, MonitoringScreen(host: dokkuHost), size: size, answers: {
        '--quiet apps:list': ok(''),
        'logs:failed --all': ok(''),
      });
      expect(find.text('No apps on this host yet. Create one to see its health here.'), findsOneWidget);
      expect(find.text('No crashed deploy containers.'), findsOneWidget);
      expect(find.textContaining(' logs'), findsNothing);
      expect(ssh.ran, isNot(includes(['checks:report'])));
      expect(ssh.missing, isEmpty);
    });
  });

  group('Datastores', () {
    final plugins = loadFixtures()['plugin:list']!.stdout;
    final info = loadFixtures()['redis:info cache']!.stdout;
    final withoutRedis = plugins.split('\n').where((l) => !l.contains('redis')).join('\n');
    final running = {'redis:info cache': ok(info.replaceFirst('restarting', 'running'))};
    final exposed = {'redis:info cache': ok(info.replaceFirst(RegExp(r'Exposed ports: +-'), 'Exposed ports:                 6379->16379'))};

    testAtAllSizes('shows plugins, services and links for the dokku user', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      expect(find.text('Datastores'), findsOneWidget);
      for (final name in ['PostgreSQL', 'Redis', 'MySQL', 'MariaDB', 'MongoDB', 'Elasticsearch', 'RabbitMQ', 'Meilisearch']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('INSTALLED'), findsOneWidget);
      expect(find.text('NOT INSTALLED'), findsNWidgets(7));
      expect(find.text('v2.1.0 · 1 service'), findsOneWidget);
      expect(find.text('redis:8.10.0 · dokku-redis-cache'), findsOneWidget);
      expect(find.text('restarting'), findsOneWidget);
      expect(find.text('internal network only'), findsOneWidget);
      expect(find.textContaining('installing plugins needs root'), findsOneWidget);
      expect(find.byTooltip('redis:unlink cache demo-app'), findsOneWidget);
      expect(find.byTooltip('redis:link cache worker-app'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('the dokku user cannot install plugins', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      final install = tester.widgetList<Btn>(find.widgetWithText(Btn, 'Install plugin'));
      expect(install, hasLength(7));
      expect(install.every((b) => b.onPressed == null && b.tooltip!.contains('needs root')), isTrue);
      await tester.tap(find.text('Install plugin').first);
      await settle(tester);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('a shell user installs a plugin', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: rootHost), size: size, host: rootHost);
      expect(find.textContaining('installing plugins needs root'), findsNothing);
      await tester.ensureVisible(find.text('Install plugin').first);
      await tester.tap(find.text('Install plugin').first);
      await settle(tester);
      expect(ssh.changes, [
        ['plugin:install', 'https://github.com/dokku/dokku-postgres.git', '--name', 'postgres'],
      ]);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('has an empty state without plugins', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size, answers: {
        'plugin:list': ok(withoutRedis),
      });
      expect(find.text('No services yet. Install a datastore plugin first.'), findsOneWidget);
      expect(find.text('Provision a service to link it to apps.'), findsOneWidget);
      expect(find.text('NOT INSTALLED'), findsNWidgets(8));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Provision service')).onPressed, isNull);
      expect(ssh.ran, isNot(includes(['redis:list'])));
      expect(ssh.missing, isEmpty);
    });

    testWidgets('has an empty state without services', (tester) async {
      await pumpScreen(tester, DatastoresScreen(host: dokkuHost), answers: {
        'redis:list': ok('=====> redis services\n'),
      });
      expect(find.text('No services yet. Provision one above.'), findsOneWidget);
      expect(find.text('v2.1.0 · 0 services'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('provision opens the dialog for that plugin', (tester) async {
      await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      await tester.tap(find.text('Provision'));
      await settle(tester);
      expect(find.text('Provision Redis service'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      await tester.tap(find.text('Provision service'));
      await settle(tester);
      expect(find.text('Provision Redis service'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('start runs for a service that is not running', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      expect(find.text('Stop'), findsNothing);
      await tester.tap(find.text('Start'));
      await settle(tester);
      expect(ssh.changes, [['redis:start', 'cache']]);
      expect(find.text('\$ dokku redis:start cache'), findsNWidgets(2));
      await finish(tester);
    });

    testWidgets('stop asks first and does nothing when cancelled', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), answers: running);
      expect(find.text('running'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await settle(tester);
      expect(find.text('Stop cache?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(ssh.changes, isEmpty);

      await tester.tap(find.text('Stop'));
      await settle(tester);
      await tester.tap(find.text('Stop service'));
      await settle(tester);
      expect(ssh.changes, [['redis:stop', 'cache']]);
      await finish(tester);
    });

    testWidgets('destroy needs the name typed', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      await tester.tap(find.text('Destroy'));
      await settle(tester);
      expect(find.text('Destroy cache?'), findsOneWidget);
      expect(find.text('Still linked to demo-app. Unlink first, or destroying will fail.'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Destroy service')).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(ssh.changes, isEmpty);

      await tester.tap(find.text('Destroy'));
      await settle(tester);
      await tester.enterText(inputs, 'cache');
      await settle(tester);
      await tester.tap(find.text('Destroy service'));
      await settle(tester);
      expect(ssh.changes, [['redis:destroy', 'cache', '--force']]);
      await finish(tester);
    });

    testAtAllSizes('info shows the details with the password hidden', (tester, size) async {
      await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      expect(find.byType(CodeBlock), findsNothing);
      await tester.ensureVisible(find.text('Info'));
      await tester.tap(find.text('Info'));
      await settle(tester);
      final shown = tester.widget<CodeBlock>(find.byType(CodeBlock)).text;
      expect(shown, contains('redis://:••••••••@dokku-redis-cache:6379'));
      expect(shown, isNot(contains('0123456789abcdef')));
      expect(shown, contains('status                 restarting'));
      await tester.tap(find.text('Info'));
      await settle(tester);
      expect(find.byType(CodeBlock), findsNothing);
    });

    testAtAllSizes('expose asks for the port and warns', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      await tester.ensureVisible(find.byType(AppSwitch));
      await tester.tap(find.byType(AppSwitch));
      await settle(tester);
      expect(find.text('Expose cache'), findsOneWidget);
      expect(find.textContaining('opens the datastore to the internet'), findsOneWidget);
      expect(find.text('\$ dokku redis:expose cache 16379'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(ssh.changes, isEmpty);

      await tester.tap(find.byType(AppSwitch));
      await settle(tester);
      await tester.enterText(inputs, '7');
      await settle(tester);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Expose')).onPressed, isNull);
      await tester.enterText(inputs, '26379');
      await settle(tester);
      await tester.tap(find.widgetWithText(Btn, 'Expose'));
      await settle(tester);
      expect(ssh.changes, [['redis:expose', 'cache', '26379']]);
      expect(find.text('Expose cache'), findsNothing);
    });

    testWidgets('unexpose runs when the switch is turned off', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), answers: exposed);
      expect(find.text('6379->16379'), findsOneWidget);
      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isTrue);
      await tester.tap(find.byType(AppSwitch));
      await settle(tester);
      expect(ssh.changes, [['redis:unexpose', 'cache']]);
      await finish(tester);
    });

    testAtAllSizes('backs up now, saves credentials and schedules', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      String preview() => tester.widget<CodeBlock>(find.byType(CodeBlock)).text;
      await tester.ensureVisible(find.text('Back up…'));
      await tester.tap(find.text('Back up…'));
      await settle(tester);
      expect(find.text('Back up cache'), findsOneWidget);
      expect(preview(), '\$ dokku redis:backup cache <bucket>');
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Run backup')).onPressed, isNull);

      await tester.enterText(inputs, 'acme-backups');
      await tester.tap(find.textContaining('--use-iam'));
      await settle(tester);
      expect(preview(), '\$ dokku redis:backup cache acme-backups --use-iam');
      await tester.tap(find.text('Run backup'));
      await settle(tester);

      await tester.tap(find.text('S3 credentials'));
      await settle(tester);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Save credentials')).onPressed, isNull);
      final fields = inputs;
      await tester.enterText(fields.at(0), 'AKIAEXAMPLE');
      await tester.enterText(fields.at(1), 's3cr3t-value');
      await tester.enterText(fields.at(3), 'https://s3.example.com');
      await settle(tester);
      expect(preview(), '\$ dokku redis:backup-auth cache <key-id> <secret> us-east-1 v4 https://s3.example.com');
      await tester.tap(find.text('Save credentials'));
      await settle(tester);

      await tester.tap(find.text('Schedule'));
      await settle(tester);
      expect(preview(), "\$ dokku redis:backup-schedule cache '0 2 * * *' acme-backups --use-iam");
      await tester.tap(find.widgetWithText(Btn, 'Schedule'));
      await settle(tester);
      await tester.tap(find.text('Remove schedule'));
      await settle(tester);

      expect(ssh.changes, [
        ['redis:backup', 'cache', 'acme-backups', '--use-iam'],
        ['redis:backup-auth', 'cache', 'AKIAEXAMPLE', 's3cr3t-value', 'us-east-1', 'v4', 'https://s3.example.com'],
        ['redis:backup-schedule', 'cache', '0 2 * * *', 'acme-backups', '--use-iam'],
        ['redis:backup-unschedule', 'cache'],
      ]);
      expect(find.text('Back up cache'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await settle(tester);
      expect(find.text('Back up cache'), findsNothing);
    });

    testWidgets('credentials without a region or endpoint are sent alone', (tester) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      await tester.tap(find.text('Back up…'));
      await settle(tester);
      await tester.tap(find.text('S3 credentials'));
      await settle(tester);
      await tester.enterText(inputs.at(0), 'AKIAEXAMPLE');
      await tester.enterText(inputs.at(1), 's3cr3t-value');
      await settle(tester);
      await tester.tap(find.text('Save credentials'));
      await settle(tester);
      expect(ssh.changes, [['redis:backup-auth', 'cache', 'AKIAEXAMPLE', 's3cr3t-value']]);
      await finish(tester);
    });

    testWidgets('a schedule needs five cron fields', (tester) async {
      await pumpScreen(tester, DatastoresScreen(host: dokkuHost));
      await tester.tap(find.text('Back up…'));
      await settle(tester);
      await tester.tap(find.text('Schedule'));
      await settle(tester);
      await tester.enterText(inputs.at(0), 'acme-backups');
      await tester.enterText(inputs.at(1), '0 2 * *');
      await settle(tester);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Schedule')).onPressed, isNull);
      await tester.enterText(inputs.at(1), '0 2 * * 1');
      await settle(tester);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Schedule')).onPressed, isNotNull);
      await finish(tester);
    });

    testAtAllSizes('tapping an empty cell links the service', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      await tester.ensureVisible(find.byTooltip('redis:link cache worker-app'));
      await tester.tap(find.byTooltip('redis:link cache worker-app'));
      await settle(tester);
      expect(ssh.changes, [['redis:link', 'cache', 'worker-app']]);
      expect(find.text('\$ dokku redis:link cache worker-app'), findsNWidgets(2));
    });

    testAtAllSizes('tapping a linked cell asks before unlinking', (tester, size) async {
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size);
      final cell = find.byTooltip('redis:unlink cache demo-app');
      await tester.ensureVisible(cell);
      await tester.tap(cell);
      await settle(tester);
      expect(find.text('Unlink cache from demo-app?'), findsOneWidget);
      expect(find.text('Removes REDIS_URL from demo-app and restarts it.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(ssh.changes, isEmpty);

      await tester.tap(cell);
      await settle(tester);
      await tester.tap(find.text('Unlink'));
      await settle(tester);
      expect(ssh.changes, [['redis:unlink', 'cache', 'demo-app']]);
    });

    testAtAllSizes('the link matrix scrolls sideways with many apps', (tester, size) async {
      final names = [for (var i = 1; i <= 14; i++) 'service-with-a-long-name-$i'];
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size, answers: {
        '--quiet apps:list': ok('${names.join('\n')}\n'),
      });
      final matrix = find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal);
      final position = tester.state<ScrollableState>(find.descendant(of: matrix, matching: find.byType(Scrollable))).position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(tester.getSize(matrix).width, lessThanOrEqualTo(size.width));

      final last = find.byTooltip('redis:link cache ${names.last}');
      await tester.ensureVisible(last);
      await tester.tap(last);
      await settle(tester);
      expect(ssh.changes, [['redis:link', 'cache', names.last]]);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('several services with long names and statuses fit', (tester, size) async {
      const long = 'a-cache-with-a-very-long-service-name';
      final ssh = await pumpScreen(tester, DatastoresScreen(host: dokkuHost), size: size, answers: {
        'plugin:list': ok('$plugins  postgres             1.41.0 enabled    dokku postgres service plugin\n'),
        'redis:list': ok('=====> redis services\ncache\n$long\n'),
        'postgres:list': ok('=====> postgres services\nmain-db\n'),
        'redis:info $long': ok(info
            .replaceFirst('restarting', 'exited (137) about three hours ago')
            .replaceFirst(RegExp(r'Exposed ports: +-'), 'Exposed ports:                 6379->16379 6380->16380 6381->16381')
            .replaceFirst(RegExp(r'Backup schedule: +'), 'Backup schedule:               0 2 * * * a-bucket-with-a-very-long-name\n')
            .replaceFirst(RegExp(r'Links: +demo-app'), 'Links:                         -')),
        'postgres:info main-db': ok(info.replaceFirst('restarting', 'running').replaceAll('redis', 'postgres')),
      });
      expect(find.text('INSTALLED'), findsNWidgets(2));
      expect(find.text('v2.1.0 · 2 services'), findsOneWidget);
      expect(find.text('exited (137) about three hours ago'), findsOneWidget);
      expect(find.text('0 2 * * * a-bucket-with-a-very-long-name'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Start'), findsNWidgets(2));
      expect(find.byTooltip('postgres:unlink main-db demo-app'), findsOneWidget);
      expect(find.byTooltip('redis:link $long demo-app'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('says so when the plugins cannot be listed', (tester) async {
      await pumpScreen(tester, DatastoresScreen(host: dokkuHost), answers: {
        'plugin:list': failed(' !     Permission denied\n'),
      });
      expect(find.textContaining('Could not list the datastores'), findsOneWidget);
      expect(find.textContaining('Permission denied'), findsOneWidget);
      await finish(tester);
    });
  });
}
