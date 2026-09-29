import 'package:dokku_console/ui/screens/apps.dart';
import 'package:dokku_console/ui/screens/dashboard.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  group('Dashboard', () {
    testAtAllSizes('shows Dokku facts for the dokku user', (tester, size) async {
      final ssh = await pumpScreen(tester, DashboardScreen(host: dokkuHost), size: size);
      expect(find.text('prod-01'), findsWidgets);
      expect(find.text('Apps'), findsOneWidget);
      expect(find.text('demo-app.web.1'), findsOneWidget);
      expect(find.text('demo-app.web.2'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('shows host metrics for a shell user', (tester, size) async {
      final ssh = await pumpScreen(tester, DashboardScreen(host: rootHost), size: size, host: rootHost);
      expect(find.text('CPU'), findsWidgets);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('Disk'), findsOneWidget);
      expect(find.text('demo-app.web.1'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });
  });

  group('Apps', () {
    testAtAllSizes('lists apps with their state', (tester, size) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size);
      expect(find.text('demo-app'), findsOneWidget);
      expect(find.text('worker-app'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('undeployed'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('filters by name', (tester) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await tester.enterText(find.byType(EditableText).first, 'worker');
      await settle(tester);
      expect(find.text('demo-app'), findsNothing);
      expect(find.text('worker-app'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('restart runs ps:restart for that app', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await tester.tap(find.text('Restart').first);
      await settle(tester);
      expect(ssh.changes, [['ps:restart', 'demo-app']]);
      await finish(tester);
    });

    testWidgets('stop asks first and does nothing when cancelled', (tester) async {
      final ssh = await pumpScreen(tester, AppsScreen(host: dokkuHost));
      await tester.tap(find.text('Stop').first);
      await settle(tester);
      expect(find.text('Stop demo-app?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });
  });
}
