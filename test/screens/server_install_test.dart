import 'dart:async';
import 'dart:convert';

import 'package:dokku_console/core/host_scripts.dart';
import 'package:dokku_console/core/install_script.dart';
import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/jobs.dart';
import 'package:dokku_console/state/queries.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/install.dart';
import 'package:dokku_console/ui/screens/server.dart';
import 'package:dokku_console/ui/screens/stream_run.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// The harness's fake, plus what it does not keep: the input sent to commands
/// and scripts, and control over when a script produces output and ends.
class ScriptSsh extends FakeSsh {
  ScriptSsh(super.fixtures, {this.hold = false, this.refuse, this.preflightError});

  /// Keeps scripts running until the test ends them.
  final bool hold;

  /// Makes opening a script fail with this message.
  final String? refuse;

  /// Makes the install wizard's inspection of the server fail with this message.
  final String? preflightError;
  final scripts = <({String command, String stdin})>[];

  /// Dokku command line to what was written to its input.
  final stdin = <String, String>{};
  void Function(String chunk, bool isStderr)? _emit;

  void emit(String chunk, {bool stderr = false}) => _emit!(chunk, stderr);

  @override
  Future<RemoteStream> stream(Host h, String cmd,
      {Pty? pty, List<int>? stdin, bool shell = false, required void Function(String chunk, bool isStderr) onData}) async {
    if (refuse != null) throw StateError(refuse!);
    scripts.add((command: cmd, stdin: utf8.decode(stdin ?? const [])));
    _emit = onData;
    final s = FakeStream();
    streams.add(s);
    if (!hold) scheduleMicrotask(s.finish);
    return s;
  }

  @override
  Future<RemoteStream> dokkuStream(Host h, List<String> args,
      {Pty? pty, List<int>? stdin, required void Function(String chunk, bool isStderr) onData}) {
    if (stdin != null) this.stdin[args.join(' ')] = utf8.decode(stdin);
    return super.dokkuStream(h, args, pty: pty, stdin: stdin, onData: onData);
  }

  @override
  Future<ExecResult> exec(Host h, String cmd,
      {List<int>? stdin, Duration timeout = const Duration(minutes: 2), String? display}) async {
    if (preflightError != null && cmd == preflightScript) throw ConnectionFailed(preflightError!);
    return super.exec(h, cmd, stdin: stdin, timeout: timeout, display: display);
  }
}

/// The harness's `pumpScreen` with a [ScriptSsh], for a shell user unless [host] says otherwise.
Future<ScriptSsh> pumpWith(
  WidgetTester tester,
  Widget child, {
  Size size = desktop,
  Host? host,
  Map<String, ExecResult> answers = const {},
  bool hold = false,
  String? preflightError,
}) async {
  final ssh = await pumpScreen(
    tester,
    child,
    size: size,
    host: host ?? rootHost,
    answers: answers,
    fake: (fixtures) => ScriptSsh(fixtures, hold: hold, preflightError: preflightError),
  );
  return ssh as ScriptSsh;
}

/// A server that has never had Dokku on it.
final freshServer = {
  '@preflight': ok('@@os\nubuntu|24.04|noble|Ubuntu 24.04 LTS\n@@arch\nx86_64\n@@user\nroot\n0\nsudo-ok\n'
      '@@nginx\nnone\n@@keys\n1\n@@dokku\nnone\n@@ip\n203.0.113.10\n@@mem\nMemTotal: 4000000 kB\n@@end\n'),
};

ExecResult systemWith({String installer = 'absent', String registries = ''}) => ok(
    '@@os\nUbuntu 24.04.2 LTS\n@@kernel\n6.8.0\n@@arch\nx86_64\n@@hostname\nprod\n@@docker\n29.8.1\n'
    '@@uptime\n6943.86 48273.21\n@@installer\n$installer\n@@registries\n$registries\n@@end\n');

Future<void> press(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settle(tester);
}

Finder button(String label) => find.widgetWithText(Btn, label);
Finder inputWithHint(String hint) => find.descendant(
    of: find.byWidgetPredicate((w) => w is AppInput && w.hint == hint), matching: find.byType(EditableText));
Finder dialogFields() => find.descendant(of: find.byType(AppDialog), matching: find.byType(EditableText));

ProviderContainer containerOf(WidgetTester tester, Type screen) =>
    ProviderScope.containerOf(tester.element(find.byType(screen)));

void main() {
  group('Server', () {
    testAtAllSizes('shows keys, facts and plugins for the dokku user', (tester, size) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: dokkuHost), size: size);
      expect(find.text('Server & SSH settings'), findsOneWidget);
      expect(find.textContaining('Connected as the dokku user.', findRichText: true), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
      expect(find.text('test_rsa'), findsOneWidget);
      expect(find.textContaining('SHA256:TrHJW+MN2hDGaITNT5f4nNKgWsEPA2FIAhpPTpvkp+k · ssh-ed25519'), findsOneWidget);
      expect(find.text('upgrade available · v0.38.31'), findsOneWidget);
      expect(find.text('1 installed · 44 core'), findsOneWidget);
      expect(find.text('dokku@203.0.113.10:22'), findsOneWidget);
      expect(find.text('redis'), findsOneWidget);
      expect(find.text('apps'), findsNothing);
      expect(find.text('Show 44 core plugins'), findsOneWidget);
      expect(find.text('Web installer service'), findsNothing);
      expect(find.textContaining('cannot be listed as the dokku user'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('shows host facts for a shell user', (tester, size) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), size: size, host: rootHost);
      expect(find.textContaining('Connected as the dokku user.', findRichText: true), findsNothing);
      expect(find.text('Ubuntu 24.04.2 LTS · x86_64'), findsOneWidget);
      expect(find.text('29.8.1'), findsOneWidget);
      expect(find.text('Web installer service'), findsOneWidget);
      expect(find.text('not present'), findsOneWidget);
      expect(find.textContaining('Not logged in to any registry'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('shows every plugin and both dialogs without overflow', (tester, size) async {
      await pumpScreen(tester, ServerScreen(host: rootHost), size: size, host: rootHost);
      await press(tester, find.text('Show 44 core plugins'));
      expect(find.text('Hide 44 core plugins'), findsOneWidget);
      expect(find.text('scheduler-docker-local'), findsOneWidget);

      await press(tester, button('Add key'));
      expect(find.text('Add SSH key'), findsOneWidget);
      await press(tester, button('Cancel'));
      await press(tester, button('Log in'));
      expect(find.text('Log in to a registry'), findsOneWidget);
      await press(tester, button('Cancel'));
      await press(tester, button('Review upgrade'));
      expect(find.text('Upgrade Dokku'), findsOneWidget);
    });

    testWidgets('disables what needs root for the dokku user and says why', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: dokkuHost));
      for (final label in ['Add key', 'Revoke', 'Review upgrade', 'Update all', 'Update', 'Disable', 'Uninstall', 'Install plugin']) {
        final b = tester.widget<Btn>(button(label).first);
        expect(b.onPressed, isNull, reason: label);
        expect(b.tooltip, 'Needs root. Connect as root or a sudo user.', reason: label);
      }
      expect(find.byTooltip('Needs root. Connect as root or a sudo user.'), findsWidgets);
      await press(tester, button('Add key'));
      expect(find.byType(AppDialog), findsNothing);
      // Logging in to a registry and the global domain do not need root.
      expect(tester.widget<Btn>(button('Log in')).onPressed, isNotNull);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('the notice opens the connection editor', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost));
      await press(tester, button('Edit connection').first);
      expect(find.text('Edit prod-01'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('adds a key, sending the public key on stdin', (tester) async {
      final ssh = await pumpWith(tester, ServerScreen(host: rootHost));
      await press(tester, button('Add key'));
      await tester.enterText(dialogFields().at(0), 'alice laptop');
      await tester.enterText(dialogFields().at(1), 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 alice@laptop');
      await settle(tester);
      expect(find.textContaining(r'$ dokku ssh-keys:add alice-laptop < key.pub'), findsOneWidget);
      await press(tester, button('Add key').last);
      expect(ssh.changes, [['ssh-keys:add', 'alice-laptop']]);
      expect(ssh.stdin['ssh-keys:add alice-laptop'], 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 alice@laptop\n');
      expect(find.byType(AppDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('rejects anything that is not a public key', (tester) async {
      final ssh = await pumpWith(tester, ServerScreen(host: rootHost));
      await press(tester, button('Add key'));
      expect(find.textContaining('Never paste a private key here.'), findsOneWidget);
      await tester.enterText(dialogFields().at(0), 'alice');

      for (final bad in [
        '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----',
        'hello world',
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 one\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5 two',
      ]) {
        await tester.enterText(dialogFields().at(1), bad);
        await settle(tester);
        expect(find.textContaining('Never paste a private key here.'), findsOneWidget, reason: bad);
        expect(tester.widget<Btn>(button('Add key').last).onPressed, isNull, reason: bad);
      }
      expect(find.textContaining('This is a private key.'), findsNothing);
      await tester.enterText(dialogFields().at(1), '-----BEGIN OPENSSH PRIVATE KEY-----');
      await settle(tester);
      expect(find.textContaining('This is a private key.'), findsOneWidget);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('revoking a key warns about locking yourself out and can be cancelled', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost);
      await press(tester, button('Revoke').first);
      expect(find.text('Revoke test?'), findsOneWidget);
      expect(find.textContaining('you will be locked out too'), findsOneWidget);
      await press(tester, button('Cancel'));
      expect(ssh.changes, isEmpty);

      await press(tester, button('Revoke').first);
      await press(tester, button('Revoke key'));
      expect(ssh.changes, [['ssh-keys:remove', 'test']]);
      await finish(tester);
    });

    testWidgets('an empty key list is not an error', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: dokkuHost),
          answers: {'ssh-keys:list --format json': failed(' !     authorized_keys is empty for dokku\n')});
      expect(find.textContaining('No deploy keys registered.'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('a failed key listing says what went wrong', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost),
          answers: {'ssh-keys:list --format json': failed(' !     Invalid flag passed, valid flags: none\n')});
      expect(find.textContaining('Could not list the SSH keys'), findsOneWidget);
      expect(find.textContaining('No deploy keys registered.'), findsNothing);
      await finish(tester);
    });

    testWidgets('saves the global domains', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: dokkuHost));
      final field = inputWithHint('apps.example.com');
      expect(tester.widget<EditableText>(field).controller.text, 'dokku.test');
      expect(tester.widget<Btn>(button('Save')).onPressed, isNull);
      expect(find.text(r'$ dokku domains:set-global dokku.test'), findsOneWidget);

      await tester.enterText(field, 'apps.example.com  example.org');
      await settle(tester);
      expect(find.text(r'$ dokku domains:set-global apps.example.com example.org'), findsOneWidget);
      await press(tester, button('Save'));
      expect(ssh.changes, [['domains:set-global', 'apps.example.com', 'example.org']]);
      await finish(tester);
    });

    testWidgets('does not save a global domain that could not be one', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: dokkuHost));
      await tester.enterText(inputWithHint('apps.example.com'), 'apps.example.com; reboot');
      await settle(tester);
      expect(tester.widget<Btn>(button('Save')).onPressed, isNull);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('shows global facts from the reports', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost), answers: {
        'config:export --global --format json': ok('{"CURL_TIMEOUT":"120","DOKKU_RM_CONTAINER":"1"}\n'),
        'registry:report': ok('=====> demo-app registry information\n       Registry global server:              ghcr.io\n'),
      });
      expect(find.text('enabled'), findsOneWidget);
      expect(find.text('master'), findsOneWidget);
      expect(find.text('ghcr.io'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('updates, disables and uninstalls a plugin', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost);
      await press(tester, button('Update'));
      await press(tester, button('Disable'));
      expect(ssh.changes, [
        ['plugin:update', 'redis'],
        ['plugin:disable', 'redis'],
      ]);

      await press(tester, button('Uninstall'));
      expect(find.text('Uninstall redis?'), findsOneWidget);
      expect(tester.widget<Btn>(button('Uninstall').last).onPressed, isNull);
      await press(tester, button('Cancel'));
      expect(ssh.changes, hasLength(2));

      await press(tester, button('Uninstall'));
      await tester.enterText(dialogFields().first, 'redis');
      await settle(tester);
      await press(tester, button('Uninstall').last);
      expect(ssh.changes.last, ['plugin:uninstall', 'redis']);
      await finish(tester);
    });

    testWidgets('offers to enable a disabled plugin', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost, answers: {
        'plugin:list': ok('  apps                 0.35.20 enabled    dokku core apps plugin\n'
            '  redis                2.1.0 disabled    dokku redis service plugin\n'),
      });
      expect(find.text('2.1.0 · disabled'), findsOneWidget);
      expect(find.text('Show 1 core plugin'), findsOneWidget);
      await press(tester, button('Enable'));
      expect(ssh.changes, [['plugin:enable', 'redis']]);
      await finish(tester);
    });

    testWidgets('update all asks first', (tester) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost);
      await press(tester, button('Update all'));
      expect(find.text('Update all plugins?'), findsOneWidget);
      await press(tester, button('Cancel'));
      expect(ssh.changes, isEmpty);
      await press(tester, button('Update all'));
      await press(tester, button('Update all').last);
      expect(ssh.changes, [['plugin:update']]);
      await finish(tester);
    });

    testWidgets('installs a plugin from an https URL after a warning', (tester) async {
      const url = 'https://github.com/dokku/dokku-letsencrypt.git';
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost);
      final field = inputWithHint(url);

      await tester.enterText(field, 'git@github.com:dokku/dokku-letsencrypt.git');
      await settle(tester);
      expect(tester.widget<Btn>(button('Install plugin')).onPressed, isNull);

      await tester.enterText(field, url);
      await settle(tester);
      expect(find.textContaining('\$ dokku plugin:install $url'), findsOneWidget);
      await press(tester, button('Install plugin'));
      expect(find.text('Install letsencrypt?'), findsOneWidget);
      expect(find.textContaining('Plugins run as root on the server.'), findsOneWidget);
      await press(tester, button('Cancel'));
      expect(ssh.changes, isEmpty);

      await press(tester, button('Install plugin'));
      await press(tester, button('Install plugin').last);
      expect(ssh.changes, [['plugin:install', url]]);
      expect(tester.widget<EditableText>(field).controller.text, isEmpty);
      await finish(tester);
    });

    testWidgets('says so when there are no third-party plugins', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost),
          answers: {'plugin:list': ok('  apps                 0.35.20 enabled    dokku core apps plugin\n')});
      expect(find.textContaining('No third-party plugins.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('logs in to a registry with the password on stdin only', (tester) async {
      const password = 'hunter2-token';
      final ssh = await pumpWith(tester, ServerScreen(host: dokkuHost), host: dokkuHost);
      await press(tester, button('Log in'));
      expect(tester.widget<EditableText>(dialogFields().at(0)).controller.text, 'ghcr.io');
      expect(tester.widget<Btn>(button('Log in').last).onPressed, isNull);

      await tester.enterText(dialogFields().at(1), 'alice');
      await tester.enterText(dialogFields().at(2), password);
      await settle(tester);
      expect(tester.widget<EditableText>(dialogFields().at(2)).obscureText, isTrue);
      expect(find.textContaining(r'$ dokku registry:login --password-stdin ghcr.io alice'), findsOneWidget);
      for (final c in tester.widgetList<CodeBlock>(find.byType(CodeBlock))) {
        expect(c.text, isNot(contains(password)));
      }
      for (final c in tester.widgetList<CmdFooter>(find.byType(CmdFooter))) {
        expect(c.command, isNot(contains(password)));
      }

      final jobs = containerOf(tester, ServerScreen).listen(jobsProvider, (_, _) {});
      await press(tester, button('Log in').last);
      expect(ssh.changes, [['registry:login', '--password-stdin', 'ghcr.io', 'alice']]);
      expect(ssh.stdin['registry:login --password-stdin ghcr.io alice'], password);
      expect(ssh.ran.expand((c) => c).join(' '), isNot(contains(password)));
      expect(jobs.read().single.command, 'dokku registry:login --password-stdin ghcr.io alice');
      expect(find.byType(AppDialog), findsNothing);
      expect(find.textContaining(password), findsNothing);
      jobs.close();
      await finish(tester);
    });

    testAtAllSizes('lists the registries a shell user is logged in to, and logs out after asking', (tester, size) async {
      final ssh = await pumpScreen(tester, ServerScreen(host: rootHost),
          size: size, host: rootHost, answers: {'@system': systemWith(registries: 'ghcr.io\nregistry.example.com')});
      expect(find.text('ghcr.io'), findsOneWidget);
      expect(find.text('registry.example.com'), findsOneWidget);
      expect(find.text('authenticated'), findsNWidgets(2));

      await press(tester, button('Log out').first);
      expect(find.text('Log out of ghcr.io?'), findsOneWidget);
      await press(tester, button('Cancel'));
      expect(ssh.changes, isEmpty);
      await press(tester, button('Log out').first);
      await press(tester, button('Log out').last);
      expect(ssh.changes, [['registry:logout', 'ghcr.io']]);
    });

    testWidgets('warns while the web installer is still enabled', (tester) async {
      await pumpScreen(tester, ServerScreen(host: rootHost),
          host: rootHost, answers: {'@system': systemWith(installer: 'enabled')});
      final dot = tester.widget<Dot>(find.widgetWithText(Dot, 'enabled'));
      expect(dot.tone, Tone.warn);
      await finish(tester);
    });

    testWidgets('says up to date on the latest release, and offers no upgrade', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost), answers: {'version': ok('dokku version 0.38.31\n')});
      expect(find.text('up to date'), findsOneWidget);
      expect(find.textContaining('upgrade available'), findsNothing);
      expect(find.text('Dokku 0.38.31 is the latest release'), findsOneWidget);
      expect(find.textContaining('Upgrade Dokku on'), findsNothing);
      expect(button('Review upgrade'), findsNothing);
      await finish(tester);
    });

    testWidgets('without an answer from GitHub it claims nothing and keeps the upgrade at hand', (tester) async {
      await pumpScreen(tester, ServerScreen(host: rootHost), host: rootHost, latestDokku: null);
      expect(find.text('up to date'), findsNothing);
      expect(find.textContaining('upgrade available'), findsNothing);
      expect(find.textContaining('could not reach GitHub to compare'), findsOneWidget);
      expect(button('Review upgrade'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('opens the install wizard', (tester) async {
      await pumpScreen(tester, ServerScreen(host: dokkuHost));
      await press(tester, button('Open installer'));
      expect(containerOf(tester, ServerScreen).read(routeProvider), const InstallRoute());
      await finish(tester);
    });

    testAtAllSizes('reviews, runs and finishes an upgrade', (tester, size) async {
      final ssh = await pumpWith(tester, ServerScreen(host: rootHost), hold: true, size: size);
      await press(tester, button('Review upgrade'));
      expect(find.text('0.35.20 → 0.38.31 on prod-01'), findsOneWidget);
      expect(find.textContaining('Read the release notes first.', findRichText: true), findsOneWidget);
      expect(find.textContaining('sudo -n apt-get -qq -y install --only-upgrade dokku'), findsOneWidget);
      expect(find.textContaining('sudo -n dokku plugin:install-dependencies --core'), findsOneWidget);
      expect(ssh.scripts, isEmpty);

      await press(tester, button('Run upgrade'));
      expect(ssh.scripts, [(command: 'bash -s', stdin: '$sudoShim$upgradeScript')]);
      expect(find.text('upgrading…'), findsOneWidget);
      // Nothing closes the dialog while the upgrade runs, not even tapping outside it.
      expect(button('Close'), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
      await tester.tapAt(const Offset(4, 4));
      await settle(tester);
      expect(find.text('upgrading…'), findsOneWidget);

      ssh.emit('-----> Upgrading dokku package\n=====> Now running dokku version 0.38.31\n');
      await settle(tester);
      expect(find.text('-----> Upgrading dokku package'), findsOneWidget);
      expect(find.text('=====> Now running dokku version 0.38.31'), findsOneWidget);

      ssh.streams.last.finish(0);
      await settle(tester);
      expect(find.text('upgrade complete'), findsOneWidget);
      expect(button('Run upgrade'), findsNothing);
      await press(tester, button('Close'));
      expect(find.byType(AppDialog), findsNothing);

      // The next review starts from the explanation, not from the old output.
      await press(tester, button('Review upgrade'));
      expect(find.textContaining('Read the release notes first.', findRichText: true), findsOneWidget);
      expect(ssh.scripts, hasLength(1));
    });

    testWidgets('a cancelled upgrade can be retried', (tester) async {
      final ssh = await pumpWith(tester, ServerScreen(host: rootHost), hold: true);
      await press(tester, button('Review upgrade'));
      await press(tester, button('Run upgrade'));
      await press(tester, button('Cancel upgrade'));
      expect(ssh.streams.last.killed, isTrue);
      expect(find.text('upgrade failed, see the output above'), findsOneWidget);
      expect(find.textContaining('Cancelled before it finished.'), findsOneWidget);

      await press(tester, button('Retry upgrade'));
      expect(ssh.scripts, hasLength(2));
      ssh.streams.last.finish(0);
      await settle(tester);
      expect(find.text('upgrade complete'), findsOneWidget);
      await finish(tester);
    });
  });

  group('Install wizard', () {
    Future<void> toStep(WidgetTester tester, int step) async {
      for (var i = 0; i < step; i++) {
        await press(tester, button('Continue'));
      }
    }

    /// The script as shown, which leaves out the newline that ends the file.
    String script(WidgetTester tester) {
      final shown = find.descendant(of: find.byType(Panel), matching: find.byType(SelectableText)).last;
      return '${tester.widget<SelectableText>(shown).textSpan!.toPlainText()}\n';
    }

    testAtAllSizes('asks for a server when there is none', (tester, size) async {
      final ssh = await pumpScreen(tester, const InstallScreen(host: null), size: size);
      expect(find.text('Connect to the server first'), findsOneWidget);
      expect(find.textContaining('root or a user with passwordless sudo'), findsOneWidget);
      await press(tester, button('Connect a server'));
      expect(find.text('Connect a Dokku host'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.ran, isEmpty);
    });

    testAtAllSizes('explains that the dokku user cannot install', (tester, size) async {
      final ssh = await pumpScreen(tester, InstallScreen(host: dokkuHost), size: size);
      expect(find.text('prod-01 is connected as the dokku user'), findsOneWidget);
      expect(find.text('Requirements check'), findsNothing);
      await press(tester, button('Edit prod-01'));
      expect(find.text('Edit prod-01'), findsWidgets);
      expect(find.byType(AppDialog), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.ran, isEmpty);
    });

    testAtAllSizes('walks through every step', (tester, size) async {
      final ssh = await pumpScreen(tester, InstallScreen(host: rootHost), size: size, host: rootHost);
      expect(find.text('Requirements check'), findsOneWidget);
      expect(find.text('Generated script'), findsOneWidget);
      // The captured server already runs Dokku, which is worth a warning, not a stop.
      expect(find.textContaining('dokku 0.35.20 is already installed'), findsOneWidget);
      expect(find.text('16265148 kB'), findsNothing);
      expect(find.text('15884 MiB'), findsOneWidget);
      expect(tester.widget<Btn>(button('Back')).onPressed, isNull);

      await toStep(tester, 1);
      expect(find.text('Install method'), findsOneWidget);
      expect(find.text('latest stable'), findsOneWidget);
      await press(tester, find.text('Unattended apt package'));
      expect(find.text('SSH key file'), findsOneWidget);
      expect(find.text('Version'), findsNothing);
      await press(tester, find.text('From source (make install)'));
      expect(find.text('Source repository'), findsOneWidget);
      await press(tester, find.text('bootstrap.sh (recommended)'));
      await press(tester, find.text('Git branch (source)'));
      expect(find.text('DOKKU_BRANCH'), findsOneWidget);

      await toStep(tester, 1);
      expect(find.text('Admin SSH key'), findsOneWidget);
      expect(find.text('~/.ssh/authorized_keys of root'), findsOneWidget);
      expect(find.text('203.0.113.10.sslip.io'), findsOneWidget);
      await press(tester, find.text('Paste public key'));
      await press(tester, find.text('Domain you control'));
      await press(tester, find.byWidgetPredicate((w) => w is AppSwitch && w.label == 'Create first app'));
      expect(find.text('First app name'), findsOneWidget);

      await toStep(tester, 1);
      expect(find.text('Installer output'), findsOneWidget);
      expect(find.text('idle'), findsOneWidget);
      expect(button('Continue'), findsNothing);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
      expect(ssh.streams, isEmpty);
    });

    testWidgets('passes every check on a fresh server', (tester) async {
      await pumpScreen(tester, InstallScreen(host: rootHost), host: rootHost, answers: freshServer);
      expect(find.text('dokku: command not found · fresh install'), findsOneWidget);
      expect(find.text('none'), findsOneWidget);
      expect(find.text('ubuntu 24.04'), findsOneWidget);
      expect(find.byIcon(LucideIcons.triangleAlert), findsNothing);
      await toStep(tester, 3);
      expect(tester.widget<Btn>(button('Run installer')).onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('re-runs the checks', (tester) async {
      final ssh = await pumpScreen(tester, InstallScreen(host: rootHost), host: rootHost);
      expect(find.text('0.35.20'), findsOneWidget);
      ssh.fixtures.addAll(freshServer);
      await press(tester, button('Re-run checks'));
      expect(find.text('0.35.20'), findsNothing);
      expect(find.text('dokku: command not found · fresh install'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the script follows the options as they change', (tester) async {
      await pumpScreen(tester, InstallScreen(host: rootHost), host: rootHost, answers: freshServer);
      expect(script(tester), installScriptText(const InstallOptions(dokkuTag: 'v0.38.31', serverIp: '203.0.113.10')));

      await toStep(tester, 1);
      await press(tester, find.byWidgetPredicate((w) => w is AppSwitch && w.label == 'Skip recommended packages'));
      expect(script(tester), contains('DOKKU_NO_INSTALL_RECOMMENDS=true'));
      await tester.enterText(inputWithHint('203.0.113.10.sslip.io'), 'paas.example.com');
      await settle(tester);
      expect(script(tester), contains("'dokku dokku/hostname string paas.example.com'"));

      await press(tester, find.text('Unattended apt package'));
      expect(script(tester), contains('apt-get -qq -y --no-install-recommends install dokku'));
      expect(script(tester), isNot(contains('bootstrap.sh')));

      await toStep(tester, 1);
      await press(tester, find.text('Server IP'));
      expect(script(tester), contains('sudo dokku domains:set-global 203.0.113.10\n'));
      await press(tester, find.text('Domain you control'));
      await tester.enterText(inputWithHint('apps.example.com'), 'Apps.Example.com');
      await settle(tester);
      expect(script(tester), contains('sudo dokku domains:set-global apps.example.com\n'));
      await press(tester, find.byWidgetPredicate((w) => w is AppSwitch && w.label == 'Install letsencrypt plugin'));
      expect(script(tester), isNot(contains('dokku-letsencrypt')));
      await finish(tester);
    });

    testWidgets('uses the latest release unless the tag was already changed', (tester) async {
      final latest = Completer<String?>();
      await pumpScreen(
        tester,
        ProviderScope(
          overrides: [latestDokkuProvider.overrideWith((ref) => latest.future)],
          child: InstallScreen(host: rootHost),
        ),
        host: rootHost,
        answers: freshServer,
      );
      expect(script(tester), contains('DOKKU_TAG=v0.35.20'));
      await toStep(tester, 1);
      final tag = find.descendant(of: find.widgetWithText(Field, 'DOKKU_TAG'), matching: find.byType(EditableText));
      await tester.enterText(tag, 'v0.36.4');
      await settle(tester);

      latest.complete('v0.38.31');
      await settle(tester);
      expect(tester.widget<EditableText>(tag).controller.text, 'v0.36.4');
      expect(script(tester), contains('DOKKU_TAG=v0.36.4'));
      expect(find.text('latest stable'), findsNothing);
      await finish(tester);
    });

    testWidgets('uses the address the server reports when it was added by name', (tester) async {
      final named = Host(id: 'h-named', name: 'paas', host: 'paas.example.com', username: 'root', createdAt: DateTime(2026));
      await pumpScreen(tester, InstallScreen(host: named), host: named, answers: freshServer);
      expect(script(tester), contains('sudo dokku domains:set-global paas.example.com\n'));
      await toStep(tester, 2);
      expect(find.text('203.0.113.10.sslip.io'), findsOneWidget);
      await press(tester, find.text('sslip.io'));
      expect(script(tester), contains('sudo dokku domains:set-global 203.0.113.10.sslip.io\n'));
      await finish(tester);
    });

    testWidgets('asks for the address when it cannot be worked out', (tester) async {
      final named = Host(id: 'h-named', name: 'paas', host: 'paas.example.com', username: 'root', createdAt: DateTime(2026));
      await pumpScreen(tester, InstallScreen(host: named), host: named, answers: {
        '@preflight': ok('@@os\nubuntu|24.04|noble|Ubuntu 24.04 LTS\n@@arch\nx86_64\n@@user\nroot\n0\nsudo-ok\n'
            '@@nginx\nnone\n@@keys\n1\n@@dokku\nnone\n@@ip\n@@mem\nMemTotal: 4000000 kB\n@@end\n'),
      });
      await toStep(tester, 2);
      expect(inputWithHint('Public IP of the server'), findsNothing);
      await press(tester, find.text('sslip.io'));
      final field = inputWithHint('Public IP of the server');
      await tester.enterText(field, '198.51.100.7');
      await settle(tester);
      // The field stays while it is being typed in.
      expect(field, findsOneWidget);
      expect(script(tester), contains('sudo dokku domains:set-global 198.51.100.7.sslip.io\n'));

      await tester.enterText(field, '');
      await settle(tester);
      await toStep(tester, 1);
      expect(find.textContaining('server IP unknown', findRichText: true), findsOneWidget);
      expect(tester.widget<Btn>(button('Run installer')).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('does not run while a requirement fails, and says which', (tester) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), answers: {
        '@preflight': ok('@@os\nubuntu|24.04|noble|Ubuntu 24.04 LTS\n@@arch\nriscv64\n@@user\ndeploy\n1000\nsudo-no\n'
            '@@nginx\nnone\n@@keys\n1\n@@dokku\nnone\n@@ip\n203.0.113.10\n@@mem\nMemTotal: 4000000 kB\n@@end\n'),
      });
      expect(find.text('no sudo'), findsOneWidget);
      await toStep(tester, 3);
      expect(find.textContaining('Requirements not met.', findRichText: true), findsOneWidget);
      expect(find.textContaining('Architecture, Sudo access. See step 01.', findRichText: true), findsOneWidget);
      expect(tester.widget<Btn>(button('Run installer')).onPressed, isNull);
      await press(tester, button('Run installer'));
      expect(find.byType(AppDialog), findsNothing);
      expect(ssh.scripts, isEmpty);
      await finish(tester);
    });

    testWidgets('does not run with invalid options, and says which', (tester) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), answers: freshServer);
      await toStep(tester, 2);
      await press(tester, find.text('Paste public key'));
      await tester.enterText(inputWithHint('ssh-ed25519 AAAA… user@host'), '-----BEGIN OPENSSH PRIVATE KEY-----');
      await settle(tester);
      expect(find.textContaining('Never paste a private key here.'), findsOneWidget);

      await toStep(tester, 1);
      expect(find.textContaining('Fix these before running:', findRichText: true), findsOneWidget);
      expect(find.textContaining('public key must be a single OpenSSH public key line', findRichText: true), findsOneWidget);
      expect(tester.widget<Btn>(button('Run installer')).onPressed, isNull);
      expect(ssh.scripts, isEmpty);
      await finish(tester);
    });

    testWidgets('does not run before the requirements are known', (tester) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), preflightError: 'Could not reach 203.0.113.10:22');
      expect(find.textContaining('Could not inspect 203.0.113.10: Could not reach 203.0.113.10:22'), findsOneWidget);
      expect(find.text('Operating system'), findsNothing);
      await toStep(tester, 3);
      expect(find.textContaining('Requirements not checked yet.', findRichText: true), findsOneWidget);
      expect(tester.widget<Btn>(button('Run installer')).onPressed, isNull);
      expect(ssh.scripts, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('asks, then runs the generated script and follows its progress', (tester, size) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), answers: freshServer, hold: true, size: size);
      await toStep(tester, 3);
      expect(find.textContaining('Press Run installer', findRichText: true), findsOneWidget);

      await press(tester, button('Run installer'));
      expect(find.text('Install Dokku on prod-01?'), findsOneWidget);
      await press(tester, button('Cancel'));
      expect(ssh.scripts, isEmpty);
      expect(find.text('idle'), findsOneWidget);

      await press(tester, button('Run installer'));
      await press(tester, button('Run installer').last);
      final expected = installScriptText(const InstallOptions(dokkuTag: 'v0.38.31', serverIp: '203.0.113.10'));
      expect(ssh.scripts, [(command: 'bash -s', stdin: '$sudoShim$expected')]);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('Starting…', findRichText: true), findsOneWidget);
      expect(tester.widget<Btn>(button('Back')).onPressed, isNull);
      expect(tester.widget<Btn>(button('Installing…')).loading, isTrue);

      ssh.emit('Setting up docker-ce (5:29.8.1) ...\nSetting up dokku (0.38.31) ...\n');
      await settle(tester);
      expect(find.text('Setting up dokku (0.38.31) ...'), findsOneWidget);
      final container = containerOf(tester, InstallScreen);
      expect(installPhase(container.read(streamRunProvider('install:h-root')).lines), 2);

      ssh.emit('=====> Dokku 0.38.31 installed.\n');
      ssh.streams.last.finish(0);
      await settle(tester);
      expect(find.text('complete'), findsOneWidget);
      expect(button('Run installer'), findsNothing);

      await press(tester, button('Open dashboard'));
      expect(container.read(routeProvider), const DashboardRoute());
      expect(container.read(streamRunProvider('install:h-root')).status, RunStatus.idle);
    });

    testWidgets('a failed install can be run again', (tester) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), answers: freshServer, hold: true);
      await toStep(tester, 3);
      await press(tester, button('Run installer'));
      await press(tester, button('Run installer').last);
      ssh.emit('E: Unable to locate package dokku\n');
      ssh.streams.last.finish(100);
      await settle(tester);
      expect(find.text('failed'), findsOneWidget);
      expect(find.text('E: Unable to locate package dokku'), findsOneWidget);
      expect(tester.widget<Btn>(button('Run again')).onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('cancel stops the run', (tester) async {
      final ssh = await pumpWith(tester, InstallScreen(host: rootHost), answers: freshServer, hold: true);
      await toStep(tester, 3);
      await press(tester, button('Run installer'));
      await press(tester, button('Run installer').last);
      await press(tester, button('Cancel install'));
      expect(ssh.streams.last.killed, isTrue);
      expect(find.text('failed'), findsOneWidget);
      expect(find.textContaining('Cancelled before it finished.'), findsOneWidget);
      expect(tester.widget<Btn>(button('Run again')).onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('leaving and coming back shows the same run', (tester) async {
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      final ssh = await pumpWith(
        tester,
        ValueListenableBuilder(
          valueListenable: shown,
          builder: (_, on, _) => on ? InstallScreen(host: rootHost) : const Text('another screen'),
        ),
        answers: freshServer,
        hold: true,
      );
      await toStep(tester, 3);
      await press(tester, button('Run installer'));
      await press(tester, button('Run installer').last);
      ssh.emit('-----> before leaving\n');
      await settle(tester);

      shown.value = false;
      await settle(tester);
      expect(find.text('Installer output'), findsNothing);
      expect(ssh.streams.single.killed, isFalse);
      ssh.emit('-----> while away\n');

      shown.value = true;
      await settle(tester);
      expect(find.text('Installer output'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
      expect(find.text('-----> before leaving'), findsOneWidget);
      expect(find.text('-----> while away'), findsOneWidget);
      expect(ssh.scripts, hasLength(1));
      await finish(tester);
    });

    testWidgets('copies the script', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpScreen(tester, InstallScreen(host: rootHost), host: rootHost, answers: freshServer);
      await toStep(tester, 1);
      await press(tester, find.text('From source (make install)'));
      await toStep(tester, 2);
      await press(tester, button('Copy script'));
      expect(
        copied,
        installScriptText(
            const InstallOptions(method: InstallMethod.source, dokkuTag: 'v0.38.31', serverIp: '203.0.113.10')),
      );
      expect(find.text('Copied'), findsOneWidget);
      await finish(tester);
    });
  });

  group('installRequirements', () {
    Map<String, Tone> tones(Map<String, String> facts) => {for (final r in installRequirements(facts)) r.label: r.tone};

    test('warns about what is unusual and fails what cannot work', () {
      final t = tones({
        'os': 'fedora|41||Fedora Linux 41',
        'arch': 'armv7l',
        'user': 'deploy\n1000\nsudo-no',
        'nginx': '2',
        'keys': '0\n0',
        'dokku': 'none',
        'mem': 'MemTotal:         512000 kB',
      });
      expect(t, {
        'Operating system': Tone.warn,
        'Architecture': Tone.bad,
        'Sudo access': Tone.bad,
        'Memory': Tone.warn,
        'Fresh machine': Tone.warn,
        'SSH keypair for deploys': Tone.warn,
        'Existing Dokku': Tone.ok,
      });
    });

    test('accepts supported systems and passwordless sudo', () {
      for (final os in ['ubuntu|22.04|jammy|Ubuntu 22.04.5 LTS', 'debian|12|bookworm|Debian GNU/Linux 12', 'debian|11|bullseye|Debian 11']) {
        final reqs = installRequirements({'os': os, 'arch': 'aarch64', 'user': 'deploy\n1000\nsudo-ok', 'nginx': '0', 'keys': '2'});
        expect(reqs[0].tone, Tone.ok, reason: os);
        expect(reqs[1].tone, Tone.ok);
        expect(reqs[2].state, 'sudo');
        expect(reqs[4].state, 'clean');
        expect(reqs[5].state, '2 keys');
      }
      expect(installRequirements({'os': 'ubuntu|20.04|focal|Ubuntu 20.04'})[0].tone, Tone.warn);
      expect(installRequirements({'os': 'debian|10|buster|Debian 10'})[0].tone, Tone.warn);
    });

    test('an unreadable server fails the checks that matter', () {
      final t = tones(const {});
      expect(t['Architecture'], Tone.bad);
      expect(t['Sudo access'], Tone.bad);
    });
  });

  test('installPhase follows the installer output', () {
    expect(installPhase(const []), 0);
    expect(installPhase(const ['Reading package lists...']), 0);
    expect(installPhase(const ['Setting up docker-ce ...']), 1);
    expect(installPhase(const ['Get docker', 'Unpacking dokku (0.38.31) ...']), 2);
    expect(installPhase(const ['Unpacking dokku (0.38.31) ...', 'SHA256:abc', 'docker again']), 3);
    expect(installPhase(const ['=====> Set global domains']), 3);
    expect(installPhase(const ['sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git']), 3);
  });

  group('StreamRun', () {
    (ProviderContainer, StreamRun, RunState Function()) setUpRun(ScriptSsh ssh) {
      final container = ProviderContainer(overrides: [sshServiceProvider.overrideWithValue(ssh)]);
      addTearDown(container.dispose);
      final provider = streamRunProvider('test:h-root');
      return (container, container.read(provider.notifier), () => container.read(provider));
    }

    test('sends the script to bash and splits the output into lines', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (container, run, state) = setUpRun(ssh);
      expect(state().status, RunStatus.idle);

      final before = container.read(generationProvider('h-root'));
      final done = run.start(rootHost, 'echo hello\n');
      await pumpEventQueue();
      expect(state().status, RunStatus.running);
      expect(ssh.scripts, [(command: 'bash -s', stdin: 'echo hello\n')]);

      ssh.emit('\x1b[1m-----> one\x1b[0m\r\ntw');
      expect(state().lines, ['-----> one']);
      ssh.emit('o\n\nthree');
      expect(state().lines, ['-----> one', 'two', '']);

      ssh.streams.single.finish(0);
      await done;
      expect(state().status, RunStatus.done);
      expect(state().exitCode, 0);
      expect(state().lines, ['-----> one', 'two', '', 'three']);
      // Cached lookups for that host are refetched.
      expect(container.read(generationProvider('h-root')), before + 1);
    });

    test('keeps half a line of output apart from errors that arrive meanwhile', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (_, run, state) = setUpRun(ssh);
      final done = run.start(rootHost, 'true\n');
      await pumpEventQueue();
      ssh.emit('Unpacking dokku ');
      ssh.emit('W: a warning\nE: half an ', stderr: true);
      expect(state().lines, ['W: a warning']);
      ssh.emit('(0.38.31) ...\n');
      expect(state().lines, ['W: a warning', 'Unpacking dokku (0.38.31) ...']);
      ssh.emit('no newline');
      ssh.streams.single.finish(1);
      await done;
      expect(state().lines, ['W: a warning', 'Unpacking dokku (0.38.31) ...', 'no newline', 'E: half an ']);
    });

    test('a non-zero exit fails the run', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (_, run, state) = setUpRun(ssh);
      final done = run.start(rootHost, 'false\n');
      await pumpEventQueue();
      ssh.streams.single.finish(2);
      await done;
      expect(state().status, RunStatus.failed);
      expect(state().exitCode, 2);
    });

    test('runs one script at a time', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (_, run, state) = setUpRun(ssh);
      final done = run.start(rootHost, 'first\n');
      await pumpEventQueue();
      await run.start(rootHost, 'second\n');
      run.reset();
      expect(state().status, RunStatus.running);
      expect(ssh.scripts, hasLength(1));
      ssh.streams.single.finish(0);
      await done;
    });

    test('kill stops the script and reset forgets it', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (_, run, state) = setUpRun(ssh);
      final done = run.start(rootHost, 'sleep 100\n');
      await pumpEventQueue();
      ssh.emit('-----> working\n');
      run.kill();
      await done;
      expect(ssh.streams.single.killed, isTrue);
      expect(state().status, RunStatus.failed);
      expect(state().lines, ['-----> working', ' !     Cancelled before it finished. Steps that already ran are not undone.']);

      run.reset();
      expect(state().status, RunStatus.idle);
      expect(state().lines, isEmpty);
      expect(state().exitCode, isNull);
    });

    test('kill before the channel opened still stops the script', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (_, run, state) = setUpRun(ssh);
      final done = run.start(rootHost, 'sleep 100\n');
      run.kill();
      await done;
      expect(ssh.streams.single.killed, isTrue);
      expect(state().status, RunStatus.failed);
    });

    test('a connection failure is reported in the output', () async {
      final ssh = ScriptSsh({}, refuse: 'Could not reach 203.0.113.10:22');
      final (_, run, state) = setUpRun(ssh);
      await run.start(rootHost, 'true\n');
      expect(state().status, RunStatus.failed);
      expect(state().lines, [' !     Could not reach 203.0.113.10:22']);
    });

    test('refuses to run as the dokku user', () async {
      final ssh = ScriptSsh({});
      final (_, run, state) = setUpRun(ssh);
      await run.start(dokkuHost, 'true\n');
      expect(state().status, RunStatus.failed);
      expect(state().lines.single, contains('needs root'));
      expect(ssh.scripts, isEmpty);
    });

    test('keeps runs apart by id', () async {
      final ssh = ScriptSsh({}, hold: true);
      final (container, run, _) = setUpRun(ssh);
      final done = run.start(rootHost, 'true\n');
      await pumpEventQueue();
      expect(container.read(streamRunProvider('other:h-root')).status, RunStatus.idle);
      ssh.streams.single.finish(0);
      await done;
    });
  });

  group('StreamOutput', () {
    test('colours lines by what they say', () {
      expect(lineColor('=====> Dokku installed'), Tone.ok.color);
      expect(lineColor(' !     Something broke'), Tone.bad.color);
      expect(lineColor('E: install failed'), Tone.bad.color);
      expect(lineColor('WARNING: apt does not have a stable CLI'), Tone.warn.color);
      expect(lineColor('-----> Note: this is a note'), Tone.warn.color);
      expect(lineColor('-----> Installing'), C.soft);
      expect(lineColor('Reading package lists...'), C.muted);
    });

    testAtAllSizes('shows the idle text, then the lines', (tester, size) async {
      final lines = ValueNotifier(const <String>[]);
      addTearDown(lines.dispose);
      await pumpScreen(
        tester,
        SizedBox(
          height: 240,
          child: ValueListenableBuilder(
            valueListenable: lines,
            builder: (_, l, _) => StreamOutput(lines: l, idle: const TextSpan(text: 'Nothing has run yet.')),
          ),
        ),
        size: size,
      );
      expect(find.text('Nothing has run yet.', findRichText: true), findsOneWidget);

      lines.value = ['=====> done', '', 'a' * 400];
      await settle(tester);
      expect(find.text('Nothing has run yet.', findRichText: true), findsNothing);
      expect(tester.widget<Text>(find.text('=====> done')).style!.color, Tone.ok.color);
    });

    testWidgets('follows new output until the user scrolls up', (tester) async {
      final lines = ValueNotifier([for (var i = 0; i < 300; i++) 'line $i']);
      addTearDown(lines.dispose);
      await pumpScreen(
        tester,
        SizedBox(
          height: 300,
          child: ValueListenableBuilder(valueListenable: lines, builder: (_, l, _) => StreamOutput(lines: l)),
        ),
      );
      final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, position.maxScrollExtent);
      expect(find.text('line 299'), findsOneWidget);

      lines.value = [...lines.value, 'line 300'];
      await settle(tester);
      expect(position.pixels, position.maxScrollExtent);
      expect(find.text('line 300'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await settle(tester);
      final readingAt = position.pixels;
      expect(readingAt, lessThan(position.maxScrollExtent));
      lines.value = [...lines.value, 'line 301'];
      await settle(tester);
      expect(position.pixels, readingAt);
      expect(find.text('line 301'), findsNothing);

      // Back at the bottom it follows again.
      position.jumpTo(position.maxScrollExtent);
      await settle(tester);
      lines.value = [...lines.value, 'line 302'];
      await settle(tester);
      expect(find.text('line 302'), findsOneWidget);
      await finish(tester);
    });
  });
}
