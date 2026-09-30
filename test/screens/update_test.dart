import 'dart:io';

import 'package:dokku_console/core/updates.dart';
import 'package:dokku_console/core/version.dart';
import 'package:dokku_console/data/self_update.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/shell/update_dialog.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _notes = "### Added\n- A Store of **templates**.\n- Something [linked](https://x).\n\n## What's Changed\n* a commit by @x\n";

AppRelease _release(String version) => AppRelease(
      version: version,
      tag: 'v$version',
      url: 'https://github.com/iamvivekkaushik/dokku-ui/releases/tag/v$version',
      notes: _notes,
      publishedAt: DateTime.utc(2026, 10, 1),
      assets: const {
        'dokku-console-android.apk': 'https://dl/android.apk',
        'dokku-console-linux-x64.tar.gz': 'https://dl/linux.tar.gz',
        'dokku-console-macos.zip': 'https://dl/macos.zip',
        'dokku-console-windows-x64.zip': 'https://dl/windows.zip',
      },
    );

class _FakeUpdater extends SelfUpdater {
  _FakeUpdater({this.inPlace = true, this.fail = false});
  final bool inPlace;
  final bool fail;
  final urls = <String>[];
  var restarted = false;

  @override
  Directory? get bundle => Directory('/opt/dokku-console');
  @override
  bool get canUpdateInPlace => inPlace;
  @override
  Future<void> update(String url, {void Function(double fraction)? onProgress}) async {
    urls.add(url);
    onProgress?.call(.5);
    onProgress?.call(1);
    if (fail) throw StateError('No space left on device');
  }

  @override
  Future<void> restart() async => restarted = true;
}

Future<void> _press(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await settle(tester);
}

void main() {
  group('Updates', () {
    testWidgets('the bell and the sidebar point at a newer release', (tester) async {
      await pumpScreen(tester, const HomeShell(), release: _release('9.9.9'));
      expect(find.text('Update to 9.9.9'), findsOneWidget, reason: 'the sidebar foot');
      await _press(tester, find.byTooltip('Activity · update available'));
      expect(find.text('Update to 9.9.9'), findsNWidgets(2), reason: 'and the activity panel');
      await _press(tester, find.text('Update to 9.9.9').last);
      expect(find.text('9.9.9 is available'), findsOneWidget);
      expect(find.text('You have $appVersion'), findsOneWidget);
      expect(find.text('A Store of templates.'), findsOneWidget, reason: 'markdown marks are gone');
      expect(find.text('Something linked.'), findsOneWidget);
      expect(find.textContaining('a commit by'), findsNothing, reason: "GitHub's commit list is cut");
      expect(find.text('Released 2026-10-01'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('says when this is the latest and offers to check again', (tester) async {
      await pumpScreen(tester, const HomeShell(), release: _release(appVersion));
      expect(find.text('Version $appVersion'), findsOneWidget);
      expect(find.byTooltip('Activity'), findsOneWidget);
      await _press(tester, find.text('Version $appVersion'));
      expect(find.text('Dokku Console $appVersion'), findsOneWidget);
      expect(find.text('This is the latest release.'), findsOneWidget);
      expect(find.widgetWithText(Btn, 'Check again'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('on Linux it replaces the bundle and offers a restart', (tester) async {
      final updater = _FakeUpdater();
      await pumpScreen(tester, const UpdateDialog(), release: _release('9.9.9'), platform: 'linux', updater: updater);
      expect(find.textContaining('Replaces the files in /opt/dokku-console'), findsOneWidget);
      await _press(tester, find.widgetWithText(Btn, 'Update and restart'));
      expect(updater.urls, ['https://dl/linux.tar.gz']);
      expect(find.textContaining('restart to run 9.9.9'), findsOneWidget);
      await _press(tester, find.widgetWithText(Btn, 'Restart now'));
      expect(updater.restarted, isTrue);
      await finish(tester);
    });

    testWidgets('a failed update says why and leaves the release page as the way out', (tester) async {
      await pumpScreen(tester, const UpdateDialog(), release: _release('9.9.9'), platform: 'linux', updater: _FakeUpdater(fail: true));
      await _press(tester, find.widgetWithText(Btn, 'Update and restart'));
      expect(find.textContaining('No space left on device'), findsOneWidget);
      expect(find.widgetWithText(Btn, 'Open release'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('elsewhere it points at the right download', (tester) async {
      const cases = [
        ('android', 'Download APK', 'Downloads the APK'),
        ('macos', 'Download', 'Drag it over'),
        ('windows', 'Download', 'unpack it over the current folder'),
        ('ios', 'Open release', 'no build for this platform'),
        ('linux', 'Download', 'cannot replace itself'),
      ];
      for (final (platform, label, hint) in cases) {
        await pumpScreen(tester, const UpdateDialog(), release: _release('9.9.9'), platform: platform, updater: _FakeUpdater(inPlace: false));
        expect(find.widgetWithText(Btn, label), findsOneWidget, reason: platform);
        expect(find.textContaining(hint), findsOneWidget, reason: platform);
        await finish(tester);
      }
    });
  });
}
