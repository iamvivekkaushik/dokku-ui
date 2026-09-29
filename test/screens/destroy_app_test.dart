import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/apps.dart';
import 'package:dokku_console/ui/shell/destroy_dialog.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Future<void> _press(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await settle(tester);
}

Finder get _dialog => find.byType(DestroyAppDialog);
Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);
Btn _confirm(WidgetTester tester) => tester.widget<Btn>(_inDialog(find.widgetWithText(Btn, 'Destroy app')));

Future<void> _typeName(WidgetTester tester, String text) async {
  await tester.enterText(_inDialog(find.byType(TextField)), text);
  await settle(tester, frames: 2);
}

const _noApps = " !     You haven't deployed any applications yet\n";

void main() {
  group('Destroy dialog', () {
    testAtAllSizes('lists what goes and what stays', (tester, size) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size);
      await _press(tester, find.byTooltip('Destroy app').first);

      expect(_inDialog(find.text('Destroy demo-app')), findsOneWidget);
      expect(_inDialog(find.text('This cannot be undone.')), findsOneWidget);
      expect(_inDialog(find.text('2 containers · image traefik/whoami:v1.10')), findsOneWidget);
      expect(_inDialog(find.text('5 config vars')), findsOneWidget, reason: 'the variables Dokku sets itself are not counted');
      expect(_inDialog(find.text('demo-app.localhost, demo.example.com')), findsOneWidget);
      expect(_inDialog(find.text('unlink cache')), findsOneWidget);
      expect(
        _inDialog(find.textContaining('/var/lib/dokku/data/storage/demo-data', findRichText: true)),
        findsOneWidget,
        reason: 'the storage that is kept is named by its real path',
      );
      expect(_inDialog(find.textContaining('unlinks 1 datastore service', findRichText: true)), findsOneWidget);
      expect(_inDialog(find.text('\$ dokku --force apps:destroy demo-app')), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('says so when there is little to remove', (tester, size) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size);
      await _press(tester, find.byTooltip('Destroy app').last);

      expect(_inDialog(find.text('Destroy worker-app')), findsOneWidget);
      expect(_inDialog(find.text('no containers')), findsOneWidget);
      expect(_inDialog(find.text('no linked services')), findsOneWidget);
      expect(_inDialog(find.textContaining('unlinks', findRichText: true)), findsNothing);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('needs the name typed exactly', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await _press(tester, find.byTooltip('Destroy app').first);
      expect(_confirm(tester).onPressed, isNull);

      await _typeName(tester, 'demo-ap');
      expect(_confirm(tester).onPressed, isNull);
      await _typeName(tester, 'Demo-app');
      expect(_confirm(tester).onPressed, isNull);
      await _typeName(tester, 'demo-app');
      expect(_confirm(tester).onPressed, isNotNull);

      await _press(tester, _inDialog(find.text('Cancel')));
      expect(_dialog, findsNothing);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('destroys the app once confirmed', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await _press(tester, find.byTooltip('Destroy app').first);
      await _typeName(tester, 'demo-app');
      await _press(tester, _inDialog(find.widgetWithText(Btn, 'Destroy app')));

      expect(_dialog, findsNothing);
      expect(ssh.changes, [
        ['--force', 'apps:destroy', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('pressing enter in the name field confirms only a matching name', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await _press(tester, find.byTooltip('Destroy app').first);
      await _typeName(tester, 'demo');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(_dialog, findsOneWidget);
      expect(ssh.changes, isEmpty);

      await _typeName(tester, 'demo-app');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(ssh.changes, [
        ['--force', 'apps:destroy', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('a lookup that fails leaves its line out and does not block the rest', (tester) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), answers: {
        'config:export --format json demo-app': failed(' !     Unable to read config\n'),
      });
      await _press(tester, find.byTooltip('Destroy app').first);
      expect(_inDialog(find.textContaining(RegExp(r'^\d+ config var'))), findsNothing);
      expect(_inDialog(find.text('unlink cache')), findsOneWidget);
      await _typeName(tester, 'demo-app');
      expect(_confirm(tester).onPressed, isNotNull);
      await finish(tester);
    });
  });

  group('Apps', () {
    testWidgets('the list view has a destroy button on every row', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await _press(tester, find.text('List'));
      expect(find.byTooltip('Destroy app'), findsNWidgets(2));

      await _press(tester, find.byTooltip('Destroy app').last);
      expect(_inDialog(find.text('Destroy worker-app')), findsOneWidget, reason: 'the button does not open the app instead');
      await _typeName(tester, 'worker-app');
      await _press(tester, _inDialog(find.widgetWithText(Btn, 'Destroy app')));
      expect(ssh.changes, [
        ['--force', 'apps:destroy', 'worker-app'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('a host without apps says how to get the first one', (tester, size) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size, answers: {
        '--quiet apps:list': failed(_noApps),
        'ps:report': ok(''),
        'domains:report': ok(''),
      });
      expect(find.textContaining('No apps on prod-01 yet.', findRichText: true), findsOneWidget);
      expect(find.textContaining('git push dokku main', findRichText: true), findsOneWidget);
      expect(find.textContaining('No apps match', findRichText: true), findsNothing);
    });

    testAtAllSizes('a filter that matches nothing says so instead', (tester, size) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size);
      await tester.enterText(find.byType(EditableText).first, 'zzz');
      await settle(tester);
      expect(find.textContaining('No apps match “zzz”.', findRichText: true), findsOneWidget);
      expect(find.textContaining('dokku apps:create <name>', findRichText: true), findsOneWidget);
      expect(find.textContaining('yet', findRichText: true), findsNothing);
    });
  });

  group('Destroying from the shell', () {
    testWidgets('leaves the app page for the list once the app is gone', (tester) async {
      final ssh = await pumpScreen(tester, const HomeShell());
      final router = ProviderScope.containerOf(tester.element(find.byType(HomeShell))).read(routerProvider.notifier)
        ..go(const AppDetailRoute('demo-app', AppTab.settings));
      await settle(tester);

      await _press(tester, find.widgetWithText(Btn, 'Destroy app'));
      await _typeName(tester, 'demo-app');
      await _press(tester, _inDialog(find.widgetWithText(Btn, 'Destroy app')));
      expect(ssh.changes, [
        ['--force', 'apps:destroy', 'demo-app'],
      ]);
      expect(router.current, const AppsRoute());
      await finish(tester);
    });
  });
}
