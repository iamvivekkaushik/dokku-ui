import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/state/jobs.dart';
import 'package:dokku_console/state/queries.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/app/routing.dart';
import 'package:dokku_console/ui/screens/app/settings.dart';
import 'package:dokku_console/ui/screens/app/storage.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Tabs are laid out inside the page's scroll view, so give them one here.
Widget inPage(Widget tab) => SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: tab));

Widget routing([String app = 'demo-app']) => inPage(RoutingTab(host: dokkuHost, app: app));
Widget storage([String app = 'demo-app']) => inPage(StorageTab(host: dokkuHost, app: app));
Widget settings([String app = 'demo-app']) => inPage(SettingsTab(host: dokkuHost, app: app));

Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await settle(tester);
}

Future<void> type(WidgetTester tester, Finder field, String text) async {
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, text);
  await settle(tester);
}

/// A text field, found by its placeholder.
Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

/// Text that is on show, leaving out the placeholders of empty fields.
Finder shown(String text) => find.byElementPredicate(
      (e) => e.widget is Text && (e.widget as Text).data == text && e.findAncestorWidgetOfExactType<TextField>() == null,
      description: 'text "$text" outside a text field',
    );

Finder within(Finder card, Finder what) => find.descendant(of: card, matching: what);

/// The card with this heading.
Finder card(String title) => find.ancestor(of: find.text(title), matching: find.byType(Panel));

Future<void> choose(WidgetTester tester, Finder select, String option) async {
  await tapOn(tester, select);
  await tester.tap(find.text(option).last);
  await settle(tester);
}

AppRoute routeOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold))).read(routeProvider);

String report(String app, String plugin, Map<String, String> rows) =>
    '=====> $app $plugin information\n${rows.entries.map((e) => '       ${e.key}: ${e.value}\n').join()}';

final certificate = {
  'certs:report demo-app': ok(report('demo-app', 'ssl', {
    'Ssl dir': '/home/dokku/demo-app/tls',
    'Ssl enabled': 'true',
    'Ssl hostnames': '*.example.com',
    'Ssl expires at': 'Dec  9 06:24:00 2036 GMT',
    'Ssl issuer': 'CN = Example CA',
    'Ssl starts at': 'Sep 10 06:24:01 2026 GMT',
    'Ssl subject': 'CN = *.example.com',
    'Ssl verified': 'self signed',
  })),
};

Map<String, ExecResult> letsencrypt({required bool active, String email = 'ops@example.com'}) => {
      'letsencrypt:report demo-app': ok(report('demo-app', 'letsencrypt', {
        'Letsencrypt active': '$active',
        'Letsencrypt autorenew': 'true',
        'Letsencrypt computed email': email,
        'Letsencrypt global email': email,
        'Letsencrypt email': '',
        'Letsencrypt expiration': active ? '1796797440' : '',
      })),
      'letsencrypt:list': ok('-----> App name           Certificate Expiry        Time before expiry        Time before renewal\n'
          '${active ? '       demo-app           2026-12-09 06:24:00       69d, 23h, 59m, 12s        39d, 23h, 59m, 12s\n' : ''}'),
    };

void main() {
  group('Routing', () {
    testAtAllSizes('shows domains, ports, certificate and proxy', (tester, size) async {
      final ssh = await pumpScreen(tester, routing(), size: size);
      expect(find.text('demo-app.localhost'), findsOneWidget);
      expect(find.text('demo.example.com'), findsOneWidget);
      expect(find.text('DNS ok'), findsNWidgets(2));
      expect(find.text('no cert'), findsNWidgets(2));
      expect(find.textContaining('demo-app.dokku.test', findRichText: true), findsOneWidget);
      // Nothing is mapped on this app, so the detected mapping is shown and labelled as such.
      expect(within(card('Ports'), shown('80')), findsNWidgets(2));
      expect(within(card('Ports'), find.byTooltip('Remove mapping')), findsNothing,
          reason: 'Dokku ignores ports:remove for a mapping that was only detected');
      expect(find.textContaining('detected, not set'), findsOneWidget);
      expect(find.text('no certificate'), findsOneWidget);
      expect(find.textContaining('letsencrypt plugin is not installed'), findsOneWidget);
      expect(find.text('Enable'), findsNothing);
      expect(find.text('HSTS'), findsOneWidget);
      expect(find.text('max-age 15724800'), findsOneWidget);
      expect(find.textContaining('(using the global default)'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('shows the state of an installed certificate and of Let\'s Encrypt', (tester, size) async {
      final ssh = await pumpScreen(tester, routing(), size: size, answers: {...certificate, ...letsencrypt(active: true)});
      expect(find.textContaining('valid · '), findsOneWidget);
      expect(find.text('CN = Example CA'), findsOneWidget);
      expect(find.textContaining('Dec  9 06:24:00 2036 GMT · in '), findsOneWidget);
      // The wildcard covers demo.example.com but not demo-app.localhost.
      expect(find.text('TLS'), findsOneWidget);
      expect(find.text('no cert'), findsOneWidget);
      expect(find.text('Renew now'), findsOneWidget);
      expect(find.textContaining('letsencrypt plugin is not installed'), findsNothing);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('renders for an app that was never deployed', (tester, size) async {
      final ssh = await pumpScreen(tester, routing('worker-app'), size: size);
      expect(find.text('worker-app.localhost'), findsOneWidget);
      expect(within(card('Ports'), shown('5000')), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('an app without domains says so', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {
        'domains:report demo-app': ok(report('demo-app', 'domains', {
          'Domains app enabled': 'true',
          'Domains app vhosts': '',
          'Domains global enabled': 'true',
          'Domains global vhosts': 'dokku.test',
        })),
        'ports:report demo-app': ok(report('demo-app', 'ports', {'Ports map': '', 'Ports map detected': ''})),
      });
      expect(find.textContaining('No domains yet.'), findsOneWidget);
      expect(find.textContaining('No port mappings yet.'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('adding a domain runs domains:add and shows the command first', (tester) async {
      final ssh = await pumpScreen(tester, routing());
      expect(find.text('Add domain'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Add domain')).onPressed, isNull);
      await type(tester, field('app.example.com'), 'API.example.com');
      expect(find.textContaining('\$ dokku domains:add demo-app api.example.com'), findsOneWidget);
      await tapOn(tester, find.text('Add domain'));
      expect(ssh.changes, [
        ['domains:add', 'demo-app', 'api.example.com']
      ]);
      await finish(tester);
    });

    testWidgets('tapping a domain opens it, over HTTPS when the certificate covers it', (tester) async {
      final opened = <String>[];
      final ssh = await pumpScreen(
        tester,
        ProviderScope(
          overrides: [openUrlProvider.overrideWithValue((url) async => opened.add('$url'))],
          child: routing(),
        ),
        answers: certificate,
      );
      await tapOn(tester, find.text('demo-app.localhost'));
      await tapOn(tester, find.text('demo.example.com'));
      expect(opened, ['http://demo-app.localhost', 'https://demo.example.com']);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('says when a domain does not point at this host', (tester, size) async {
      await pumpScreen(
        tester,
        ProviderScope(
          overrides: [
            dnsProvider.overrideWith((ref, q) async => const {
                  'demo-app.localhost': DnsCheck('demo-app.localhost', [], null),
                  'demo.example.com': DnsCheck('demo.example.com', ['198.51.100.7'], false),
                }),
          ],
          child: routing(),
        ),
        size: size,
      );
      expect(find.text('No DNS record'), findsOneWidget);
      expect(find.text('Resolves to 198.51.100.7, not this host'), findsOneWidget);
      expect(find.text('DNS ok'), findsNothing);
    });

    testWidgets('removing a domain asks first', (tester) async {
      final ssh = await pumpScreen(tester, routing());
      await tapOn(tester, find.byTooltip('Remove domain').last);
      expect(find.text('Remove demo.example.com?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.byTooltip('Remove domain').last);
      await tapOn(tester, find.widgetWithText(Btn, 'Remove domain'));
      expect(ssh.changes, [
        ['domains:remove', 'demo-app', 'demo.example.com']
      ]);
      await finish(tester);
    });

    testAtAllSizes('mapping a port runs ports:add with the chosen scheme', (tester, size) async {
      final ssh = await pumpScreen(tester, routing(), size: size);
      final ports = card('Ports');
      await choose(tester, within(ports, find.byType(AppSelect<String>)), 'https');
      await type(tester, within(ports, field('80')), '443');
      await type(tester, within(ports, field('5000')), '8443');
      expect(find.textContaining('\$ dokku ports:add demo-app https:443:8443'), findsOneWidget);
      await tapOn(tester, find.text('Map port'));
      expect(ssh.changes, [
        ['ports:add', 'demo-app', 'https:443:8443']
      ]);
    });

    testWidgets('removing a port mapping runs ports:remove', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {
        'ports:report demo-app':
            ok(report('demo-app', 'ports', {'Ports map': 'http:80:5000 https:443:5000', 'Ports map detected': 'http:80:80'})),
      });
      expect(find.textContaining('detected, not set'), findsNothing);
      await tapOn(tester, find.byTooltip('Remove mapping').last);
      expect(ssh.changes, [
        ['ports:remove', 'demo-app', 'https:443:5000']
      ]);
      await finish(tester);
    });

    testWidgets('enabling Let\'s Encrypt saves a changed email first, then schedules renewal', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: letsencrypt(active: false));
      expect(tester.widget<TextField>(field('ops@example.com')).controller!.text, 'ops@example.com');
      await type(tester, field('ops@example.com'), 'tls@example.com');
      expect(find.textContaining('\$ dokku letsencrypt:set demo-app email tls@example.com'), findsOneWidget);
      await tapOn(tester, find.text('Enable'));
      expect(ssh.changes, [
        ['letsencrypt:set', 'demo-app', 'email', 'tls@example.com'],
        ['letsencrypt:enable', 'demo-app'],
        ['letsencrypt:cron-job', '--add'],
      ]);
      await finish(tester);
    });

    testWidgets('enabling Let\'s Encrypt leaves an unchanged email alone', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: letsencrypt(active: false));
      await tapOn(tester, find.text('Enable'));
      expect(ssh.changes, [
        ['letsencrypt:enable', 'demo-app'],
        ['letsencrypt:cron-job', '--add'],
      ]);
      await finish(tester);
    });

    testWidgets('Let\'s Encrypt cannot be enabled without an email address', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: letsencrypt(active: false, email: ''));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Enable')).onPressed, isNull);
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'Let\'s Encrypt'), find.byType(AppSwitch)));
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('disabling Let\'s Encrypt asks first', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {...certificate, ...letsencrypt(active: true)});
      final toggle = within(find.widgetWithText(SwitchRow, 'Let\'s Encrypt'), find.byType(AppSwitch));
      await tapOn(tester, toggle);
      expect(find.text('Disable Let\'s Encrypt?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, toggle);
      await tapOn(tester, find.text('Disable'));
      expect(ssh.changes, [
        ['letsencrypt:disable', 'demo-app']
      ]);
      await finish(tester);
    });

    testWidgets('an active Let\'s Encrypt certificate can be renewed and scheduled', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {...certificate, ...letsencrypt(active: true)});
      expect(find.text('Enable'), findsNothing);
      expect(find.textContaining('\$ dokku letsencrypt:auto-renew demo-app'), findsOneWidget);
      await tapOn(tester, find.text('Renew now'));
      await tapOn(tester, find.text('Schedule auto-renew'));
      expect(ssh.changes, [
        ['letsencrypt:auto-renew', 'demo-app'],
        ['letsencrypt:cron-job', '--add'],
      ]);
      await finish(tester);
    });

    testAtAllSizes('uploading a certificate runs certs:add and never repeats the key', (tester, size) async {
      final ssh = await pumpScreen(tester, routing(), size: size);
      await tapOn(tester, find.text('Upload'));
      expect(find.text('Upload certificate'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install certificate')).onPressed, isNull);

      const secret = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASC';
      await type(tester, field('-----BEGIN CERTIFICATE-----'), '-----BEGIN CERTIFICATE-----\nMIIDdzCCAl8\n-----END CERTIFICATE-----');
      await type(tester, field('-----BEGIN PRIVATE KEY-----'), '-----BEGIN PRIVATE KEY-----\n$secret\n-----END PRIVATE KEY-----');
      expect(find.textContaining(secret), findsOneWidget);

      await tapOn(tester, find.text('Install certificate'));
      expect(ssh.changes, [
        ['certs:add', 'demo-app']
      ]);
      expect(find.text('Upload certificate'), findsNothing);
      expect(find.textContaining(secret, findRichText: true), findsNothing);
      // Nor is it kept with the job, which is what the job dock and the activity log show.
      final jobs = ProviderScope.containerOf(tester.element(find.byType(Scaffold))).read(jobsProvider);
      expect(jobs, hasLength(1));
      expect('${jobs.single.command} ${jobs.single.args} ${jobs.single.text}', isNot(contains(secret)));
    });

    testWidgets('a file that cannot be read is reported in the upload dialog', (tester) async {
      // No file picker exists in the test environment, so choosing a file fails.
      final ssh = await pumpScreen(tester, routing());
      await tapOn(tester, find.text('Upload'));
      await tapOn(tester, find.text('Choose file').first);
      expect(find.text('That file could not be read.'), findsOneWidget);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('removing the certificate asks first, and is unavailable without one', (tester) async {
      var ssh = await pumpScreen(tester, routing());
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Remove')).onPressed, isNull);
      await finish(tester);

      ssh = await pumpScreen(tester, routing(), answers: certificate);
      await tapOn(tester, find.text('Remove'));
      expect(find.text('Remove certificate?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.text('Remove'));
      await tapOn(tester, find.text('Remove certificate'));
      expect(ssh.changes, [
        ['certs:remove', 'demo-app']
      ]);
      await finish(tester);
    });

    testWidgets('disabling the proxy asks first', (tester) async {
      final ssh = await pumpScreen(tester, routing());
      final toggle = within(find.widgetWithText(PanelHead, 'Reverse proxy'), find.byType(AppSwitch));
      await tapOn(tester, toggle);
      expect(find.text('Disable the proxy?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, toggle);
      await tapOn(tester, find.text('Disable proxy'));
      expect(ssh.changes, [
        ['proxy:disable', 'demo-app']
      ]);
      await finish(tester);
    });

    testWidgets('enabling the proxy does not need a confirmation', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {
        'proxy:report demo-app': ok(report('demo-app', 'proxy', {
          'Proxy computed type': 'nginx',
          'Proxy enabled': 'false',
          'Proxy global type': 'nginx',
          'Proxy type': '',
        })),
      });
      await tapOn(tester, within(find.widgetWithText(PanelHead, 'Reverse proxy'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['proxy:enable', 'demo-app']
      ]);
      await finish(tester);
    });

    testAtAllSizes('switching the proxy engine asks first', (tester, size) async {
      final ssh = await pumpScreen(tester, routing(), size: size);
      await tapOn(tester, find.text('caddy'));
      expect(find.text('Switch proxy to caddy?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.text('caddy'));
      await tapOn(tester, find.text('Switch proxy'));
      expect(ssh.changes, [
        ['proxy:set', 'demo-app', 'caddy']
      ]);
    });

    testWidgets('another proxy engine hides the nginx settings', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {
        'proxy:report demo-app': ok(report('demo-app', 'proxy', {
          'Proxy computed type': 'caddy',
          'Proxy enabled': 'true',
          'Proxy global type': 'nginx',
          'Proxy type': 'caddy',
        })),
      });
      expect(find.text('HSTS'), findsNothing);
      expect(find.textContaining('\$ dokku proxy:set demo-app caddy'), findsOneWidget);
      expect(ssh.ran.where((c) => c.first == 'nginx:report'), isEmpty);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testWidgets('changing HSTS rebuilds the nginx config', (tester) async {
      final ssh = await pumpScreen(tester, routing());
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'HSTS'), find.byType(AppSwitch)));
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'HSTS preload'), find.byType(AppSwitch)));
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'HSTS include subdomains'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['nginx:set', 'demo-app', 'hsts', 'false'],
        ['proxy:build-config', 'demo-app'],
        ['nginx:set', 'demo-app', 'hsts-preload', 'true'],
        ['proxy:build-config', 'demo-app'],
        ['nginx:set', 'demo-app', 'hsts-include-subdomains', 'false'],
        ['proxy:build-config', 'demo-app'],
      ]);
      await finish(tester);
    });

    testWidgets('a failed nginx change does not rebuild the config', (tester) async {
      final ssh = await pumpScreen(tester, routing(), answers: {
        'nginx:set demo-app hsts false': failed(' !     Invalid key specified\n'),
      });
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'HSTS'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['nginx:set', 'demo-app', 'hsts', 'false']
      ]);
      await finish(tester);
    });
  });

  testWidgets('a shell user gets the same three tabs', (tester) async {
    for (final tab in [
      RoutingTab(host: rootHost, app: 'demo-app'),
      StorageTab(host: rootHost, app: 'demo-app'),
      SettingsTab(host: rootHost, app: 'demo-app'),
    ]) {
      final ssh = await pumpScreen(tester, inPage(tab), host: rootHost);
      expect(find.byType(CmdFooter), findsWidgets);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    }
  });

  group('Storage & network', () {
    testAtAllSizes('shows mounts, Docker options and networks', (tester, size) async {
      final ssh = await pumpScreen(tester, storage(), size: size);
      expect(find.text('/var/lib/dokku/data/storage/demo-data'), findsOneWidget);
      expect(find.text('/app/storage'), findsOneWidget);
      expect(shown('--restart=on-failure:10'), findsOneWidget);
      expect(shown('--shm-size=256m'), findsOneWidget);
      expect(find.text('-v /var/lib/dokku/data/storage/demo-data:/app/storage'), findsOneWidget);
      expect(find.text('Initial network'), findsOneWidget);
      expect(find.text('(none)'), findsNWidgets(3));
      expect(find.text('available: bridge · demo-net · host · none'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testAtAllSizes('an app without volumes or flags says so', (tester, size) async {
      final ssh = await pumpScreen(tester, storage('worker-app'), size: size);
      expect(find.textContaining('No volumes are mounted.'), findsOneWidget);
      expect(shown('--restart=on-failure:10'), findsOneWidget);
      await tapOn(tester, find.text('run'));
      expect(find.text('No extra flags for the run phase.'), findsOneWidget);
      expect(ssh.missing, isEmpty);
    });

    testAtAllSizes('unmounting asks first', (tester, size) async {
      final ssh = await pumpScreen(tester, storage(), size: size);
      await tapOn(tester, find.text('Unmount'));
      expect(find.text('Unmount volume?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.text('Unmount'));
      await tapOn(tester, find.text('Unmount').last);
      expect(ssh.changes, [
        ['storage:unmount', 'demo-app', '/var/lib/dokku/data/storage/demo-data:/app/storage']
      ]);
    });

    testWidgets('unmounting names the mount exactly, options included', (tester) async {
      final ssh = await pumpScreen(tester, storage(), answers: {
        'storage:list demo-app --format json':
            ok('[{"host_path":"/srv/shared","container_path":"/data","volume_options":"ro"}]'),
      });
      expect(find.text('ro'), findsOneWidget);
      await tapOn(tester, find.text('Unmount'));
      await tapOn(tester, find.text('Unmount').last);
      expect(ssh.changes, [
        ['storage:unmount', 'demo-app', '/srv/shared:/data:ro']
      ]);
      await finish(tester);
    });

    testAtAllSizes('mounting managed storage creates the directory first', (tester, size) async {
      final ssh = await pumpScreen(tester, storage('worker-app'), size: size);
      await tapOn(tester, find.text('Mount volume'));
      expect(find.text('Mount a volume'), findsOneWidget);
      final submit = find.widgetWithText(Btn, 'Mount volume').last;
      expect(tester.widget<Btn>(submit).onPressed, isNull);

      await type(tester, field('worker-app'), 'uploads');
      await choose(tester, within(find.byType(AppDialog), find.byType(AppSelect<String>)), 'root');
      await type(tester, field('/app/storage'), '/app/uploads');
      expect(
        find.text('\$ dokku storage:ensure-directory --chown root uploads\n'
            '\$ dokku storage:mount worker-app /var/lib/dokku/data/storage/uploads:/app/uploads'),
        findsOneWidget,
      );
      await tapOn(tester, submit);
      expect(ssh.changes, [
        ['storage:ensure-directory', '--chown', 'root', 'uploads'],
        ['storage:mount', 'worker-app', '/var/lib/dokku/data/storage/uploads:/app/uploads'],
      ]);
      expect(find.text('Mount a volume'), findsNothing);
    });

    testWidgets('mounting an existing host path only mounts', (tester) async {
      final ssh = await pumpScreen(tester, storage());
      await tapOn(tester, find.text('Mount volume'));
      await type(tester, field('/srv/data/uploads'), '/srv/shared');
      await tapOn(tester, find.widgetWithText(Btn, 'Mount volume').last);
      expect(ssh.changes, [
        ['storage:mount', 'demo-app', '/srv/shared:/app/storage']
      ]);
      await finish(tester);
    });

    testWidgets('the default owner is not passed, and a failed directory stops the mount', (tester) async {
      final ssh = await pumpScreen(tester, storage(), answers: {
        'storage:ensure-directory uploads': failed(' !     Unable to create the directory\n'),
      });
      await tapOn(tester, find.text('Mount volume'));
      await type(tester, field('demo-app'), 'uploads');
      await tapOn(tester, find.widgetWithText(Btn, 'Mount volume').last);
      expect(ssh.changes, [
        ['storage:ensure-directory', 'uploads']
      ]);
      expect(find.text('Mount a volume'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('cancelling the mount dialog does nothing', (tester) async {
      final ssh = await pumpScreen(tester, storage());
      await tapOn(tester, find.text('Mount volume'));
      await type(tester, field('demo-app'), 'uploads');
      await tapOn(tester, find.text('Cancel'));
      expect(find.text('Mount a volume'), findsNothing);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('adds and removes Docker options for the chosen phase', (tester, size) async {
      final ssh = await pumpScreen(tester, storage(), size: size);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Add flag')).onPressed, isNull);
      await type(tester, field('--shm-size=256m'), '--memory=1g');
      expect(find.textContaining('\$ dokku docker-options:add demo-app deploy --memory=1g'), findsOneWidget);
      await tapOn(tester, find.text('Add flag'));

      await tapOn(tester, find.text('build'));
      expect(shown('--shm-size=256m'), findsNothing);
      expect(find.textContaining('\$ dokku docker-options:add demo-app build <flag>'), findsOneWidget);
      await tapOn(tester, find.byTooltip('Remove flag'));
      expect(ssh.changes, [
        ['docker-options:add', 'demo-app', 'deploy', '--memory=1g'],
        ['docker-options:remove', 'demo-app', 'build', '--link dokku.redis.cache:dokku-redis-cache'],
      ]);
    });

    testAtAllSizes('attaches the app to a network', (tester, size) async {
      final ssh = await pumpScreen(tester, storage(), size: size);
      final selects = within(card('Networks'), find.byType(AppSelect<String>));
      expect(selects, findsNWidgets(3));
      await tapOn(tester, selects.at(1));
      // Docker's own networks cannot be attached to.
      expect(find.text('host'), findsNothing);
      expect(find.text('bridge'), findsWidgets);
      await tester.tap(find.text('demo-net').last);
      await settle(tester);
      expect(ssh.changes, [
        ['network:set', 'demo-app', 'attach-post-create', 'demo-net']
      ]);
    });

    testWidgets('choosing (none) clears a network property', (tester) async {
      final ssh = await pumpScreen(tester, storage(), answers: {
        'network:report demo-app': ok(report('demo-app', 'network', {
          'Network attach post create': '',
          'Network attach post deploy': '',
          'Network bind all interfaces': 'false',
          'Network computed attach post create': '',
          'Network computed attach post deploy': 'demo-net',
          'Network computed initial network': 'gone-net',
          'Network global attach post deploy': 'demo-net',
          'Network initial network': 'gone-net',
        })),
      });
      // A network that no longer exists is still shown as the current value.
      expect(find.text('gone-net'), findsOneWidget);
      expect(find.textContaining('global: demo-net'), findsOneWidget);
      await choose(tester, within(card('Networks'), find.byType(AppSelect<String>)).first, '(none)');
      expect(ssh.changes, [
        ['network:set', 'demo-app', 'initial-network']
      ]);
      await finish(tester);
    });

    testWidgets('binds to all interfaces and creates a network', (tester) async {
      final ssh = await pumpScreen(tester, storage());
      await tapOn(tester, find.text('false'));
      expect(ssh.changes, isEmpty);
      await tapOn(tester, find.text('true'));

      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Create network')).onPressed, isNull);
      await type(tester, field('new-network'), 'jobs net');
      expect(find.textContaining('\$ dokku network:create jobsnet'), findsOneWidget);
      await tapOn(tester, find.text('Create network'));
      expect(ssh.changes, [
        ['network:set', 'demo-app', 'bind-all-interfaces', 'true'],
        ['network:create', 'jobsnet'],
      ]);
      await finish(tester);
    });
  });

  group('Settings', () {
    testAtAllSizes('shows app facts, registry, lock and danger zone', (tester, size) async {
      final ssh = await pumpScreen(tester, settings(), size: size);
      final created = DateTime.fromMillisecondsSinceEpoch(1790686813 * 1000);
      String two(int n) => n.toString().padLeft(2, '0');
      expect(find.text('${created.year}-${two(created.month)}-${two(created.day)}'), findsOneWidget);
      expect(find.text('1790686813'), findsNothing);
      expect(find.text('docker-image · master'), findsOneWidget);
      expect(find.text('/home/dokku/demo-app'), findsOneWidget);
      expect(find.textContaining('dokku/demo-app', findRichText: true), findsWidgets);
      expect(find.textContaining('Deploys are allowed.'), findsOneWidget);
      expect(find.text('\$ dokku --force apps:destroy demo-app'), findsOneWidget);
      expect(find.text('Host: prod-01'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Rename')).onPressed, isNull);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Save')).onPressed, isNull);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('an app that was never deployed shows the default source', (tester) async {
      final ssh = await pumpScreen(tester, settings('worker-app'));
      expect(find.text('git push · master'), findsOneWidget);
      expect(ssh.missing, isEmpty);
      await finish(tester);
    });

    testAtAllSizes('renaming asks first, then opens the renamed app', (tester, size) async {
      final ssh = await pumpScreen(tester, settings(), size: size);
      final name = within(card('General'), find.byType(TextField));
      await type(tester, name, 'worker-app');
      expect(find.text('An app with this name already exists.'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Rename')).onPressed, isNull);

      await type(tester, name, 'Demo-API');
      expect(find.textContaining('\$ dokku apps:rename demo-app demo-api'), findsOneWidget);
      await tapOn(tester, find.text('Rename'));
      expect(find.text('Rename demo-app to demo-api?'), findsOneWidget);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);
      expect(routeOf(tester), const DashboardRoute());

      await tapOn(tester, find.text('Rename'));
      await tapOn(tester, find.text('Rename app'));
      expect(ssh.changes, [
        ['apps:rename', 'demo-app', 'demo-api']
      ]);
      expect(routeOf(tester), const AppDetailRoute('demo-api', AppTab.settings));
    });

    testWidgets('a failed rename stays on the page', (tester) async {
      final ssh = await pumpScreen(tester, settings(), answers: {
        'apps:rename demo-app demo-api': failed(' !     App demo-api already exists\n'),
      });
      await type(tester, within(card('General'), find.byType(TextField)), 'demo-api');
      await tapOn(tester, find.text('Rename'));
      await tapOn(tester, find.text('Rename app'));
      expect(ssh.changes, hasLength(1));
      expect(routeOf(tester), const DashboardRoute());
      await finish(tester);
    });

    testAtAllSizes('saves only the registry values that changed', (tester, size) async {
      final ssh = await pumpScreen(tester, settings(), size: size);
      await type(tester, field('ghcr.io'), 'registry.example.com');
      expect(find.textContaining('\$ dokku registry:set demo-app server registry.example.com'), findsOneWidget);
      await tapOn(tester, find.text('Save'));
      expect(ssh.changes, [
        ['registry:set', 'demo-app', 'server', 'registry.example.com']
      ]);
    });

    testWidgets('clearing a registry value unsets it', (tester) async {
      final ssh = await pumpScreen(tester, settings(), answers: {
        'registry:report demo-app': ok(report('demo-app', 'registry', {
          'Registry computed image repo': 'acme/demo',
          'Registry computed push on release': 'true',
          'Registry computed server': 'ghcr.io/',
          'Registry image repo': 'acme/demo',
          'Registry push on release': 'true',
          'Registry server': 'ghcr.io',
        })),
      });
      final fields = within(card('Container registry'), find.byType(TextField));
      expect(tester.widget<TextField>(fields.first).controller!.text, 'ghcr.io');
      expect(tester.widget<TextField>(fields.last).controller!.text, 'acme/demo');
      await type(tester, fields.first, '');
      await type(tester, fields.last, 'acme/api');
      await tapOn(tester, find.text('Save'));
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'Push on release'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['registry:set', 'demo-app', 'server'],
        ['registry:set', 'demo-app', 'image-repo', 'acme/api'],
        ['registry:set', 'demo-app', 'push-on-release', 'false'],
      ]);
      await finish(tester);
    });

    testWidgets('push on release is turned on with registry:set', (tester) async {
      final ssh = await pumpScreen(tester, settings());
      await tapOn(tester, within(find.widgetWithText(SwitchRow, 'Push on release'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['registry:set', 'demo-app', 'push-on-release', 'true']
      ]);
      await finish(tester);
    });

    testWidgets('the deploy lock switch locks and unlocks', (tester) async {
      var ssh = await pumpScreen(tester, settings());
      expect(find.text('\$ dokku apps:lock demo-app  ·  apps:locked demo-app'), findsOneWidget);
      await tapOn(tester, within(find.widgetWithText(PanelHead, 'Deploy lock'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['apps:lock', 'demo-app']
      ]);
      await finish(tester);

      ssh = await pumpScreen(tester, settings(), answers: {
        'apps:report demo-app': ok(report('demo-app', 'app', {
          'App created at': '1790686813',
          'App deploy source': 'docker-image',
          'App dir': '/home/dokku/demo-app',
          'App locked': 'true',
        })),
      });
      expect(find.textContaining('Deploys are blocked.'), findsOneWidget);
      await tapOn(tester, within(find.widgetWithText(PanelHead, 'Deploy lock'), find.byType(AppSwitch)));
      expect(ssh.changes, [
        ['apps:unlock', 'demo-app']
      ]);
      await finish(tester);
    });

    testAtAllSizes('destroying needs the app name typed, then returns to the apps list', (tester, size) async {
      final ssh = await pumpScreen(tester, settings(), size: size);
      await tapOn(tester, find.text('Destroy app'));
      expect(find.text('Destroy demo-app?'), findsOneWidget);
      final confirm = find.widgetWithText(Btn, 'Destroy app').last;
      expect(tester.widget<Btn>(confirm).onPressed, isNull);
      await tapOn(tester, find.text('Cancel'));
      expect(ssh.changes, isEmpty);

      await tapOn(tester, find.text('Destroy app'));
      await type(tester, within(find.byType(AppDialog), find.byType(TextField)), 'demo-ap');
      expect(tester.widget<Btn>(confirm).onPressed, isNull);
      await type(tester, within(find.byType(AppDialog), find.byType(TextField)), 'demo-app');
      await tapOn(tester, confirm);
      expect(ssh.changes, [
        ['--force', 'apps:destroy', 'demo-app']
      ]);
      expect(routeOf(tester), const AppsRoute());
    });

    testWidgets('a failed destroy stays on the page', (tester) async {
      final ssh = await pumpScreen(tester, settings(), answers: {
        '--force apps:destroy demo-app': failed(' !     App is locked\n'),
      });
      await tapOn(tester, find.text('Destroy app'));
      await type(tester, within(find.byType(AppDialog), find.byType(TextField)), 'demo-app');
      await tapOn(tester, find.widgetWithText(Btn, 'Destroy app').last);
      expect(ssh.changes, hasLength(1));
      expect(routeOf(tester), const DashboardRoute());
      await finish(tester);
    });

    testWidgets('cloning copies the settings of this app into a new one', (tester) async {
      final ssh = await pumpScreen(tester, settings());
      await tapOn(tester, within(card('Clone'), find.byType(Btn)));
      expect(find.text('Clone demo-app'), findsOneWidget);
      expect(find.text('Copy settings from (optional)'), findsOneWidget);
      expect(ssh.changes, isEmpty);

      await type(tester, within(find.byType(AppDialog), find.byType(TextField)), 'demo-staging');
      expect(find.text('\$ dokku apps:clone demo-app demo-staging'), findsOneWidget);
      await tapOn(tester, find.widgetWithText(Btn, 'Clone app').last);
      expect(ssh.changes, [
        ['apps:clone', 'demo-app', 'demo-staging'],
      ]);
      await finish(tester);
    });
  });
}
