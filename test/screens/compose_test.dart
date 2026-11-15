import 'dart:convert';

import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/state/router.dart';
import 'package:dokku_console/ui/screens/compose.dart';
import 'package:dokku_console/ui/screens/store.dart';
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

Finder _switch(String label) => find.byWidgetPredicate((w) => w is AppSwitch && w.label == label);

Finder _input(String label) => find.descendant(of: find.widgetWithText(Field, label), matching: find.byType(TextField));

String _preview(WidgetTester tester) => tester.widget<CodeBlock>(find.byType(CodeBlock)).text;

Btn _deploy(WidgetTester tester) => tester.widget<Btn>(find.byWidgetPredicate((w) => w is Btn && RegExp(r'^Deploy \d+ apps?$').hasMatch(w.label)));

List<String> _joined(FakeSsh ssh) => [for (final c in ssh.changes) c.first == 'config:set' ? 'config:set ${c[3]}' : c.join(' ')];

Map<String, String> _decode(List<String> args) => {
      for (final a in args.skip(4)) a.substring(0, a.indexOf('=')): utf8.decode(base64.decode(a.substring(a.indexOf('=') + 1))),
    };

AppRoute _route(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(StoreScreen))).read(routeProvider);

const _compose = r'''
name: docmost
services:
  docmost:
    image: docmost/docmost:latest
    depends_on: [db, redis]
    environment:
      APP_URL: http://localhost:3000
      APP_SECRET: ${APP_SECRET}
      DATABASE_URL: postgresql://docmost:${POSTGRES_PASSWORD}@db:5432/docmost
      REDIS_URL: redis://redis:6379
      TZ: ${TZ:-UTC}
    ports: ["3000:3000"]
    volumes: [docmost:/app/data/storage, ./nginx.conf:/etc/nginx.conf:ro]
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes: [db_data:/var/lib/postgresql/data]
    healthcheck: {test: [CMD, pg_isready]}
  redis:
    image: redis:7.2-alpine
    volumes: [redis_data:/data]
  proxy:
    image: caddy:2
    ports: ["80:80", "443:443"]
volumes:
  docmost:
  db_data:
  redis_data:
''';

/// Opens the Store's compose dialogs with [text] pasted.
Future<FakeSsh> _open(WidgetTester tester, {String text = _compose, Size size = desktop, Map<String, ExecResult> answers = const {}}) async {
  final ssh = await pumpScreen(tester, StoreScreen(host: rootHost), size: size, host: rootHost, answers: answers);
  await _press(tester, find.byKey(const ValueKey('compose')));
  await _type(tester, find.descendant(of: find.byType(ComposeSourceDialog), matching: find.byType(TextField)), text);
  await _press(tester, find.widgetWithText(Btn, 'Continue'));
  return ssh;
}

void main() {
  group('Compose', () {
    testWidgets('reads what is pasted, and says what is wrong with it', (tester) async {
      await pumpScreen(tester, StoreScreen(host: rootHost), host: rootHost);
      await _press(tester, find.byKey(const ValueKey('compose')));
      final input = find.descendant(of: find.byType(ComposeSourceDialog), matching: find.byType(TextField));
      Btn next() => tester.widget<Btn>(find.widgetWithText(Btn, 'Continue'));
      expect(find.text('Paste it here, or open the file.'), findsOneWidget);
      expect(next().onPressed, isNull);
      await _type(tester, input, 'services: [oops');
      expect(find.textContaining('Line 1'), findsOneWidget);
      expect(next().onPressed, isNull);
      await _type(tester, input, 'version: "3.8"');
      expect(find.text('It has no services.'), findsOneWidget);
      await _type(tester, input, _compose);
      expect(find.text('4 services: docmost, db, redis, proxy.'), findsOneWidget);
      expect(next().onPressed, isNotNull);
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
      expect(find.byType(ComposeSourceDialog), findsNothing);
      await finish(tester);
    });

    testAtAllSizes('the dialog shows what will run and follows every choice', (tester, size) async {
      await _open(tester, size: size);
      expect(find.text('Deploy a compose file'), findsOneWidget);
      expect(find.text('4 services, pasted'), findsOneWidget);
      var text = _preview(tester);
      expect(text, startsWith('\$ dokku network:exists docmost || dokku network:create docmost\n\n# db: postgres:16-alpine\n'));
      expect(text.indexOf('# redis:'), lessThan(text.indexOf('# docmost:')), reason: 'dependencies first');
      expect(text, contains('storage:mount docmost-db docmost_db_data:/var/lib/postgresql/data'));
      expect(text, contains('docker-options:add docmost-db deploy \'--network-alias db\''));
      expect(text, contains('ports:set docmost http:80:3000'));
      expect(text, contains('POSTGRES_PASSWORD=•••'));
      expect(text, contains('TZ=UTC'));
      expect(text, isNot(contains('caddy')), reason: 'a reverse proxy of its own is left out');
      expect(find.textContaining("Dokku's proxy does its job"), findsOneWidget);
      expect(find.textContaining('Not carried over: healthcheck.'), findsOneWidget);
      expect(find.text('docmost.dokku.test goes through the proxy to port 3000.'), findsOneWidget);
      expect(_deploy(tester).label, 'Deploy 3 apps');
      expect(_deploy(tester).onPressed, isNotNull);

      // The config file beside the compose file stays out until it is copied over.
      expect(text, isNot(contains('nginx.conf')));
      await _press(tester, _switch('./nginx.conf → /etc/nginx.conf (read-only)'));
      expect(_preview(tester), contains('storage:mount docmost /var/lib/dokku/data/storage/docmost-nginx.conf:/etc/nginx.conf:ro'));
      await _press(tester, _switch('Volume redis_data → /data'));
      expect(_preview(tester), isNot(contains('docmost_redis_data')));
      expect(find.textContaining('lost on every deploy'), findsOneWidget);

      // Exposure: the database on the host publishes nothing, since the file publishes nothing for it.
      await _press(tester, find.text('Host ports').at(1));
      expect(find.text('It publishes no ports, so nothing outside reaches it.'), findsOneWidget);
      await _press(tester, find.text('Internal').first);
      expect(_preview(tester), contains('proxy:disable docmost\n'));
      expect(_preview(tester), isNot(contains('ports:set docmost')));
      await _press(tester, find.text('Web').first);
      await _type(tester, _input('Domain'), 'wiki.example.com');
      expect(_preview(tester), contains('domains:set docmost wiki.example.com'));

      // Variables: typed wins over the .env, which wins over a generated value.
      expect(find.text('A random value generated on this device. Type one to use it instead.'), findsNWidgets(2));
      await _type(tester, find.widgetWithText(TextField, 'KEY=value, one per line'), 'TZ=Europe/Berlin\nPOSTGRES_PASSWORD=from-dotenv\n');
      expect(_preview(tester), contains('TZ=Europe/Berlin'));
      expect(find.text('From the .env.'), findsNWidgets(2));
      await _type(tester, _input('TZ'), 'Asia/Kolkata');
      expect(_preview(tester), contains('TZ=Asia/Kolkata'));

      // Problems hold the deploy back.
      await _press(tester, _switch('proxy'));
      expect(find.textContaining("publishes port 443 on the host, which Dokku's proxy holds"), findsWidgets);
      expect(_deploy(tester).onPressed, isNull);
      await _press(tester, find.text('Internal').last);
      expect(_deploy(tester).onPressed, isNotNull);
      await _type(tester, find.widgetWithText(TextField, 'docmost').first, 'demo-app');
      expect(find.text('Apps are named demo-app-<service>, and the service named demo-app is the app demo-app.'), findsOneWidget);
      await _type(tester, find.widgetWithText(TextField, 'demo-app'), 'demo');
      expect(_deploy(tester).onPressed, isNotNull);
      await _press(tester, _switch('db'));
      expect(find.text('It depends on db, which is not deployed here.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
    });

    testWidgets('a proxy that runs in a container is named as a risk for the services on the web', (tester) async {
      await _open(tester, answers: {'proxy:report': ok('=====> demo-app proxy information\n       Proxy global type:             caddy\n')});
      expect(find.textContaining("This host's proxy is caddy"), findsOneWidget, reason: 'docmost alone is on the web');
      await _press(tester, find.text('Internal').first);
      expect(find.textContaining("This host's proxy is caddy"), findsNothing);
      await _press(tester, find.widgetWithText(Btn, 'Cancel'));
      await finish(tester);
    });

    testWidgets('deploys with the commands shown, joining a network that exists, then lists the apps', (tester) async {
      final ssh = await _open(tester, answers: {'network:exists docmost': ok('-----> Network exists\n')});
      await _press(tester, find.widgetWithText(Btn, 'Deploy 3 apps'));
      await settle(tester, frames: 40);
      expect(ssh.ran.map((c) => c.join(' ')), contains('network:exists docmost'));
      expect(_joined(ssh), [
        'apps:create docmost-db',
        'network:set docmost-db initial-network docmost',
        'docker-options:add docmost-db deploy --network-alias db',
        'storage:mount docmost-db docmost_db_data:/var/lib/postgresql/data',
        'config:set docmost-db',
        'checks:disable docmost-db web',
        'proxy:disable docmost-db',
        'scheduler-docker-local:set docmost-db init-process false',
        'git:from-image docmost-db postgres:16-alpine',
        'apps:create docmost-redis',
        'network:set docmost-redis initial-network docmost',
        'docker-options:add docmost-redis deploy --network-alias redis',
        'storage:mount docmost-redis docmost_redis_data:/data',
        'checks:disable docmost-redis web',
        'proxy:disable docmost-redis',
        'scheduler-docker-local:set docmost-redis init-process false',
        'git:from-image docmost-redis redis:7.2-alpine',
        'apps:create docmost',
        'network:set docmost initial-network docmost',
        'docker-options:add docmost deploy --network-alias docmost',
        'storage:mount docmost docmost_docmost:/app/data/storage',
        'config:set docmost',
        'ports:set docmost http:80:3000',
        'checks:disable docmost web',
        'scheduler-docker-local:set docmost init-process false',
        'git:from-image docmost docmost/docmost:latest',
      ], reason: 'the network exists, so it is not created');
      final db = _decode(ssh.changes.firstWhere((c) => c.first == 'config:set' && c[3] == 'docmost-db'));
      final app = _decode(ssh.changes.firstWhere((c) => c.first == 'config:set' && c[3] == 'docmost'));
      expect(db['POSTGRES_PASSWORD'], hasLength(64));
      expect(app['DATABASE_URL'], 'postgresql://docmost:${db['POSTGRES_PASSWORD']}@db:5432/docmost', reason: 'one password for both');
      expect(app['APP_SECRET'], hasLength(64));
      expect(_route(tester), const AppsRoute());
      expect(find.text('docmost is up'), findsOneWidget);
      expect(find.text('http://docmost.dokku.test'), findsOneWidget);
      expect(find.text('db on the network'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('creates the network when it is missing, and stops at the first failure', (tester) async {
      final ssh = await _open(tester,
          text: 'services: {web: {image: nginx, ports: ["8080:80"]}}',
          answers: {'network:exists web': failed(' !     Network does not exist\n'), 'git:from-image web nginx:latest': failed(' !     pull failed\n')});
      await _press(tester, find.widgetWithText(Btn, 'Deploy 1 app'));
      await settle(tester, frames: 40);
      expect(_joined(ssh), [
        'network:create web',
        'apps:create web',
        'network:set web initial-network web',
        'docker-options:add web deploy --network-alias web',
        'ports:set web http:80:80',
        'scheduler-docker-local:set web init-process false',
        'git:from-image web nginx:latest',
      ]);
      expect(find.text('web is up'), findsNothing);
      await finish(tester);
    });
  });
}
