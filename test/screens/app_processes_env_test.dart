import 'dart:convert';
import 'dart:typed_data';

import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/ui/screens/app/env.dart';
import 'package:dokku_console/ui/screens/app/processes.dart';
import 'package:dokku_console/ui/shell/terminal.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _masked = '••••••••••••••••';

/// Tabs do not scroll by themselves; the app detail page does that for them.
Widget _page(Widget tab) => SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: tab));

Widget _processes([String app = 'demo-app', Host? host]) => _page(ProcessesTab(host: host ?? dokkuHost, app: app));

Widget _env([String app = 'demo-app']) => _page(EnvTab(host: dokkuHost, app: app));

Finder _input(String hint) => find.byWidgetPredicate((w) => w is AppInput && w.hint == hint);

/// A control inside the table row that shows [text].
Finder _inRow(String text, Finder control) =>
    find.descendant(of: find.ancestor(of: find.text(text), matching: find.byType(PanelRow)), matching: control);

Future<void> _press(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await settle(tester);
}

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, text);
  await settle(tester, frames: 2);
}

String _b64(String value) => base64.encode(utf8.encode(value));

final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this.text);
  @override
  final String name;
  final String text;

  Uint8List get _bytes => Uint8List.fromList(utf8.encode(text));

  @override
  Uri get uri => Uri(scheme: 'memory', path: name);
  @override
  get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => _bytes.length;
  @override
  Future<int?> length() async => _bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => _bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

/// Stands in for the system file dialogs.
class _FakeFiles extends FilePickerPlatform {
  _PickedFile? next;
  final saved = <String, String>{};

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      next;

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
    return Uri.file('/downloads/$fileName');
  }
}

const _noTypes = '-----> Scaling for worker-app\nproctype: qty\n--------: ---\n';
const _cronId = '5cruaotm4yzzpnjlsdunblj8qyjp';
const _cronList = '[{"id":"$_cronId","app":"demo-app","command":"node scripts/cleanup.js","schedule":"0 3 * * *"},'
    '{"id":"b2","app":"demo-app","command":"node scripts/report.js --weekly","schedule":"*/15 * * * *"}]';

Btn apply(WidgetTester tester) => tester.widget<Btn>(find.widgetWithText(Btn, 'Apply limits'));

void main() {
  group('Processes', () {
    testAtAllSizes('shows process types, resources, checks and scheduler', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes(), size: size);
      expect(find.text('Process types'), findsOneWidget);
      expect(find.text('web'), findsNWidgets(2)); // scaling row and checks row
      expect(find.text('2 running'), findsOneWidget);
      expect(find.text('web.1'), findsNWidgets(2)); // enter button and status dot
      expect(find.text('web.2'), findsNWidgets(2));
      expect(find.text('No scheduled tasks. Add a cron block to app.json and deploy again.'), findsOneWidget);
      expect(tester.widget<AppInput>(_input('1.0')).controller!.text, '1');
      expect(tester.widget<AppInput>(_input('512m')).controller!.text, '512m');
      expect(tester.widget<AppInput>(_input('—').first).controller!.text, isEmpty);
      expect(find.text('web: reserve-memory 128m'), findsOneWidget);
      expect(find.text('wait to retire 60s'), findsOneWidget);
      expect(find.text('on-failure:10'), findsOneWidget);
      expect(find.textContaining('through the Docker daemon'), findsOneWidget);
      expect(find.text('\$ dokku ps:scale demo-app web=2'), findsOneWidget);
      expect(
        find.text('\$ dokku resource:limit --cpu <cpus> --memory <size> demo-app\n'
            '\$ dokku resource:reserve --cpu <cpus> --memory <size> demo-app'),
        findsOneWidget,
      );
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('renders the same for a shell user', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes('demo-app', rootHost), size: size, host: rootHost);
      expect(find.text('2 running'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('an app that is not deployed cannot be started or checked', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes('worker-app'), size: size);
      expect(find.text('0 running'), findsOneWidget);
      expect(find.text('none running'), findsOneWidget);
      for (final label in ['Start', 'Stop', 'Restart', 'Rebuild', 'Run checks']) {
        expect(tester.widget<Btn>(find.widgetWithText(Btn, label)).onPressed, isNull, reason: label);
      }
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('says so when there are no process types', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes('worker-app'), size: size, answers: {'ps:scale worker-app': ok(_noTypes)});
      expect(find.textContaining('No process types yet. They come from the Procfile'), findsOneWidget);
      expect(find.textContaining('No process types yet. Checks appear here'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Apply scale')).onPressed, isNull);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('a failed lookup is explained in the card', (tester) async {
      await pumpScreen(tester, _processes(), answers: {'ps:scale demo-app': failed(' !     App demo-app is locked\n')});
      expect(find.textContaining('Could not read the process types.'), findsOneWidget);
      expect(find.textContaining('Could not read the checks.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('apply scale is enabled by a change and sends every count', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      Btn apply() => tester.widget<Btn>(find.widgetWithText(Btn, 'Apply scale'));
      expect(apply().onPressed, isNull);

      await _press(tester, find.text('+'));
      expect(find.text('2 running → 3'), findsOneWidget);
      expect(find.text('\$ dokku ps:scale demo-app web=3'), findsOneWidget);
      expect(apply().onPressed, isNotNull);

      await _press(tester, find.text('−'));
      expect(apply().onPressed, isNull, reason: 'back at the saved count');

      await _press(tester, find.text('+'));
      await _press(tester, find.text('Apply scale'));
      expect(ssh.changes, [
        ['ps:scale', 'demo-app', 'web=3'],
      ]);
      await finish(tester);
    });

    testWidgets('a process type can be added before scaling', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      Btn add() => tester.widget<Btn>(find.widgetWithText(Btn, 'Add type'));
      expect(add().onPressed, isNull);

      await _type(tester, _input('Process type, e.g. worker'), 'web');
      expect(add().onPressed, isNull, reason: 'web is already listed');

      await _type(tester, _input('Process type, e.g. worker'), 'wor ker!');
      expect(find.text('worker'), findsOneWidget, reason: 'only letters, digits, dashes and underscores');
      await _press(tester, find.text('Add type'));
      expect(find.text('0 running → 1'), findsOneWidget);

      await _press(tester, find.text('Apply scale'));
      expect(ssh.changes, [
        ['ps:scale', 'demo-app', 'web=2', 'worker=1'],
      ]);
      await finish(tester);
    });

    testWidgets('restart and rebuild run at once', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.text('Restart'));
      await _press(tester, find.text('Rebuild'));
      await _press(tester, find.text('Start'));
      expect(ssh.changes, [
        ['ps:restart', 'demo-app'],
        ['ps:rebuild', 'demo-app'],
        ['ps:start', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('stop asks first and does nothing when cancelled', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.text('Stop'));
      expect(find.text('Stop demo-app?'), findsOneWidget);
      await _press(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('Stop'));
      await _press(tester, find.text('Stop app'));
      expect(ssh.changes, [
        ['ps:stop', 'demo-app'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('a one-off command opens a terminal with separate arguments', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes(), size: size);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Run')).onPressed, isNull);

      await _type(tester, _input('npm run migrate'), 'sh -c "echo hello world"');
      expect(find.textContaining("\$ dokku run demo-app sh -c 'echo hello world'"), findsOneWidget);
      await _press(tester, find.text('Run'));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byTooltip('Close terminal'), findsOneWidget);
      expect(ssh.changes, [
        ['run', 'demo-app', 'sh', '-c', 'echo hello world'],
      ]);
      await _press(tester, find.byTooltip('Close terminal'));
      expect(find.byTooltip('Close terminal'), findsNothing);
    });

    testWidgets('a detached command runs in the background', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _type(tester, _input('npm run migrate'), 'rake db:migrate');
      await _press(tester, find.text('Run detached'));
      expect(find.byTooltip('Close terminal'), findsNothing);
      expect(ssh.changes, [
        ['run:detached', 'demo-app', 'rake', 'db:migrate'],
      ]);
      await finish(tester);
    });

    testWidgets('an open quote is explained and nothing runs', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _type(tester, _input('npm run migrate'), 'echo "hello');
      await _press(tester, find.text('Run'));
      expect(find.textContaining('A quote in this command is not closed.'), findsOneWidget);
      await _press(tester, find.text('Run detached'));
      expect(find.textContaining('A quote in this command is not closed.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(ssh.changes, isEmpty);

      await _type(tester, _input('npm run migrate'), 'echo "hello"');
      expect(find.textContaining('A quote in this command is not closed.'), findsNothing);
      await finish(tester);
    });

    testWidgets('entering a container opens a terminal on that process', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.widgetWithText(Btn, 'web.2'));
      await tester.pump(const Duration(seconds: 3));
      expect(ssh.changes, [
        ['enter', 'demo-app', 'web.2'],
      ]);
      expect(find.text('live'), findsOneWidget);
      await _press(tester, find.byTooltip('Close terminal'));
      await finish(tester);
    });

    testWidgets('an image without bash gets sh instead', (tester) async {
      const noBash = 'OCI runtime exec failed: exec failed: unable to start container process: '
          'exec: "/bin/bash": stat /bin/bash: no such file or directory\r\n';
      final ssh = await pumpScreen(tester, _processes(), answers: {'enter demo-app web.2': failed(noBash, code: 127)});
      await _press(tester, find.widgetWithText(Btn, 'web.2'));
      await tester.pump(const Duration(seconds: 3));
      expect(ssh.changes, [
        ['enter', 'demo-app', 'web.2'],
        ['enter', 'demo-app', 'web.2', 'sh'],
      ]);
      expect(find.text('live'), findsOneWidget);
      await _press(tester, find.byTooltip('Close terminal'));
      await finish(tester);
    });

    testWidgets('a program the user asked for is not swapped for sh', (tester) async {
      const noPython = 'exec: "python": executable file not found in \$PATH\r\n';
      final ssh = await pumpScreen(
        tester,
        TerminalPane(host: dokkuHost, spec: const TerminalSpec.dokku(['enter', 'demo-app', 'web.2', 'python']), title: 'enter'),
        answers: {'enter demo-app web.2 python': failed(noPython, code: 127)},
      );
      await tester.pump(const Duration(seconds: 3));
      expect(ssh.changes, [
        ['enter', 'demo-app', 'web.2', 'python'],
      ]);
      expect(find.text('exited 127'), findsOneWidget);
      await finish(tester);
    });

    testAtAllSizes('lists scheduled tasks and runs one now', (tester, size) async {
      final ssh = await pumpScreen(tester, _processes(), size: size, answers: {'cron:list demo-app --format json': ok(_cronList)});
      expect(find.text('node scripts/cleanup.js'), findsOneWidget);
      expect(find.text('0 3 * * * · daily at 03:00 · id 5cruaotm4y…'), findsOneWidget);
      expect(find.text('*/15 * * * * · every 15 min · id b2'), findsOneWidget);
      expect(find.textContaining('No scheduled tasks'), findsNothing);

      await _press(tester, find.text('Run now').first);
      expect(ssh.changes, [
        ['cron:run', 'demo-app', _cronId],
      ]);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('an older Dokku without cron:list is explained', (tester) async {
      await pumpScreen(tester, _processes(), answers: {'cron:list demo-app --format json': unknownCommand('cron:list')});
      expect(find.textContaining('This Dokku version cannot list scheduled tasks.'), findsOneWidget);
      expect(find.textContaining('No scheduled tasks'), findsNothing);
      await finish(tester);
    });

    testWidgets('resources apply limits, then reservations', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      expect(apply(tester).onPressed, isNull, reason: 'nothing was changed yet');

      await _type(tester, _input('1.0'), ' 2 ');
      await _type(tester, _input('—').last, '256m');
      expect(find.text('\$ dokku resource:limit --cpu 2 --memory 512m demo-app\n\$ dokku resource:reserve --memory 256m demo-app'),
          findsOneWidget);
      await _press(tester, find.text('Apply limits'));
      expect(ssh.changes, [
        ['resource:limit', '--cpu', '2', '--memory', '512m', 'demo-app'],
        ['resource:reserve', '--memory', '256m', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('only the kind of resource that changed is sent', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _type(tester, _input('—').first, '0.5');
      await _press(tester, find.text('Apply limits'));
      expect(ssh.changes, [
        ['resource:reserve', '--cpu', '0.5', 'demo-app'],
      ]);
      await finish(tester);
    });

    // Dokku ignores an empty value, so the defaults are cleared and the rest set again.
    testWidgets('emptying a field removes that limit and keeps the others', (tester) async {
      const report = '=====> demo-app resource information\n'
          '       _default_ limit cpu:           1\n'
          '       _default_ limit memory:        512m\n'
          '       _default_ limit memory-swap:   1g\n'
          '       _default_ reserve memory:      128m\n'
          '       web limit cpu:                 2\n';
      final ssh = await pumpScreen(tester, _processes(), answers: {'resource:report demo-app': ok(report)});
      await _type(tester, _input('1.0'), '');
      expect(
        find.text('\$ dokku resource:limit-clear --process-type _default_ demo-app\n'
            '\$ dokku resource:limit --memory 512m --memory-swap 1g demo-app'),
        findsOneWidget,
      );
      await _press(tester, find.text('Apply limits'));
      expect(ssh.changes, [
        ['resource:limit-clear', '--process-type', '_default_', 'demo-app'],
        ['resource:limit', '--memory', '512m', '--memory-swap', '1g', 'demo-app'],
      ], reason: 'reservations and the limit for web are left alone');
      await finish(tester);
    });

    testWidgets('emptying the only limit just clears it', (tester) async {
      const report = '=====> demo-app resource information\n'
          '       _default_ reserve memory:      128m\n';
      final ssh = await pumpScreen(tester, _processes(), answers: {'resource:report demo-app': ok(report)});
      await _type(tester, _input('—').last, '');
      await _press(tester, find.text('Apply limits'));
      expect(ssh.changes, [
        ['resource:reserve-clear', '--process-type', '_default_', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('resources cannot be applied with every field empty', (tester) async {
      await pumpScreen(tester, _processes('worker-app'));
      expect(apply(tester).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('clearing resources asks first and does nothing when cancelled', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.text('Clear limits'));
      expect(find.text('Clear resource limits?'), findsOneWidget);
      await _press(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('Clear limits'));
      await _press(tester, find.widgetWithText(Btn, 'Clear limits').last);
      expect(ssh.changes, [
        ['resource:limit-clear', 'demo-app'],
        ['resource:reserve-clear', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('checks are switched per process type', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.text('enabled'));
      expect(ssh.changes, isEmpty, reason: 'already enabled');

      await _press(tester, find.text('skipped'));
      await _press(tester, find.text('disabled'));
      await _press(tester, find.text('Run checks'));
      expect(ssh.changes, [
        ['checks:skip', 'demo-app', 'web'],
        ['checks:disable', 'demo-app', 'web'],
        ['checks:run', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('checks that are off can be turned back on', (tester) async {
      const report = '=====> demo-app checks information\n'
          '       Checks disabled list:          _all_\n'
          '       Checks skipped list:           none\n'
          '       Checks computed wait to retire: 90\n';
      final ssh = await pumpScreen(tester, _processes(), answers: {'checks:report demo-app': ok(report)});
      expect(find.text('wait to retire 90s'), findsOneWidget);
      expect(tester.widget<Seg<Object>>(find.ancestor(of: find.text('disabled'), matching: find.bySubtype<Seg<Object>>())).value.toString(),
          contains('disabled'));
      await _press(tester, find.text('enabled'));
      expect(ssh.changes, [
        ['checks:enable', 'demo-app', 'web'],
      ]);
      await finish(tester);
    });

    testWidgets('the restart policy is saved once it differs', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      Btn save() => tester.widget<Btn>(find.widgetWithText(Btn, 'Save policy'));
      expect(save().onPressed, isNull);

      await _press(tester, find.text('on-failure:10'));
      await _press(tester, find.text('unless-stopped').last);
      expect(find.textContaining('\$ dokku ps:set demo-app restart-policy unless-stopped'), findsOneWidget);
      expect(save().onPressed, isNotNull);
      await _press(tester, find.text('Save policy'));
      expect(ssh.changes, [
        ['ps:set', 'demo-app', 'restart-policy', 'unless-stopped'],
      ]);
      await finish(tester);
    });

    testWidgets('a policy this app does not list is still offered', (tester) async {
      const report = '=====> demo-app ps information\n'
          '       Deployed:                      true\n'
          '       Ps restart policy:             on-failure:3\n'
          '       Status web 1:                  running (CID: 32e0eed506d)\n';
      await pumpScreen(tester, _processes(), answers: {'ps:report demo-app': ok(report)});
      expect(find.text('on-failure:3'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('switching the scheduler asks first', (tester) async {
      final ssh = await pumpScreen(tester, _processes());
      await _press(tester, find.text('k3s'));
      expect(find.text('Use the k3s scheduler for demo-app?'), findsOneWidget);
      await _press(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('null'));
      expect(find.textContaining('never starts containers'), findsOneWidget);
      await _press(tester, find.text('Switch scheduler'));
      expect(ssh.changes, [
        ['scheduler:set', 'demo-app', 'selected', 'null'],
      ]);
      await finish(tester);
    });

    testWidgets('what was typed survives the columns stacking', (tester) async {
      await pumpScreen(tester, _processes());
      await _type(tester, _input('npm run migrate'), 'rake db:migrate');
      await _press(tester, find.text('+'));

      tester.view.physicalSize = phone;
      await settle(tester);
      expect(find.text('rake db:migrate'), findsOneWidget);
      expect(find.text('2 running → 3'), findsOneWidget);
      await finish(tester);
    });
  });

  group('Environment', () {
    late _FakeFiles files;
    late FilePickerPlatform realFiles;

    setUp(() {
      realFiles = FilePickerPlatform.instance;
      FilePickerPlatform.instance = files = _FakeFiles();
    });
    tearDown(() => FilePickerPlatform.instance = realFiles);

    Btn save(WidgetTester tester) => tester.widget<Btn>(find.widgetWithText(Btn, 'Save changes'));

    Future<void> add(WidgetTester tester, String key, String value) async {
      await _type(tester, _input('NEW_KEY'), key);
      await _type(tester, _input('value'), value);
      await _press(tester, find.text('Add variable'));
    }

    testAtAllSizes('lists variables with secrets masked and system ones hidden', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      expect(find.text('Config vars · 5'), findsOneWidget);
      for (final key in ['DATABASE_URL', 'JWT_SIGNING_KEY', 'LOG_LEVEL', 'NODE_ENV', 'REDIS_URL']) {
        expect(find.text(key), findsOneWidget);
      }
      expect(find.text('info'), findsOneWidget);
      expect(find.text('production'), findsOneWidget);
      expect(find.text(_masked), findsNWidgets(3));
      expect(find.textContaining('s3cret'), findsNothing);
      expect(find.textContaining('ed25519'), findsNothing);
      expect(find.textContaining('0123456789abcdef'), findsNothing);
      for (final key in ['GIT_REV', 'DOKKU_APP_TYPE', 'DOKKU_PROXY_PORT', 'DOKKU_APP_RESTORE']) {
        expect(find.text(key), findsNothing);
      }
      expect(find.text('new'), findsNothing);
      expect(find.text('edited'), findsNothing);
      expect(save(tester).onPressed, isNull);
      expect(find.text('Discard'), findsNothing);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('says so when nothing is set', (tester, size) async {
      final ssh = await pumpScreen(tester, _env('worker-app'), size: size);
      expect(find.text('No config vars set. Add one below or import a .env file.'), findsOneWidget);
      expect(find.text('Config vars · 0'), findsOneWidget);
      expect(save(tester).onPressed, isNull);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('output that cannot be read is an error, not an empty list', (tester) async {
      await pumpScreen(tester, _env(), answers: {'config:export --format json demo-app': ok('{"LOG_LEVEL":')});
      expect(find.textContaining('Could not read the config vars.'), findsOneWidget);
      expect(find.textContaining('No config vars set'), findsNothing);
      expect(find.text('Add variable'), findsNothing);
      await finish(tester);
    });

    testAtAllSizes('a secret shows only once it is revealed', (tester, size) async {
      await pumpScreen(tester, _env(), size: size);
      await _press(tester, _inRow('DATABASE_URL', find.byTooltip('Reveal value')));
      expect(find.text('postgres://app:s3cret@db.internal:5432/app'), findsOneWidget);
      expect(find.textContaining('ed25519'), findsNothing, reason: 'the other secrets stay hidden');
      expect(find.text(_masked), findsNWidgets(2));

      await _press(tester, _inRow('DATABASE_URL', find.byTooltip('Hide value')));
      expect(find.textContaining('s3cret'), findsNothing);
    });

    testWidgets('reveal all shows every secret, and one can be hidden again', (tester) async {
      await pumpScreen(tester, _env());
      await _press(tester, find.text('Reveal all'));
      expect(find.textContaining('s3cret'), findsOneWidget);
      expect(find.textContaining('ed25519'), findsOneWidget);
      expect(find.text(_masked), findsNothing);

      await _press(tester, _inRow('DATABASE_URL', find.byTooltip('Hide value')));
      expect(find.textContaining('s3cret'), findsNothing);
      expect(find.textContaining('ed25519'), findsOneWidget);

      await _press(tester, find.text('Reveal all'));
      await _press(tester, find.text('Hide values'));
      expect(find.text(_masked), findsNWidgets(3));
      expect(find.textContaining('s3cret'), findsNothing);
      await finish(tester);
    });

    testAtAllSizes('keys only hides every value', (tester, size) async {
      await pumpScreen(tester, _env(), size: size);
      await _press(tester, find.text('Keys only'));
      expect(find.text('LOG_LEVEL'), findsOneWidget);
      expect(find.text('info'), findsNothing);
      expect(find.text(_masked), findsNothing);
      expect(find.byTooltip('Reveal value'), findsNothing);

      await _press(tester, find.text('Show values'));
      expect(find.text('info'), findsOneWidget);
    });

    testAtAllSizes('system shows the variables Dokku sets', (tester, size) async {
      await pumpScreen(tester, _env(), size: size);
      await _press(tester, find.text('System'));
      for (final key in ['GIT_REV', 'DOKKU_APP_TYPE', 'DOKKU_PROXY_PORT', 'DOKKU_APP_RESTORE']) {
        expect(find.text(key), findsOneWidget);
      }
      expect(find.text('Config vars · 9'), findsOneWidget);

      await _press(tester, find.text('System'));
      expect(find.text('GIT_REV'), findsNothing);
    });

    testAtAllSizes('an added variable is staged, masked, and sent encoded on save', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      await add(tester, 'api-token', 'hunter2 & "quotes"');
      expect(find.text('API_TOKEN'), findsOneWidget, reason: 'keys are upper-cased as they are typed');
      expect(find.text('new'), findsOneWidget);
      expect(find.text('edited'), findsNothing);
      expect(find.textContaining('hunter2'), findsNothing);
      expect(find.text('\$ dokku config:set --encoded demo-app API_TOKEN=•••'), findsOneWidget);
      expect(ssh.changes, isEmpty, reason: 'nothing is sent until it is saved');

      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', 'demo-app', 'API_TOKEN=${_b64('hunter2 & "quotes"')}'],
      ]);
      expect(find.text('new'), findsNothing);
      expect(save(tester).onPressed, isNull);
    });

    testWidgets('a key must start with a letter or an underscore', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      await _type(tester, _input('NEW_KEY'), '9lives');
      expect(find.text('A key starts with a letter or an underscore.'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Add variable')).onPressed, isNull);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('an edited value may span lines and is marked edited, never new', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      await _press(tester, find.text('info'));
      expect(find.text('LOG_LEVEL'), findsNWidgets(2)); // the row and the dialog title
      await tester.enterText(find.descendant(of: find.byType(AppDialog), matching: find.byType(AppInput)), 'debug\nverbose "x"');
      await _press(tester, find.text('Update value'));

      expect(find.text('edited'), findsOneWidget);
      expect(find.text('new'), findsNothing);
      expect(find.text('debug ↵ verbose "x"'), findsOneWidget);
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', 'demo-app', 'LOG_LEVEL=${_b64('debug\nverbose "x"')}'],
      ]);
    });

    testWidgets('closing the editor or typing the saved value stages nothing', (tester) async {
      await pumpScreen(tester, _env());
      await _press(tester, find.text('info'));
      await tester.enterText(find.descendant(of: find.byType(AppDialog), matching: find.byType(AppInput)), 'debug');
      await _press(tester, find.text('Cancel'));
      expect(find.text('edited'), findsNothing);

      await _press(tester, find.text('info'));
      await _press(tester, find.text('Update value'));
      expect(find.text('edited'), findsNothing);
      expect(save(tester).onPressed, isNull);
      await finish(tester);
    });

    testAtAllSizes('a deletion is listed, can be undone, and is sent on save', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      expect(find.text('NODE_ENV'), findsNothing);
      expect(find.text('will unset: NODE_ENV'), findsOneWidget);
      expect(find.text('\$ dokku config:unset demo-app NODE_ENV'), findsOneWidget);

      await _press(tester, find.text('Undo'));
      expect(find.text('NODE_ENV'), findsOneWidget);
      expect(find.textContaining('will unset'), findsNothing);
      expect(save(tester).onPressed, isNull);

      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      await _press(tester, _inRow('LOG_LEVEL', find.byTooltip('Delete variable')));
      expect(ssh.changes, isEmpty);
      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:unset', 'demo-app', 'NODE_ENV', 'LOG_LEVEL'],
      ]);
    });

    testWidgets('deleting a variable that was only staged sends nothing', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('FEATURE_X', find.byTooltip('Delete variable')));
      expect(find.text('FEATURE_X'), findsNothing);
      expect(find.textContaining('will unset'), findsNothing);
      expect(save(tester).onPressed, isNull);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('sets first, then unsets, and skips the restart when asked', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      await _press(tester, find.byType(AppSwitch));
      expect(find.text('\$ dokku config:set --encoded --no-restart demo-app KEY=<base64>\n\$ dokku config:unset --no-restart demo-app KEY'),
          findsOneWidget);

      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', '--no-restart', 'demo-app', 'FEATURE_X=${_b64('on')}'],
        ['config:unset', '--no-restart', 'demo-app', 'NODE_ENV'],
      ]);
      await finish(tester);
    });

    testWidgets('a failed set stops before anything is unset and keeps the changes', (tester) async {
      final set = 'config:set --encoded --no-restart demo-app FEATURE_X=${_b64('on')}';
      final ssh = await pumpScreen(tester, _env(), answers: {set: failed(' !     Invalid key\n')});
      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [set.split(' ')]);
      expect(find.text('new'), findsOneWidget);
      expect(find.text('will unset: NODE_ENV'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a failed unset keeps the deletion staged', (tester) async {
      final ssh = await pumpScreen(tester, _env(), answers: {'config:unset demo-app NODE_ENV': failed(' !     Invalid key\n')});
      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', '--no-restart', 'demo-app', 'FEATURE_X=${_b64('on')}'],
        ['config:unset', 'demo-app', 'NODE_ENV'],
      ]);
      expect(find.text('will unset: NODE_ENV'), findsOneWidget);
      expect(find.text('\$ dokku config:unset demo-app NODE_ENV'), findsOneWidget, reason: 'the set is not sent twice');
      expect(find.textContaining('the app was not restarted'), findsOneWidget);
      expect(save(tester).onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('restarts the app once when variables are both set and removed', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      expect(
        find.text('\$ dokku config:set --encoded --no-restart demo-app FEATURE_X=•••\n\$ dokku config:unset demo-app NODE_ENV'),
        findsOneWidget,
      );
      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', '--no-restart', 'demo-app', 'FEATURE_X=${_b64('on')}'],
        ['config:unset', 'demo-app', 'NODE_ENV'],
      ]);
      expect(find.textContaining('the app was not restarted'), findsNothing);
      await finish(tester);
    });

    testWidgets('discard drops everything that was staged', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      await add(tester, 'FEATURE_X', 'on');
      await _press(tester, _inRow('NODE_ENV', find.byTooltip('Delete variable')));
      await _press(tester, find.text('Discard'));
      expect(find.text('FEATURE_X'), findsNothing);
      expect(find.text('NODE_ENV'), findsOneWidget);
      expect(save(tester).onPressed, isNull);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    const dotenv = '# staging\n'
        'LOG_LEVEL=debug\n'
        'export GREETING="hello world"\n'
        'NODE_ENV=production\n';

    testAtAllSizes('importing a file merges it into the staged changes', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      files.next = _PickedFile('staging.env', dotenv);
      await _press(tester, find.text('Import .env'));
      expect(find.text('staging.env'), findsOneWidget);
      expect(find.textContaining('3 variables found.'), findsOneWidget);

      await _press(tester, find.text('Merge'));
      expect(find.text('GREETING'), findsOneWidget);
      expect(find.text('hello world'), findsOneWidget);
      expect(find.text('debug'), findsOneWidget);
      expect(find.text('new'), findsOneWidget);
      expect(find.text('edited'), findsOneWidget, reason: 'NODE_ENV already has that value');
      expect(find.textContaining('will unset'), findsNothing);
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', 'demo-app', 'LOG_LEVEL=${_b64('debug')}', 'GREETING=${_b64('hello world')}'],
      ]);
    });

    testAtAllSizes('replace all also unsets what the file leaves out', (tester, size) async {
      final ssh = await pumpScreen(tester, _env(), size: size);
      files.next = _PickedFile('staging.env', dotenv);
      await _press(tester, find.text('Import .env'));
      await _press(tester, find.text('Replace all'));
      expect(find.text('will unset: DATABASE_URL JWT_SIGNING_KEY REDIS_URL'), findsOneWidget);
      expect(find.text('Config vars · 3'), findsOneWidget);
      expect(ssh.changes, isEmpty);

      await _press(tester, find.text('Save changes'));
      expect(ssh.changes, [
        ['config:set', '--encoded', '--no-restart', 'demo-app', 'LOG_LEVEL=${_b64('debug')}', 'GREETING=${_b64('hello world')}'],
        ['config:unset', 'demo-app', 'DATABASE_URL', 'JWT_SIGNING_KEY', 'REDIS_URL'],
      ], reason: 'the variables Dokku sets itself are left alone');
    });

    testWidgets('an import can be edited or cancelled before it is staged', (tester) async {
      final ssh = await pumpScreen(tester, _env());
      files.next = _PickedFile('staging.env', dotenv);
      await _press(tester, find.text('Import .env'));
      await tester.enterText(find.descendant(of: find.byType(AppDialog), matching: find.byType(AppInput)), 'ONLY=this');
      await settle(tester, frames: 2);
      expect(find.textContaining('1 variable found.'), findsOneWidget);
      await _press(tester, find.text('Cancel'));
      expect(find.text('ONLY'), findsNothing);
      expect(save(tester).onPressed, isNull);

      files.next = null; // the file dialog was closed without a choice
      await _press(tester, find.text('Import .env'));
      expect(find.byType(AppDialog), findsNothing);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('a file with no variables cannot be imported', (tester) async {
      await pumpScreen(tester, _env());
      files.next = _PickedFile('notes.txt', 'nothing to see here\n');
      await _press(tester, find.text('Import .env'));
      expect(find.textContaining('0 variables found.'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Merge')).onPressed, isNull);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Replace all')).onPressed, isNull);
      await _press(tester, find.text('Cancel'));
      await finish(tester);
    });

    testAtAllSizes('a file that is too large is refused with a reason', (tester, size) async {
      await pumpScreen(tester, _env(), size: size);
      files.next = _PickedFile('huge.env', 'A=${'x' * 300000}\n');
      await _press(tester, find.text('Import .env'));
      expect(find.text('Could not read that file. That file is too large to be a key or config file.'), findsOneWidget);
      expect(find.byType(AppDialog), findsNothing);

      await _press(tester, find.byTooltip('Dismiss'));
      expect(find.textContaining('Could not read that file.'), findsNothing);
    });

    testWidgets('exports what is listed as env, json or shell', (tester) async {
      await pumpScreen(tester, _env());
      await add(tester, 'GREETING', "it's here");

      await _press(tester, find.text('Export'));
      final env = files.saved['demo-app.env']!.split('\n');
      expect(env, contains('DATABASE_URL=postgres://app:s3cret@db.internal:5432/app'));
      expect(env, contains('LOG_LEVEL=info'));
      expect(env, contains(r"GREETING='it'\''s here'"));
      expect(env.where((l) => l.startsWith('GIT_REV')), isEmpty, reason: 'system variables are hidden');
      expect(env.last, isEmpty, reason: 'ends with a line break');

      await _press(tester, find.text('shell'));
      await _press(tester, find.text('Export'));
      expect(files.saved['demo-app.env']!.split('\n'), contains('export LOG_LEVEL=info'));

      await _press(tester, find.text('json'));
      await _press(tester, find.text('System'));
      await _press(tester, find.text('Export'));
      final json = jsonDecode(files.saved['demo-app.json']!) as Map<String, dynamic>;
      expect(json['NODE_ENV'], 'production');
      expect(json['GREETING'], "it's here");
      expect(json['DOKKU_APP_TYPE'], 'dockerfile');
      expect(json, hasLength(10));
      await finish(tester);
    });
  });
}
