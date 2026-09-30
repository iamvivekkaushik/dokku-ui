import 'package:dokku_console/ui/screens/apps.dart';
import 'package:dokku_console/ui/screens/dashboard.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The Apps page of a 1280 window: 1000 wide next to the sidebar, so three
/// cards of about 320 fit across.
const _wide = Size(1048, 800);

/// A card's action labels, each shown whole rather than cut with an ellipsis.
void _expectWholeLabels(WidgetTester tester) {
  for (final label in ['Restart', 'Rebuild', 'Stop', 'Start', 'Logs']) {
    for (final p in tester.renderObjectList<RenderParagraph>(find.text(label))) {
      expect(p.didExceedMaxLines, isFalse, reason: '"$label" is cut short');
    }
  }
}

/// Whether the first card has Logs on the same row as Restart, or below it.
bool _oneRow(WidgetTester tester) => tester.getRect(find.text('Logs').first).top == tester.getRect(find.text('Restart').first).top;

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

    testAtAllSizes('shows every action label whole', (tester, size) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), size: size);
      _expectWholeLabels(tester);
      // A phone shows the actions in one row, as it always has.
      if (size == phone) expect(_oneRow(tester), isTrue);
    });

    testWidgets('a few apps widen to share the row, so the actions stay in one row', (tester) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), size: _wide);
      expect(tester.getSize(find.byKey(const ValueKey('demo-app'))).width, closeTo((1000 - 16) / 2, 1));
      expect(_oneRow(tester), isTrue);
      _expectWholeLabels(tester);
      await finish(tester);
    });

    testWidgets('a full row of narrow cards wraps the actions into two rows', (tester) async {
      await pumpScreen(tester, AppsScreen(host: dokkuHost), size: _wide,
          answers: {'--quiet apps:list': ok('demo-app\nworker-app\napi\n')});
      expect(tester.getSize(find.byKey(const ValueKey('demo-app'))).width, closeTo((1000 - 2 * 16) / 3, 1));
      expect(_oneRow(tester), isFalse);
      expect(tester.getRect(find.text('Rebuild').first).top, tester.getRect(find.text('Restart').first).top);
      expect(tester.getRect(find.text('Stop').first).top, tester.getRect(find.text('Logs').first).top);
      _expectWholeLabels(tester);
      expect(tester.takeException(), isNull);
      await finish(tester);
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
