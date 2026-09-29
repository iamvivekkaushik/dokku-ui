import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/jobs.dart';
import 'package:dokku_console/ui/screens/app/build.dart';
import 'package:dokku_console/ui/screens/app/deploys.dart';
import 'package:dokku_console/ui/screens/app/overview.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Tabs sit inside the page's scroll view in the app, so give them one here.
Widget tab(Widget child) => SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child));

Finder inputOf(String label) => find.descendant(of: find.widgetWithText(Field, label), matching: find.byType(EditableText));

Finder inputWithHint(String hint) => find.ancestor(of: find.text(hint), matching: find.byType(TextField));

Finder switchOf(String title) => find.descendant(of: find.widgetWithText(SwitchRow, title), matching: find.byType(AppSwitch));

Finder optionOf(String builder) => find.ancestor(of: find.text(builder), matching: find.byType(GestureDetector)).first;

/// The command shown at the bottom of a card.
Finder footer(String command) => find.descendant(of: find.byType(CmdFooter), matching: find.text(command));

String valueOf(WidgetTester tester, Finder field) => tester.widget<EditableText>(field).controller.text;

Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settle(tester);
}

Future<void> type(WidgetTester tester, Finder field, String text) async {
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await settle(tester, frames: 2);
}

String report(String app, String plugin, Map<String, String> rows) =>
    '=====> $app $plugin information\n${rows.entries.map((e) => '       ${e.key}: ${e.value}\n').join()}';

const nodeBuildpack = 'https://github.com/heroku/heroku-buildpack-nodejs.git';
const nginxBuildpack = 'https://github.com/heroku/heroku-buildpack-nginx.git';

final pinnedBuildpacks = {
  'buildpacks:report demo-app': ok(report('demo-app', 'buildpacks', {
    'Buildpacks computed stack': 'gliderlabs/herokuish:latest-24',
    'Buildpacks list': '$nodeBuildpack,$nginxBuildpack',
  })),
};

Map<String, ExecResult> builderSetTo(String builder, {String buildDir = ''}) => {
      'builder:report demo-app': ok(report('demo-app', 'builder', {
        'Builder build dir': buildDir,
        'Builder computed build dir': buildDir,
        'Builder computed selected': builder,
        'Builder selected': builder,
      })),
    };

const buildHistory = '''
[
  {"id": "b3", "kind": "deploy", "status": "running", "source": "git-push", "started_at": "2026-09-29T12:40:00Z", "duration": "", "display_status": "running"},
  {"id": "b2", "kind": "deploy", "status": "succeeded", "source": "git-sync", "started_at": "2026-09-29T11:05:00Z", "duration": "48s", "display_status": "succeeded"},
  {"id": "b1", "kind": "build", "status": "failed", "source": "docker-image", "started_at": "2026-09-28T09:30:00Z", "duration": "12s", "display_status": "failed"}
]
''';

final dokku038 = {'builds:list demo-app --format json': ok(buildHistory)};

void main() {
  group('Overview', () {
    testAtAllSizes('shows the release, containers and links for the dokku user', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'demo-app')), size: size);
      expect(find.text('CPU'), findsOneWidget);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.text('Connect as a shell user to see container metrics.'), findsNWidgets(2));
      expect(find.text('697df9e97b7a · master'), findsOneWidget);
      expect(find.text('traefik/whoami:v1.10'), findsOneWidget);
      expect(find.text('on-failure:10'), findsOneWidget);
      expect(find.text('docker-image'), findsOneWidget);
      expect(find.text('2 processes'), findsOneWidget);
      expect(find.text('web.1'), findsOneWidget);
      expect(find.text('web.2'), findsOneWidget);
      expect(find.text('32e0eed506d'), findsOneWidget);
      expect(find.text('http://demo-app.localhost'), findsOneWidget);
      expect(find.text('http://demo.example.com'), findsOneWidget);
      expect(find.text('No changes to demo-app made from this console yet.'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('shows container metrics for a shell user', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(OverviewTab(host: rootHost, app: 'demo-app')), size: size, host: rootHost);
      expect(find.text('Connect as a shell user to see container metrics.'), findsNothing);
      expect(find.text('0.0'), findsOneWidget);
      expect(find.text('% of 8 vCPU'), findsOneWidget);
      expect(find.text('last 10s'), findsOneWidget);
      // Two web containers of about 1.36 MiB each.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('limit 16 GiB'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('says so when the app is not deployed', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'worker-app')), size: size);
      expect(find.text('Not deployed yet. Use Deploy app to push code or an image.'), findsOneWidget);
      expect(find.text('0 processes'), findsOneWidget);
      expect(find.text('— · master'), findsOneWidget);
      expect(find.text('never'), findsOneWidget);
      expect(find.text('http://worker-app.localhost'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testWidgets('a shell user without running containers is told there is nothing to measure', (tester) async {
      await pumpScreen(tester, tab(OverviewTab(host: rootHost, app: 'worker-app')), host: rootHost);
      expect(find.text('No running containers.'), findsNWidgets(2));
      await finish(tester);
    });

    testAtAllSizes('lists the changes made to this app only', (tester, size) async {
      await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'demo-app')), size: size);
      final scope = ProviderScope.containerOf(tester.element(find.byType(OverviewTab)));
      final log = scope.read(activityLogProvider);
      await log.add(hostId: dokkuHost.id, command: 'dokku ps:restart worker-app', code: 0, durationMs: 900);
      await log.add(hostId: dokkuHost.id, command: 'dokku config:set demo-app KEY=•••', code: 0, durationMs: 2300);
      await log.add(hostId: dokkuHost.id, command: 'dokku ps:rebuild demo-app', code: 1, durationMs: 41000, stderr: 'failed');
      scope.read(generationProvider(dokkuHost.id).notifier).bump();
      await settle(tester);

      expect(find.text('dokku ps:rebuild demo-app'), findsOneWidget);
      expect(find.text('dokku config:set demo-app KEY=•••'), findsOneWidget);
      expect(find.text('2.3s'), findsOneWidget);
      expect(find.text('dokku ps:restart worker-app'), findsNothing);
      expect(find.text('No changes to demo-app made from this console yet.'), findsNothing);
    });

    testWidgets('opens a link in the browser', (tester) async {
      final opened = <String>[];
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(launcher, (call) async {
        if (call.method == 'launch') opened.add('${(call.arguments as Map)['url']}');
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));

      await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('http://demo.example.com'));
      expect(opened, ['http://demo.example.com']);
      await finish(tester);
    });

    testWidgets('a link that cannot be opened is not an error', (tester) async {
      // Nothing answers the launcher here, as on a device without a browser.
      await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('http://demo.example.com'));
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('says why when the release cannot be read', (tester) async {
      await pumpScreen(tester, tab(OverviewTab(host: dokkuHost, app: 'demo-app')), answers: {
        'git:report demo-app': failed(' !     Permission denied\n'),
      });
      expect(find.textContaining('Could not read the release'), findsOneWidget);
      expect(find.textContaining('Permission denied'), findsOneWidget);
      // The rest of the tab does not depend on it.
      expect(find.text('web.1'), findsOneWidget);
      await finish(tester);
    });
  });

  group('Deploys', () {
    testAtAllSizes('shows git settings and deploys from this console on Dokku 0.35', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), size: size);
      expect(find.text('rev 697df9e · master'), findsOneWidget);
      expect(find.text('dokku@203.0.113.10:demo-app'), findsOneWidget);
      expect(valueOf(tester, inputOf('Deploy branch')), 'master');
      expect(find.text('Deploys are allowed. Lock to reject pushes for a while.'), findsOneWidget);
      expect(find.text('Sync from repository'), findsOneWidget);
      expect(find.text('Deploy an image'), findsOneWidget);
      expect(find.textContaining('needs Dokku 0.38 or newer', findRichText: true), findsOneWidget);
      expect(find.text('No deploys from this console yet.'), findsOneWidget);
      expect(find.text('Cancel running build'), findsNothing);
      expect(footer('\$ dokku git:set demo-app deploy-branch master  ·  apps:lock demo-app  ·  git:unlock demo-app --force'),
          findsOneWidget);
      expect(footer('\$ dokku git:sync --build demo-app <git-url>'), findsOneWidget);
      expect(footer('\$ dokku git:from-image demo-app <image>'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('renders for an app that was never deployed', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'worker-app')), size: size);
      expect(find.text('rev — · master'), findsOneWidget);
      expect(find.text('No deploys from this console yet.'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('lists the build history on Dokku 0.38', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), size: size, answers: dokku038);
      expect(find.text('b3 · deploy'), findsOneWidget);
      expect(find.text('b2 · deploy'), findsOneWidget);
      expect(find.text('b1 · build'), findsOneWidget);
      expect(find.textContaining('git-sync · '), findsOneWidget);
      expect(find.textContaining(' · 48s'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('succeeded'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
      expect(find.text('Output'), findsNWidgets(3));
      expect(find.text('Cancel running build'), findsOneWidget);
      expect(find.textContaining('needs Dokku 0.38', findRichText: true), findsNothing);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('says so when Dokku 0.38 has no builds yet', (tester) async {
      await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')),
          answers: {'builds:list demo-app --format json': ok('[]\n')});
      expect(find.text('No builds recorded for this app yet.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('saves the deploy branch once it differs', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('Save'));
      expect(ssh.changes, isEmpty);

      await type(tester, inputOf('Deploy branch'), 'main');
      expect(footer('\$ dokku git:set demo-app deploy-branch main  ·  apps:lock demo-app  ·  git:unlock demo-app --force'),
          findsOneWidget);
      await tapOn(tester, find.text('Save'));
      expect(ssh.changes, [
        ['git:set', 'demo-app', 'deploy-branch', 'main'],
      ]);
      await finish(tester);
    });

    testWidgets('follows a branch changed elsewhere, but not over what is being typed', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      final scope = ProviderScope.containerOf(tester.element(find.byType(DeploysTab)));
      String gitReport(String branch) => report('demo-app', 'git', {
            'Git deploy branch': branch,
            'Git sha': '697df9e97b7a4ac61b7114b65d33271c4744c931',
          });

      ssh.fixtures['git:report demo-app'] = ok(gitReport('main'));
      scope.read(generationProvider(dokkuHost.id).notifier).bump();
      await settle(tester);
      expect(valueOf(tester, inputOf('Deploy branch')), 'main');
      expect(find.text('rev 697df9e · main'), findsOneWidget);

      await type(tester, inputOf('Deploy branch'), 'release');
      ssh.fixtures['git:report demo-app'] = ok(gitReport('production'));
      scope.read(generationProvider(dokkuHost.id).notifier).bump();
      await settle(tester);
      expect(valueOf(tester, inputOf('Deploy branch')), 'release');
      expect(find.text('rev 697df9e · production'), findsOneWidget);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('says why when the build history cannot be read', (tester) async {
      await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), answers: {
        'builds:list demo-app --format json': failed(' !     Permission denied\n'),
      });
      expect(find.textContaining('Could not read the build history of demo-app'), findsOneWidget);
      expect(find.textContaining('needs Dokku 0.38', findRichText: true), findsNothing);
      await finish(tester);
    });

    testWidgets('keeps the .git directory when switched on', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, switchOf('Keep .git directory'));
      expect(ssh.changes, [
        ['git:set', 'demo-app', 'keep-git-dir', 'true'],
      ]);
      await finish(tester);
    });

    testWidgets('locks deploys', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, switchOf('Deploy lock'));
      expect(ssh.changes, [
        ['apps:lock', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('unlocks deploys for a locked app', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), answers: {
        'apps:report demo-app': ok(report('demo-app', 'app', {'App locked': 'true'})),
      });
      expect(find.text('Deploys are blocked. Pushes are rejected until it is unlocked.'), findsOneWidget);
      expect(footer('\$ dokku git:set demo-app deploy-branch master  ·  apps:unlock demo-app  ·  git:unlock demo-app --force'),
          findsOneWidget);
      await tapOn(tester, switchOf('Deploy lock'));
      expect(ssh.changes, [
        ['apps:unlock', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('clears a stale lock with git:unlock', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('Clear lock'));
      expect(ssh.changes, [
        ['git:unlock', 'demo-app', '--force'],
      ]);
      await finish(tester);
    });

    testWidgets('falls back to apps:unlock when git:unlock does not exist', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), answers: {
        'git:unlock demo-app --force': unknownCommand('git:unlock demo-app --force'),
      });
      await tapOn(tester, find.text('Clear lock'));
      expect(ssh.changes, [
        ['git:unlock', 'demo-app', '--force'],
        ['apps:unlock', 'demo-app'],
      ]);
      // Finding out which command this Dokku has is not a failed change.
      final scope = ProviderScope.containerOf(tester.element(find.byType(DeploysTab)));
      final log = await scope.read(activityLogProvider).load();
      expect([for (final e in log) (e.command, e.ok)], [('dokku apps:unlock demo-app', true)]);
      expect([for (final j in scope.read(jobsProvider)) j.command], ['dokku apps:unlock demo-app']);
      await finish(tester);
    });

    testWidgets('does not fall back when git:unlock fails for another reason', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), answers: {
        'git:unlock demo-app --force': failed(' !     Permission denied\n'),
      });
      await tapOn(tester, find.text('Clear lock'));
      expect(ssh.changes, [
        ['git:unlock', 'demo-app', '--force'],
      ]);
      await finish(tester);
    });

    testWidgets('syncs a repository and builds it', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('Sync & deploy'));
      await type(tester, inputWithHint('https://github.com/acme/api-gateway.git'), 'not a repository');
      await tapOn(tester, find.text('Sync & deploy'));
      expect(ssh.changes, isEmpty);

      await type(tester, inputWithHint('not a repository'), 'https://github.com/acme/api.git');
      await type(tester, inputWithHint('ref (optional)'), 'v1.4.2');
      expect(footer('\$ dokku git:sync --build demo-app https://github.com/acme/api.git v1.4.2'), findsOneWidget);
      await tapOn(tester, find.text('Sync & deploy'));
      expect(ssh.changes, [
        ['git:sync', '--build', 'demo-app', 'https://github.com/acme/api.git', 'v1.4.2'],
      ]);
      await finish(tester);
    });

    testWidgets('syncs without building when the box is cleared', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await type(tester, inputWithHint('https://github.com/acme/api-gateway.git'), 'git@github.com:acme/api.git');
      await tapOn(tester, find.text('Build after sync (--build)'));
      expect(footer('\$ dokku git:sync demo-app git@github.com:acme/api.git'), findsOneWidget);
      await tapOn(tester, find.text('Sync & deploy'));
      expect(ssh.changes, [
        ['git:sync', 'demo-app', 'git@github.com:acme/api.git'],
      ]);
      await finish(tester);
    });

    testWidgets('deploys an image', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('Deploy image'));
      expect(ssh.changes, isEmpty);

      await type(tester, inputWithHint('ghcr.io/acme/api:1.4.2'), 'ghcr.io/acme/api:1.4.3');
      expect(footer('\$ dokku git:from-image demo-app ghcr.io/acme/api:1.4.3'), findsOneWidget);
      await tapOn(tester, find.text('Deploy image'));
      expect(ssh.changes, [
        ['git:from-image', 'demo-app', 'ghcr.io/acme/api:1.4.3'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('a rebuild shows up in the deploys from this console', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), size: size);
      await tapOn(tester, find.text('Trigger rebuild'));
      expect(ssh.changes, [
        ['ps:rebuild', 'demo-app'],
      ]);
      expect(find.text('dokku ps:rebuild demo-app'), findsOneWidget);
      expect(find.text('deployed'), findsOneWidget);
      expect(find.text('No deploys from this console yet.'), findsNothing);
    });

    testWidgets('cancels the running build on Dokku 0.38', (tester) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), answers: dokku038);
      await tapOn(tester, find.text('Cancel running build'));
      expect(ssh.changes, [
        ['builds:cancel', 'demo-app'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('shows the output of a build', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(DeploysTab(host: dokkuHost, app: 'demo-app')), size: size, answers: {
        ...dokku038,
        'builds:output demo-app b2': ok('-----> Building demo-app\n=====> Application deployed\n'),
      });
      await tapOn(tester, find.text('Output').at(1));
      expect(find.text('Build b2'), findsOneWidget);
      expect(find.text('-----> Building demo-app\n=====> Application deployed'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });
  });

  group('Build', () {
    testAtAllSizes('shows the builder, buildpacks and Dockerfile settings', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), size: size);
      for (final name in ['auto', 'herokuish', 'pack', 'dockerfile', 'nixpacks', 'railpack', 'lambda', 'null']) {
        expect(find.descendant(of: optionOf(name), matching: find.byType(RadioDot)), findsOneWidget);
      }
      expect(find.byType(RadioDot), findsNWidgets(8));
      expect(tester.widget<RadioDot>(find.descendant(of: optionOf('auto'), matching: find.byType(RadioDot))).on, isTrue);
      expect(tester.widget<RadioDot>(find.descendant(of: optionOf('pack'), matching: find.byType(RadioDot))).on, isFalse);
      expect(find.text('No buildpacks pinned. The builder detects them from the repository.'), findsOneWidget);
      expect(find.text('In use: Dockerfile'), findsOneWidget);
      expect(find.text('Build environment'), findsOneWidget);
      expect(find.text('gliderlabs/herokuish:latest-24'), findsOneWidget);
      expect(footer('\$ dokku builder:set demo-app selected'), findsOneWidget);
      expect(footer('\$ dokku buildpacks:add demo-app <url>  ·  buildpacks:remove  ·  buildpacks:set'), findsOneWidget);
      expect(footer('\$ dokku builder-dockerfile:set demo-app dockerfile-path'), findsOneWidget);
      expect(footer('\$ dokku builder:set demo-app build-dir  ·  builder:report demo-app'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('lists pinned buildpacks in order', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')),
          size: size, answers: {...builderSetTo('herokuish'), ...pinnedBuildpacks});
      expect(find.text('01'), findsOneWidget);
      expect(find.text('02'), findsOneWidget);
      expect(find.text(nodeBuildpack), findsOneWidget);
      expect(find.text(nginxBuildpack), findsOneWidget);
      // Buildpack builders have no Dockerfile to configure.
      expect(find.text('Dockerfile path'), findsNothing);
      expect(footer('\$ dokku builder:set demo-app selected herokuish'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('hides buildpacks for the dockerfile builder', (tester, size) async {
      final ssh =
          await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), size: size, answers: builderSetTo('dockerfile'));
      expect(find.text('Buildpacks'), findsNothing);
      expect(find.text('Dockerfile path'), findsOneWidget);
      expect(find.text('Build directory'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('shows only the build environment for other builders', (tester, size) async {
      final ssh =
          await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), size: size, answers: builderSetTo('nixpacks'));
      expect(find.text('Buildpacks'), findsNothing);
      expect(find.text('Dockerfile path'), findsNothing);
      expect(find.text('Build directory'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('selects a builder', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), size: size);
      await tapOn(tester, optionOf('pack'));
      expect(ssh.changes, [
        ['builder:set', 'demo-app', 'selected', 'pack'],
      ]);
    });

    testWidgets('selecting auto clears the builder setting', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: builderSetTo('herokuish'));
      await tapOn(tester, optionOf('auto'));
      expect(ssh.changes, [
        ['builder:set', 'demo-app', 'selected'],
      ]);
      await finish(tester);
    });

    testWidgets('selecting the current builder does nothing', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: builderSetTo('herokuish'));
      await tapOn(tester, optionOf('herokuish'));
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('adds a buildpack at a position', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), size: size);
      await tapOn(tester, find.text('Add buildpack'));
      expect(ssh.changes, isEmpty);

      await type(tester, inputWithHint('heroku/nodejs or a repository URL'), 'heroku/nodejs');
      await type(tester, inputWithHint('index'), '2');
      expect(footer('\$ dokku buildpacks:add --index 2 demo-app heroku/nodejs  ·  buildpacks:remove  ·  buildpacks:set'),
          findsOneWidget);
      await tapOn(tester, find.text('Add buildpack'));
      expect(ssh.changes, [
        ['buildpacks:add', '--index', '2', 'demo-app', 'heroku/nodejs'],
      ]);
      // The form is ready for the next one.
      expect(footer('\$ dokku buildpacks:add demo-app <url>  ·  buildpacks:remove  ·  buildpacks:set'), findsOneWidget);
    });

    testWidgets('adds a buildpack at the end when no position is given', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')));
      await type(tester, inputWithHint('heroku/nodejs or a repository URL'), nodeBuildpack);
      await tapOn(tester, find.text('Add buildpack'));
      expect(ssh.changes, [
        ['buildpacks:add', 'demo-app', nodeBuildpack],
      ]);
      await finish(tester);
    });

    testWidgets('moving a buildpack up swaps it with the one above', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: pinnedBuildpacks);
      // The first one cannot move further up.
      await tapOn(tester, find.byTooltip('Move up').first);
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.byTooltip('Move up').last);
      expect(ssh.changes, [
        ['buildpacks:set', '--index', '1', 'demo-app', nginxBuildpack],
        ['buildpacks:set', '--index', '2', 'demo-app', nodeBuildpack],
      ]);
      await finish(tester);
    });

    testWidgets('a failed move stops before the second write', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: {
        ...pinnedBuildpacks,
        'buildpacks:set --index 1 demo-app $nginxBuildpack': failed(' !     Deploy lock is held\n'),
      });
      await tapOn(tester, find.byTooltip('Move up').last);
      expect(ssh.changes, [
        ['buildpacks:set', '--index', '1', 'demo-app', nginxBuildpack],
      ]);
      await finish(tester);
    });

    testWidgets('removing a buildpack asks first', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: pinnedBuildpacks);
      await tapOn(tester, find.byTooltip('Remove').last);
      expect(find.text('Remove this buildpack?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.byTooltip('Remove').last);
      await tapOn(tester, find.text('Remove buildpack'));
      expect(ssh.changes, [
        ['buildpacks:remove', 'demo-app', nginxBuildpack],
      ]);
      await finish(tester);
    });

    testWidgets('clearing buildpacks asks first', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')), answers: pinnedBuildpacks);
      await tapOn(tester, find.text('Clear buildpacks'));
      expect(find.text('Clear all buildpacks?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.text('Clear buildpacks'));
      await tapOn(tester, find.text('Clear buildpacks').last);
      expect(ssh.changes, [
        ['buildpacks:clear', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('there is nothing to clear without pinned buildpacks', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')));
      await tapOn(tester, find.text('Clear buildpacks'));
      expect(find.text('Clear all buildpacks?'), findsNothing);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('saves the Dockerfile path', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')));
      await type(tester, inputOf('Dockerfile path'), 'docker/Dockerfile.prod');
      expect(footer('\$ dokku builder-dockerfile:set demo-app dockerfile-path docker/Dockerfile.prod'), findsOneWidget);
      await tapOn(tester, find.descendant(of: find.widgetWithText(Field, 'Dockerfile path'), matching: find.text('Save')));
      expect(ssh.changes, [
        ['builder-dockerfile:set', 'demo-app', 'dockerfile-path', 'docker/Dockerfile.prod'],
      ]);
      await finish(tester);
    });

    testWidgets('saves the build directory', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')));
      await type(tester, inputOf('Build directory'), 'services/api');
      expect(footer('\$ dokku builder:set demo-app build-dir services/api  ·  builder:report demo-app'), findsOneWidget);
      await tapOn(tester, find.descendant(of: find.widgetWithText(Field, 'Build directory'), matching: find.text('Save')));
      expect(ssh.changes, [
        ['builder:set', 'demo-app', 'build-dir', 'services/api'],
      ]);
      await finish(tester);
    });

    testWidgets('an empty build directory clears the setting', (tester) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'demo-app')),
          answers: builderSetTo('', buildDir: 'services/api'));
      expect(valueOf(tester, inputOf('Build directory')), 'services/api');
      await type(tester, inputOf('Build directory'), '');
      await tapOn(tester, find.descendant(of: find.widgetWithText(Field, 'Build directory'), matching: find.text('Save')));
      expect(ssh.changes, [
        ['builder:set', 'demo-app', 'build-dir'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('renders for an app that was never deployed', (tester, size) async {
      final ssh = await pumpScreen(tester, tab(BuildTab(host: dokkuHost, app: 'worker-app')), size: size);
      expect(find.text('Builder'), findsOneWidget);
      expect(footer('\$ dokku builder:set worker-app selected'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });
  });
}
