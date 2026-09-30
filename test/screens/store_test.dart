import 'dart:convert';

import 'package:dokku_console/core/templates.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/store.dart';
import 'package:dokku_console/ui/shell/shell.dart';
import 'package:dokku_console/ui/widgets/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Future<void> _press(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await settle(tester);
}

Future<void> _type(WidgetTester tester, Finder f, String text) async {
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await settle(tester);
}

Finder _field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

Finder _switch(String label) => find.byWidgetPredicate((w) => w is AppSwitch && w.label == label);

String _preview(WidgetTester tester) => tester.widget<CodeBlock>(find.byType(CodeBlock)).text;

List<String> _joined(FakeSsh ssh) => [for (final c in ssh.changes) c.first == 'config:set' ? 'config:set' : c.join(' ')];

Map<String, String> _decode(List<String> args) => {
      for (final a in args.skip(4)) a.substring(0, a.indexOf('=')): utf8.decode(base64.decode(a.substring(a.indexOf('=') + 1))),
    };

AppRoute _route(WidgetTester tester, Type screen) => ProviderScope.containerOf(tester.element(find.byType(screen))).read(routeProvider);

const _n8nCommands = [
  'apps:create n8n',
  'storage:ensure-directory --chown heroku n8n-data',
  'storage:mount n8n /var/lib/dokku/data/storage/n8n-data:/home/node/.n8n',
  'config:set',
  'ports:set n8n http:80:5678',
  'git:from-image n8n docker.n8n.io/n8nio/n8n:latest',
];

void main() {
  group('Store', () {
    testAtAllSizes('lists every template with what it needs', (tester, size) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), size: size, host: rootHost);
      for (final t in templates) {
        expect(find.text(t.name), findsOneWidget, reason: t.name);
      }
      expect(find.text('storage'), findsWidgets);
      expect(find.text('postgres'), findsWidgets, reason: 'required datastores are named');
      expect(find.text('postgres · optional'), findsWidgets);
      expect(ssh.missing, isEmpty);
      expect(ssh.changes, isEmpty);
    });

    testWidgets('filters by name, category and tagline', (tester) async {
      await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      await _type(tester, _field('Filter templates'), 'uptime');
      expect(find.text('Uptime Kuma'), findsOneWidget);
      expect(find.text('n8n'), findsNothing);
      await _type(tester, _field('Filter templates'), 'webhooks');
      expect(find.text('Outpost'), findsOneWidget);
      await _type(tester, _field('Filter templates'), 'zzz');
      expect(find.textContaining('No templates match'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the category list filters the grid, together with the text filter', (tester) async {
      await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      expect(find.text('All · ${templates.length}'), findsOneWidget);
      await _press(tester, find.text('Monitoring & alerts · 4'));
      expect(find.text('Uptime Kuma'), findsOneWidget);
      expect(find.text('Gotify'), findsOneWidget);
      expect(find.text('ntfy'), findsOneWidget);
      expect(find.text('Grafana'), findsOneWidget);
      expect(find.text('n8n'), findsNothing);
      await _type(tester, _field('Filter templates'), 'push');
      expect(find.text('Gotify'), findsOneWidget);
      expect(find.text('Uptime Kuma'), findsNothing);
      await _type(tester, _field('Filter templates'), 'n8n');
      expect(find.textContaining('No templates match'), findsOneWidget, reason: 'n8n is not in this category');
      await _press(tester, find.text('All · ${templates.length}'));
      expect(find.textContaining('No templates match'), findsNothing);
      expect(find.text('Uptime Kuma'), findsNothing, reason: 'the text filter still applies');
      await _type(tester, _field('Filter templates'), '');
      expect(find.text('Uptime Kuma'), findsOneWidget);
      await finish(tester);
    });

    testAtAllSizes('the install dialog shows what will run and follows every choice', (tester, size) async {
      await pumpScreen(tester, StoreScreen(host: rootHost), size: size, host: rootHost);
      await _press(tester, find.byKey(const ValueKey('install-n8n')));
      expect(find.text('Install n8n'), findsWidgets);
      expect(_preview(tester), contains('\$ dokku apps:create n8n'));
      expect(_preview(tester), contains('storage:mount n8n /var/lib/dokku/data/storage/n8n-data:/home/node/.n8n'));
      expect(_preview(tester), contains('ports:set n8n http:80:5678'));
      expect(_preview(tester), contains('N8N_HOST=n8n.dokku.test'), reason: 'the default domain comes from the global vhost');
      expect(_preview(tester), contains('git:from-image n8n docker.n8n.io/n8nio/n8n:latest'));
      expect(_preview(tester), contains('N8N_ENCRYPTION_KEY=•••'));

      await _press(tester, _switch('Keep workflows, credentials and the SQLite database on the host'));
      expect(_preview(tester), isNot(contains('storage:mount')));
      expect(find.textContaining('lost on every deploy'), findsOneWidget);

      await _type(tester, _field('n8n.example.com'), 'flows.example.com');
      expect(_preview(tester), contains('domains:set n8n flows.example.com'));
      expect(_preview(tester), contains('WEBHOOK_URL=http://flows.example.com/'));

      // Only redis is installed on the fixture host: PostgreSQL goes on all the same, for one running elsewhere.
      expect(find.textContaining('The postgres plugin is not installed.'), findsOneWidget);
      await _press(tester, _switch('PostgreSQL'));
      expect(find.widgetWithText(Btn, 'Install plugin'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install n8n')).onPressed, isNull, reason: 'neither plugin nor URL');
      await _type(tester, _field('postgres://user:password@host:5432/db'), 'postgres://n8n:s3cret@db.example.com:5432/n8n');
      expect(find.widgetWithText(Btn, 'Install plugin'), findsNothing);
      expect(_preview(tester), contains('DATABASE_URL=•••'));
      expect(_preview(tester), contains('DB_POSTGRESDB_HOST=db.example.com'));
      expect(_preview(tester), isNot(contains('postgres:create')));
      expect(_preview(tester), isNot(contains('s3cret')));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install n8n')).onPressed, isNotNull);
      await _type(tester, _field('postgres://user:password@host:5432/db'), 'db.example.com:5432');
      expect(find.textContaining('scheme and a host'), findsWidgets);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install n8n')).onPressed, isNull);
      await _press(tester, _switch('PostgreSQL'));
      expect(find.text('PostgreSQL URL'), findsNothing);
      expect(tester.widget<AppSwitch>(_switch("Let's Encrypt certificate")).onChanged, isNull);

      await _type(tester, find.widgetWithText(TextField, 'n8n'), 'demo-app');
      expect(find.text('An app with this name already exists.'), findsOneWidget);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install n8n')).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
      await finish(tester);
    });

    testWidgets('installs n8n with the commands shown, then opens the app', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      await _press(tester, find.byKey(const ValueKey('install-n8n')));
      await _press(tester, find.widgetWithText(Btn, 'Install n8n'));
      await settle(tester, frames: 30);
      expect(_joined(ssh), _n8nCommands);
      final env = _decode(ssh.changes.firstWhere((c) => c.first == 'config:set'));
      expect(env['N8N_HOST'], 'n8n.dokku.test');
      expect(env['N8N_PORT'], '5678');
      expect(env['N8N_ENCRYPTION_KEY'], hasLength(64));
      expect(_route(tester, StoreScreen), const AppDetailRoute('n8n'));
      expect(find.text('n8n is up'), findsOneWidget);
      expect(find.text('http://n8n.dokku.test'), findsOneWidget);
      expect(find.textContaining('owner account'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a linked datastore sets the variables the app expects, from the URL Dokku gives', (tester) async {
      final plugins = '${loadFixtures()['plugin:list']!.stdout}  postgres             1.40.0 enabled    dokku postgres service plugin\n';
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost, answers: {
        'plugin:list': ok(plugins),
        'postgres:list': ok('=====> Postgres services\n'),
        'config:get n8n DATABASE_URL': ok('postgres://postgres:s3cret@dokku-postgres-n8n-db:5432/n8n_db\n'),
      });
      await _press(tester, find.byKey(const ValueKey('install-n8n')));
      await _press(tester, _switch('PostgreSQL'));
      expect(_preview(tester), contains('postgres:create n8n-db'));
      expect(_preview(tester), contains('DB_POSTGRESDB_HOST=<from DATABASE_URL>'));
      await _press(tester, find.widgetWithText(Btn, 'Install n8n'));
      await settle(tester, frames: 30);
      expect(_joined(ssh), [
        ..._n8nCommands.take(5),
        'postgres:create n8n-db',
        'postgres:link n8n-db n8n --no-restart',
        'config:set',
        _n8nCommands.last,
      ]);
      expect(ssh.ran.map((c) => c.join(' ')), contains('config:get n8n DATABASE_URL'));
      final sets = ssh.changes.where((c) => c.first == 'config:set').toList();
      expect(_decode(sets.last), {
        'DB_TYPE': 'postgresdb',
        'DB_POSTGRESDB_HOST': 'dokku-postgres-n8n-db',
        'DB_POSTGRESDB_PORT': '5432',
        'DB_POSTGRESDB_DATABASE': 'n8n_db',
        'DB_POSTGRESDB_USER': 'postgres',
        'DB_POSTGRESDB_PASSWORD': 's3cret',
      });
      expect(find.text('n8n is up'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a datastore running elsewhere is set from its URL and needs no plugin', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      await _press(tester, find.byKey(const ValueKey('install-umami')));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install Umami')).onPressed, isNull, reason: 'no postgres plugin on the fixture host');
      await _type(tester, _field('postgres://user:password@host:5432/db'), 'postgres://umami:s3cret@db.example.com:5432/umami');
      expect(find.widgetWithText(Btn, 'Install plugin'), findsNothing);
      expect(find.textContaining('Nothing is provisioned'), findsOneWidget);
      expect(_preview(tester), contains('DATABASE_URL=•••'));
      expect(_preview(tester), isNot(contains('postgres:create')));
      await _press(tester, find.widgetWithText(Btn, 'Install Umami'));
      await settle(tester, frames: 30);
      expect(_joined(ssh), [
        'apps:create umami',
        'config:set',
        'ports:set umami http:80:3000',
        'git:from-image umami docker.umami.is/umami-software/umami:postgresql-latest',
      ]);
      final env = _decode(ssh.changes.firstWhere((c) => c.first == 'config:set'));
      expect(env['DATABASE_URL'], 'postgres://umami:s3cret@db.example.com:5432/umami');
      expect(env['APP_SECRET'], hasLength(64));
      expect(ssh.ran.map((c) => c.join(' ')), isNot(contains('config:get umami DATABASE_URL')));
      expect(find.text('Umami is up'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a template whose image runs as another uid hands its storage over on the host, as root', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      expect(find.text('needs root'), findsWidgets);
      await _press(tester, find.byKey(const ValueKey('install-grafana')));
      expect(find.textContaining('handed to uid 472 with chown'), findsOneWidget);
      expect(_preview(tester), contains('\$ chown 472:472 /var/lib/dokku/data/storage/grafana-data'));
      await _press(tester, find.widgetWithText(Btn, 'Install Grafana'));
      await settle(tester, frames: 30);
      expect(_joined(ssh), [
        'apps:create grafana',
        'storage:ensure-directory --chown false grafana-data',
        'storage:mount grafana /var/lib/dokku/data/storage/grafana-data:/var/lib/grafana',
        'config:set',
        'ports:set grafana http:80:3000',
        'git:from-image grafana grafana/grafana:latest',
      ]);
      expect(ssh.hostRan, ['chown 472:472 /var/lib/dokku/data/storage/grafana-data'], reason: 'root runs it as is');
      expect(find.text('Grafana is up'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the dokku user cannot hand storage over, unless the mount is left out', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: dokkuHost));
      await _press(tester, find.byKey(const ValueKey('install-grafana')));
      expect(find.textContaining('needs root'), findsWidgets);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install Grafana')).onPressed, isNull);
      await _press(tester, _switch('Keep dashboards, users and the SQLite database on the host'));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install Grafana')).onPressed, isNotNull, reason: 'nothing to hand over');
      expect(_preview(tester), isNot(contains('chown')));
      expect(ssh.changes, isEmpty);
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
      await finish(tester);
    });

    testWidgets('a failure stops the install where it is', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost, answers: {'ports:set n8n http:80:5678': failed(' !     nope\n')});
      await _press(tester, find.byKey(const ValueKey('install-n8n')));
      await _press(tester, find.widgetWithText(Btn, 'Install n8n'));
      await settle(tester, frames: 30);
      expect(_joined(ssh), _n8nCommands.take(5));
      expect(_route(tester, StoreScreen), isNot(const AppDetailRoute('n8n')));
      expect(find.text('n8n is up'), findsNothing);
      await finish(tester);
    });

    testWidgets('a required plugin that is missing blocks the install, and root can add it from the dialog', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      await _press(tester, find.byKey(const ValueKey('install-umami')));
      expect(find.textContaining('The postgres plugin is not installed.'), findsWidgets);
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install Umami')).onPressed, isNull);
      await _press(tester, find.widgetWithText(Btn, 'Install plugin'));
      expect(ssh.changes, [
        ['plugin:install', 'https://github.com/dokku/dokku-postgres.git', '--name', 'postgres'],
      ]);
      await finish(tester);
    });

    testWidgets('a template without HTTP shows its ports and no HTTPS section', (tester) async {
      await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      expect(find.text('host ports'), findsNWidgets(2), reason: 'RustDesk and Gitea');
      await _press(tester, find.byKey(const ValueKey('install-rustdesk')));
      expect(find.text("Let's Encrypt certificate"), findsNothing);
      expect(find.textContaining('Clients connect to this name.'), findsOneWidget);
      expect(_preview(tester), contains('docker-options:add rustdesk deploy \'-p 21116:21116/udp\''));
      expect(_preview(tester), contains('proxy:disable rustdesk'));
      expect(_preview(tester), isNot(contains('ports:set')));
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
      await finish(tester);
    });

    testWidgets('the dokku user is told plugins need root', (tester) async {
      final ssh = await pumpScreen(tester, StoreScreen(host: dokkuHost));
      await _press(tester, find.byKey(const ValueKey('install-umami')));
      expect(tester.widget<Btn>(find.widgetWithText(Btn, 'Install plugin')).onPressed, isNull);
      expect(find.textContaining('Installing plugins needs root'), findsOneWidget);
      expect(ssh.changes, isEmpty);
      await finish(tester);
    });

    testWidgets('the Apps page leads to the store, which keeps the Apps tab lit on a phone', (tester) async {
      await pumpScreen(tester, const HomeShell(), size: phone);
      ProviderScope.containerOf(tester.element(find.byType(HomeShell))).read(routerProvider.notifier).section(const AppsRoute());
      await settle(tester);
      await _press(tester, find.widgetWithText(Btn, 'Store'));
      expect(_route(tester, HomeShell), const StoreRoute());
      expect(find.text('Filter templates'), findsOneWidget);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(_route(tester, HomeShell), const AppsRoute());
      await finish(tester);
    });

    testWidgets('the sidebar has a Store entry', (tester) async {
      await pumpScreen(tester, const HomeShell());
      await _press(tester, find.text('Store').first);
      expect(_route(tester, HomeShell), const StoreRoute());
      expect(find.text('Uptime Kuma'), findsOneWidget);
      await finish(tester);
    });
  });
}
