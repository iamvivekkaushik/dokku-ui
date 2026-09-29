import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

ProviderContainer _scope(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

RouteStack _router(WidgetTester tester) => _scope(tester).read(routerProvider.notifier);

const _oldKey = 'SHA256:4m2Yc0k0oldoldoldoldoldoldoldoldoldoldoldold';
const _newKey = 'SHA256:kYt4RQ9cw2Jt8kE1hZ0mV3pXqL7nB5dC6fA8sD9gH0c';

final _pinned = dokkuHost.copyWith(hostKey: () => _oldKey, hostKeyType: () => 'ssh-ed25519');

/// A server that was reinstalled: it no longer has the key this app saved.
class _Reinstalled extends FakeSsh {
  _Reinstalled(super.fixtures);

  /// The hosts the connection test was run with.
  final tested = <Host>[];

  @override
  Future<ConnStatus> ping(Host h) async => h.hostKey == _oldKey
      ? const ConnStatus(ConnState.disconnected, error: 'Host key mismatch', hostKeyChanged: true)
      : super.ping(h);

  @override
  Stream<HandshakeStep> test(Host h, HostSecrets secrets) {
    tested.add(h);
    if (h.hostKey != _oldKey) return super.test(h, secrets);
    return Stream.fromIterable(const [
      HandshakeStep(0, StepStatus.ok, 'ssh -p 22 dokku@203.0.113.10'),
      HandshakeStep(1, StepStatus.fail, 'host key changed', detail: 'saved  $_oldKey\nsent   $_newKey', presentedKey: _newKey),
    ]);
  }
}

void main() {
  group('Shell', () {
    // Walks the whole app the way a user would, so a screen that throws or
    // overflows inside the real frame fails here even if its own test passes.
    for (final host in [dokkuHost, rootHost]) {
      testAtAllSizes('opens every screen as ${host.username}', (tester, size) async {
        final ssh = await pumpScreen(tester, const HomeShell(), size: size, host: host);
        final router = _router(tester);

        for (final route in const [AppsRoute(), DatastoresRoute(), MonitoringRoute(), ServerRoute(), InstallRoute()]) {
          router.go(route);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$route');
        }
        for (final app in ['demo-app', 'worker-app']) {
          for (final tab in AppTab.values) {
            router.go(AppDetailRoute(app, tab));
            await settle(tester);
            expect(tester.takeException(), isNull, reason: '$app ${tab.name}');
            expect(find.text(app), findsWidgets);
          }
        }
        expect(ssh.missing, isEmpty);
        expect(ssh.changes, isEmpty);
      });
    }

    testWidgets('says so when an app is not on the host', (tester) async {
      final ssh = await pumpScreen(tester, const HomeShell());
      _router(tester).go(const AppDetailRoute('ghost'));
      await settle(tester);
      expect(find.text('The app "ghost" does not exist on prod-01.'), findsOneWidget);
      expect(ssh.ran.where((c) => c.contains('ghost')), isEmpty, reason: 'nothing is asked about an app that is not there');
      await finish(tester);
    });

    testWidgets('sidebar moves between sections', (tester) async {
      await pumpScreen(tester, const HomeShell());
      final router = _router(tester);

      await tester.tap(find.text('Apps').first);
      await settle(tester);
      expect(router.current, const AppsRoute());

      await tester.tap(find.text('Server & SSH'));
      await settle(tester);
      expect(router.current, const ServerRoute());

      // Shortcuts to an app tab open the first app when none was visited yet.
      await tester.tap(find.text('Environment'));
      await settle(tester);
      expect(router.current, const AppDetailRoute('demo-app', AppTab.env));
      await finish(tester);
    });

    testWidgets('bottom bar moves between sections on a phone', (tester) async {
      await pumpScreen(tester, const HomeShell(), size: phone);
      final router = _router(tester);
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Datastores')));
      await settle(tester);
      expect(router.current, const DatastoresRoute());

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Server')));
      await settle(tester);
      expect(router.current, const ServerRoute());
      await finish(tester);
    });

    testWidgets('back returns to the previous screen', (tester) async {
      await pumpScreen(tester, const HomeShell(), size: phone);
      final router = _router(tester)
        ..section(const AppsRoute())
        ..go(const AppDetailRoute('demo-app'))
        ..go(const AppDetailRoute('demo-app', AppTab.logs));
      await settle(tester);

      // Tabs of one app share a history entry, so one step back leaves the app.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(router.current, const AppsRoute());
      await finish(tester);
    });

    testAtAllSizes('a changed host key can be reviewed and trusted', (tester, size) async {
      final ssh = await pumpScreen(tester, const HomeShell(), size: size, hosts: [_pinned], fake: _Reinstalled.new) as _Reinstalled;
      final scope = _scope(tester);
      scope.read(connStatusProvider.notifier).set(_pinned.id, await ssh.ping(_pinned));
      await settle(tester);
      expect(find.textContaining('Host key changed.'), findsOneWidget);

      await tester.tap(find.text('Review key'));
      await settle(tester);
      expect(find.text('Edit prod-01'), findsOneWidget);
      Btn save() => tester.widget<Btn>(find.widgetWithText(Btn, 'Save changes'));

      await tester.ensureVisible(find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await settle(tester);
      expect(ssh.tested.last.hostKey, _oldKey);
      expect(find.text('host key changed'), findsOneWidget);
      expect(find.textContaining('This is not the key saved for this server.'), findsOneWidget);
      expect(save().onPressed, isNull, reason: 'nothing can be saved over a key that does not match');

      await tester.ensureVisible(find.text('Trust new key'));
      await tester.tap(find.text('Trust new key'));
      await settle(tester);
      expect(ssh.tested.last.hostKey, isNull);
      expect(find.textContaining('This is not the key saved'), findsNothing);
      expect(save().onPressed, isNotNull);

      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await settle(tester);
      expect(find.text('Edit prod-01'), findsNothing);
      final hosts = await scope.read(hostRepositoryProvider).load();
      expect(hosts.single.hostKey, _newKey);
      expect(hosts.single.id, _pinned.id);
    });

    testAtAllSizes('welcomes a fresh install', (tester, size) async {
      final ssh = await pumpScreen(tester, const HomeShell(), size: size, hosts: const []);
      expect(find.text('Connect your first Dokku host'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(ssh.ran, isEmpty);

      await tester.tap(find.text('Install Dokku on a server'));
      await settle(tester);
      expect(_router(tester).current, const InstallRoute());
    });
  });
}
