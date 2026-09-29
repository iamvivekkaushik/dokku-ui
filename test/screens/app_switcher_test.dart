import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/shell/app_switcher.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

ProviderContainer _scope(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
RouteStack _router(WidgetTester tester) => _scope(tester).read(routerProvider.notifier);

Finder get _switcher => find.byType(AppSwitcher);
Finder get _menu => find.byType(AppMenu);
Finder _inMenu(Finder f) => find.descendant(of: _menu, matching: f);
Finder _inSwitcher(Finder f) => find.descendant(of: _switcher, matching: f);

Future<void> _press(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await settle(tester);
}

const _narrow = Size(1000, 800);

void main() {
  group('App switcher', () {
    testWidgets('names the first app and its revision until one is opened', (tester) async {
      final ssh = await pumpScreen(tester, const HomeShell());
      expect(_inSwitcher(find.text('demo-app')), findsOneWidget);
      expect(_inSwitcher(find.text('697df9e')), findsOneWidget);

      _router(tester).go(const AppDetailRoute('worker-app'));
      await settle(tester);
      expect(_inSwitcher(find.text('worker-app')), findsOneWidget);
      expect(_inSwitcher(find.text('697df9e')), findsNothing, reason: 'an app that was never deployed has no revision');
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('lists every app with its processes and state', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);

      expect(_menu, findsOneWidget);
      expect(_inMenu(find.text('demo-app')), findsOneWidget);
      expect(_inMenu(find.text('web.1:up web.2:up')), findsOneWidget);
      expect(_inMenu(find.text('running')), findsOneWidget);
      expect(_inMenu(find.text('worker-app')), findsOneWidget);
      expect(_inMenu(find.text('not deployed')), findsOneWidget);
      expect(_inMenu(find.text('undeployed')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('opens below its button and inside the window', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);
      final button = tester.getRect(_switcher), menu = tester.getRect(_menu);
      expect(menu.top, greaterThan(button.bottom));
      expect(menu.left, closeTo(button.left, 1));
      expect(menu.width, 300);
      await finish(tester);
    });

    testWidgets('from the dashboard it opens the overview of the chosen app', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);
      await _press(tester, _inMenu(find.text('worker-app')));
      expect(_menu, findsNothing);
      expect(_router(tester).current, const AppDetailRoute('worker-app'));
      await finish(tester);
    });

    testWidgets('on an app page it keeps the tab', (tester) async {
      await pumpScreen(tester, const HomeShell());
      _router(tester).go(const AppDetailRoute('demo-app', AppTab.env));
      await settle(tester);
      await _press(tester, _switcher);
      await _press(tester, _inMenu(find.text('worker-app')));
      expect(_router(tester).current, const AppDetailRoute('worker-app', AppTab.env));
      await finish(tester);
    });

    testWidgets('elsewhere it stays on the page and the sidebar shortcuts follow', (tester) async {
      await pumpScreen(tester, const HomeShell());
      _router(tester).section(const DatastoresRoute());
      await settle(tester);
      await _press(tester, _switcher);
      await _press(tester, _inMenu(find.text('worker-app')));

      expect(_router(tester).current, const DatastoresRoute());
      expect(_scope(tester).read(prefsProvider).lastApp, 'worker-app');
      expect(_inSwitcher(find.text('worker-app')), findsOneWidget);

      await _press(tester, find.text('Environment'));
      expect(_router(tester).current, const AppDetailRoute('worker-app', AppTab.env));
      await finish(tester);
    });

    testWidgets('filters by name and opens the first match on enter', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);
      await tester.enterText(_inMenu(find.byType(TextField)), 'work');
      await settle(tester);
      expect(_inMenu(find.text('demo-app')), findsNothing);
      expect(_inMenu(find.text('worker-app')), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
      expect(_router(tester).current, const AppDetailRoute('worker-app'));
      await finish(tester);
    });

    testWidgets('says so when nothing matches, and escape closes it', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);
      await tester.enterText(_inMenu(find.byType(TextField)), 'zzz');
      await settle(tester);
      expect(_inMenu(find.text('No apps match.')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(_menu, findsNothing);
      expect(_router(tester).current, const DashboardRoute());
      await finish(tester);
    });

    testWidgets('leads to the list of apps and to creating one', (tester) async {
      final ssh = await pumpScreen(tester, const HomeShell());
      await _press(tester, _switcher);
      await _press(tester, _inMenu(find.text('All apps')));
      expect(_menu, findsNothing);
      expect(_router(tester).current, const AppsRoute());

      await _press(tester, _switcher);
      await _press(tester, _inMenu(find.text('+ Create app')));
      expect(_menu, findsNothing);
      expect(find.byType(AppDialog), findsOneWidget);
      expect(find.text('Lowercase letters, digits and dashes. Becomes the git remote and default subdomain.'), findsOneWidget);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('a host without apps shows that instead of a name', (tester) async {
      await pumpScreen(tester, const HomeShell(), answers: {
        '--quiet apps:list': failed(" !     You haven't deployed any applications yet\n"),
        'ps:report': ok(''),
        'domains:report': ok(''),
      });
      expect(_inSwitcher(find.text('No apps')), findsOneWidget);
      await _press(tester, _switcher);
      expect(_inMenu(find.text('No apps on prod-01 yet.')), findsOneWidget);
      expect(_inMenu(find.text('+ Create app')), findsOneWidget);
      await finish(tester);
    });
  });

  group('Top bar', () {
    testWidgets('a wide window has the address, the search field and labelled buttons', (tester) async {
      await pumpScreen(tester, const HomeShell());
      expect(find.text('203.0.113.10'), findsWidgets);
      expect(find.text('Search apps, services, domains…'), findsOneWidget);
      expect(find.text('SSH terminal'), findsNothing, reason: 'signed in as the dokku user');
      expect(find.text('Dokku console'), findsOneWidget);
      expect(find.text('Deploy app'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a narrow window keeps the switchers and turns the rest into icons', (tester) async {
      await pumpScreen(tester, const HomeShell(), size: _narrow);
      expect(_switcher, findsOneWidget);
      expect(_inSwitcher(find.text('demo-app')), findsOneWidget);
      expect(_inSwitcher(find.text('697df9e')), findsNothing);
      expect(find.text('Search apps, services, domains…'), findsNothing);
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.text('Deploy app'), findsNothing);
      expect(find.byTooltip('Deploy app'), findsOneWidget);

      await _press(tester, find.byTooltip('Search'));
      expect(find.byType(Dialog), findsOneWidget, reason: 'the icon opens the same search');
      await finish(tester);
    });

    // The breakpoint moved from 1100 to 1180 with the app switcher.
    testWidgets('switches layout at 1180', (tester) async {
      await pumpScreen(tester, const HomeShell(), size: const Size(1179, 800));
      expect(find.text('Deploy app'), findsNothing);
      await finish(tester);

      await pumpScreen(tester, const HomeShell(), size: const Size(1180, 800));
      expect(find.text('Deploy app'), findsOneWidget);
      await finish(tester);
    });

    for (final width in [760.0, 820.0, 900.0, 1000.0, 1100.0, 1179.0, 1180.0, 1280.0, 1440.0, 1920.0]) {
      testWidgets('fits a long host and app name at $width', (tester) async {
        const long = 'customer-portal-background-jobs-staging';
        final host = dokkuHost.copyWith(name: 'production-frankfurt-cluster-01');
        final fixtures = loadFixtures();
        await pumpScreen(tester, const HomeShell(), size: Size(width, 800), host: host, answers: {
          '--quiet apps:list': ok('$long\nworker-app\n'),
          'ps:report': ok(fixtures['ps:report']!.stdout.replaceAll('demo-app', long)),
          'domains:report': ok(fixtures['domains:report']!.stdout.replaceAll('demo-app', long)),
          'git:report $long': ok(fixtures['git:report demo-app']!.stdout.replaceAll('demo-app', long)),
        });
        expect(tester.takeException(), isNull);
        expect(_switcher, findsOneWidget);
        final bar = tester.getRect(_switcher);
        expect(bar.width, greaterThanOrEqualTo(90), reason: 'the app name stays readable');

        // With the sidebar collapsed the bar has more room, and must still be laid out well.
        await _press(tester, find.text('Collapse'));
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }

    testAtAllSizes('a phone has the switcher in the breadcrumb of the app page', (tester, size) async {
      await pumpScreen(tester, const HomeShell(), size: size);
      _router(tester).go(const AppDetailRoute('demo-app', AppTab.routing));
      await settle(tester);

      expect(_switcher, findsOneWidget, reason: 'one switcher at every size, in the top bar or the breadcrumb');
      if (size.width >= Bp.compact) return;
      expect(find.text('/'), findsNothing, reason: 'not squeezed into the top bar');

      await _press(tester, _switcher);
      final menu = tester.getRect(_menu);
      expect(menu.left, greaterThanOrEqualTo(8));
      expect(menu.right, lessThanOrEqualTo(size.width - 8));
      await _press(tester, _inMenu(find.text('worker-app')));
      expect(_router(tester).current, const AppDetailRoute('worker-app', AppTab.routing));
    });
  });
}
