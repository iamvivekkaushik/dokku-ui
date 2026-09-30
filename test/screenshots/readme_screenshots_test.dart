/// Renders the screenshots shown in the README, from the same captured Dokku
/// output the screen tests use. Skipped unless SCREENSHOTS names the folder to
/// write into; `python3 tool/screenshots.py` runs it and shrinks the files.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

final _out = Platform.environment['SCREENSHOTS'];

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);

/// Images are rendered at twice the logical size, for sharp text on any screen.
const _scale = 2.0;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadBundledFonts();
    final out = _out;
    if (out != null) Directory(out).createSync(recursive: true);
  });

  group('README screenshots', skip: _out == null ? 'set SCREENSHOTS to the output folder' : false, () {
    _shot('dashboard', const DashboardRoute());
    _shot('app-processes', const AppDetailRoute('demo-app', AppTab.processes));
    _shot('app-routing', const AppDetailRoute('demo-app', AppTab.routing));
    _shot('datastores', const DatastoresRoute());
    _shot('server', const ServerRoute());
    _shot('app-switcher', const AppDetailRoute('demo-app'), then: (tester) => tester.tap(find.byTooltip('Switch app')));
    _shot('destroy-app', const AppDetailRoute('demo-app', AppTab.settings),
        then: (tester) => tester.tap(find.widgetWithText(Btn, 'Destroy app')));
    _shot('store', const StoreRoute());
    _shot('store-install', const StoreRoute(), then: (tester) => tester.tap(find.byKey(const ValueKey('install-n8n'))));

    _shot('phone-dashboard', const DashboardRoute(), size: _phone);
    _shot('phone-apps', const AppsRoute(), size: _phone);
    _shot('phone-app-processes', const AppDetailRoute('demo-app', AppTab.processes), size: _phone);
    _shot('phone-app-switcher', const AppDetailRoute('demo-app'), size: _phone, then: (tester) => tester.tap(find.byTooltip('Switch app')));
    _shot('phone-store', const StoreRoute(), size: _phone);
  });
}

/// Opens [route] in the whole app frame, as root on the fixture host, runs
/// [then] if given, and writes `<name>.png`.
void _shot(
  String name,
  AppRoute route, {
  Size size = _desktop,
  List<Host>? hosts,
  Future<void> Function(WidgetTester tester)? then,
}) {
  testWidgets(name, (tester) async {
    // Tests draw without shadows; the pictures should look like the app.
    debugDisableShadows = false;
    try {
      await pumpScreen(tester, const HomeShell(), size: size, host: rootHost, hosts: hosts, answers: {'@metrics': _metrics()});
      if (hosts == null) {
        final scope = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
        // Nothing pings in here, so the host would stay "connecting".
        scope.read(connStatusProvider.notifier).set(rootHost.id, const ConnStatus(ConnState.connected, rttMs: 38));
        scope.read(routerProvider.notifier).go(route);
      }
      await settle(tester, frames: 12);
      if (then != null) {
        await then(tester);
        await settle(tester, frames: 12);
      }
      expect(tester.takeException(), isNull);
      await _write(tester, '$_out/$name.png');
      await finish(tester);
    } finally {
      debugDisableShadows = true;
    }
  });
}

/// The captured metrics, without the container the capture itself ran in.
ExecResult _metrics() {
  final real = loadFixtures()['@metrics']!;
  final lines = real.stdout.split('\n').where((l) => !l.contains('dokku-console-test'));
  return ExecResult(code: 0, stdout: lines.join('\n'), stderr: '', durationMs: 40, command: real.command);
}

Future<void> _write(WidgetTester tester, String path) => tester.runAsync(() async {
      final view = tester.binding.renderViews.single;
      final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & view.size, pixelRatio: _scale);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File(path).writeAsBytesSync(png!.buffer.asUint8List());
    });

/// Every font the app ships, icons included, so nothing renders as a box.
Future<void> _loadBundledFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}
