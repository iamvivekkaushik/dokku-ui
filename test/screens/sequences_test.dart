import 'dart:async';

import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:dokku_console/ui/screens/app/processes.dart';
import 'package:dokku_console/ui/screens/app/routing.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Holds every change until the test lets it finish, like a slow server.
class _Slow extends FakeSsh {
  _Slow(super.fixtures);

  final _waiting = <Completer<void>>[];

  /// Lets the command that is running now finish.
  Future<void> finishOne(WidgetTester tester) async {
    _waiting.removeAt(0).complete();
    await settle(tester, frames: 3);
  }

  @override
  Future<RemoteStream> dokkuStream(Host h, List<String> args,
      {Pty? pty, List<int>? stdin, required void Function(String chunk, bool isStderr) onData}) async {
    final gate = Completer<void>();
    _waiting.add(gate);
    await gate.future;
    return super.dokkuStream(h, args, pty: pty, stdin: stdin, onData: onData);
  }
}

/// Shows [tab] until the test replaces it, the way leaving a screen does.
class _Page extends StatefulWidget {
  const _Page(this.tab);
  final Widget tab;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  var _open = true;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextButton(onPressed: () => setState(() => _open = false), child: const Text('Leave')),
          if (_open) widget.tab else const Text('Somewhere else'),
        ]),
      );
}

Future<void> _leave(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Leave'));
  await tester.tap(find.text('Leave'));
  await settle(tester, frames: 3);
  expect(find.text('Somewhere else'), findsOneWidget);
}

Future<void> _press(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await settle(tester, frames: 3);
}

void main() {
  // A change made of several commands must not be left half made because the
  // user moved to another screen while the first command was still running.
  group('Leaving the screen', () {
    const limits = '=====> demo-app resource information\n'
        '       _default_ limit cpu:           1\n'
        '       _default_ limit memory:        512m\n';

    testWidgets('does not leave limits cleared without setting the others again', (tester) async {
      final ssh = await pumpScreen(
        tester,
        _Page(ProcessesTab(host: dokkuHost, app: 'demo-app')),
        answers: {'resource:report demo-app': ok(limits)},
        fake: _Slow.new,
      ) as _Slow;
      await tester.enterText(find.byWidgetPredicate((w) => w is AppInput && w.hint == '1.0'), '');
      await settle(tester, frames: 2);
      await _press(tester, find.text('Apply limits'));
      expect(ssh.changes, isEmpty, reason: 'the first command is still on its way');

      await _leave(tester);
      await ssh.finishOne(tester);
      await ssh.finishOne(tester);
      expect(tester.takeException(), isNull);
      expect(ssh.changes, [
        ['resource:limit-clear', '--process-type', '_default_', 'demo-app'],
        ['resource:limit', '--memory', '512m', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('still rebuilds the proxy config after a setting was changed', (tester) async {
      final ssh = await pumpScreen(tester, _Page(RoutingTab(host: dokkuHost, app: 'demo-app')), fake: _Slow.new) as _Slow;
      await _press(tester, find.descendant(of: find.widgetWithText(SwitchRow, 'HSTS'), matching: find.byType(AppSwitch)));
      await _leave(tester);
      await ssh.finishOne(tester);
      await ssh.finishOne(tester);
      expect(tester.takeException(), isNull);
      expect(ssh.changes.map((c) => c.first), ['nginx:set', 'proxy:build-config']);
      await finish(tester);
    });
  });
}
