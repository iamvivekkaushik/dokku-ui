import 'dart:convert';

import 'package:dokku_console/core/command.dart';
import 'package:dokku_console/core/templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// The variables a `config:set --encoded` sets, decoded.
Map<String, String> decodeConfig(List<String> args) => {
      for (final a in args.skip(4)) a.substring(0, a.indexOf('=')): utf8.decode(base64.decode(a.substring(a.indexOf('=') + 1))),
    };

Iterable<String> placeholders(String text) => RegExp(r'\{(\w+)\}').allMatches(text).map((m) => m[1]!);

List<String> commandsOf(InstallPlan p) => [for (final s in p.steps) s.args.first == 'config:set' ? 'config:set' : s.args.join(' ')];

void main() {
  group('Catalog', () {
    test('every template is well formed', () {
      expect(templates.map((t) => t.id).toSet().length, templates.length, reason: 'ids are unique');
      const known = {'postgres', 'redis', 'mysql', 'rabbitmq'};
      for (final t in templates) {
        expect(appNamePattern.hasMatch(t.id), isTrue, reason: '${t.id} is a valid app name');
        expect(t.image.contains(':'), isFalse, reason: '${t.id}: the tag is chosen separately');
        expect(t.tags, isNotEmpty, reason: t.id);
        if (t.port != null) expect(t.port, greaterThan(0), reason: t.id);
        expect(t.glyph.length, 2, reason: t.id);
        expect(t.homepage, startsWith('https://'), reason: t.id);
        expect(t.notes, contains(t.port == null ? '{domain}' : '{url}'), reason: '${t.id} tells the user where to go');
        expect(t.port != null || t.publish.isNotEmpty, isTrue, reason: '${t.id} is reachable somehow');
        for (final p in t.publish) {
          expect(p, matches(RegExp(r'^\d+:\d+(/udp)?$')), reason: '${t.id}: $p');
        }
        expect({for (final m in t.mounts) m.name}.length, t.mounts.length, reason: '${t.id}: mount names are unique');
        for (final s in t.services) {
          expect(known, contains(s.type), reason: '${t.id} uses ${s.type}');
          for (final v in s.env.values) {
            expect(placeholders(v), everyElement(isIn(['url', 'host', 'port', 'user', 'password', 'database'])), reason: '${t.id}: $v');
          }
        }
        for (final v in t.env.values) {
          expect(placeholders(v), everyElement(isIn(['app', 'domain', 'url', 'scheme', 'https'])), reason: '${t.id}: $v');
        }
        expect(placeholders(t.notes), everyElement(isIn(['app', 'domain', 'url', 'data'])), reason: t.id);
        for (final k in t.secrets) {
          expect(k, matches(RegExp(r'^[A-Z][A-Z0-9_]*$')), reason: t.id);
        }
        for (final m in t.mounts) {
          expect(['herokuish', 'heroku', 'paketo', 'false'], contains(m.owner), reason: '${t.id}: Dokku 0.35 knows no other owners');
        }
        expect({for (final s in t.settings) s.id}.length, t.settings.length, reason: '${t.id}: setting ids are unique');
      }
    });

    test('the three the store was asked for are there', () {
      expect(templateOf('n8n'), isNotNull);
      expect(templateOf('inngest')?.startCommand, 'inngest start');
      expect(templateOf('outpost')?.services.map((s) => s.type), ['postgres', 'redis', 'rabbitmq']);
      expect(templateOf('nope'), isNull);
    });
  });

  group('Plan', () {
    final n8n = templateOf('n8n')!;

    test('n8n as it comes: storage kept, SQLite, the default domain', () {
      final p = planInstall(n8n, defaultChoices(n8n), defaultDomain: 'n8n.dokku.test');
      expect(commandsOf(p), [
        'apps:create n8n',
        'storage:ensure-directory --chown heroku n8n-data',
        'storage:mount n8n /var/lib/dokku/data/storage/n8n-data:/home/node/.n8n',
        'config:set',
        'ports:set n8n http:80:5678',
        'git:from-image n8n docker.n8n.io/n8nio/n8n:latest',
      ]);
      expect(p.env['N8N_HOST'], 'n8n.dokku.test');
      expect(p.env['WEBHOOK_URL'], 'http://n8n.dokku.test/');
      expect(p.env['N8N_PROTOCOL'], 'http');
      expect(p.env['N8N_SECURE_COOKIE'], 'false');
      expect(p.env['GENERIC_TIMEZONE'], 'UTC');
      expect(p.env['TZ'], 'UTC');
      expect(p.env['N8N_ENCRYPTION_KEY'], hasLength(64));
      expect(p.env.containsKey('DB_TYPE'), isFalse, reason: 'no PostgreSQL unless asked');
      final set = p.steps.firstWhere((s) => s.args.first == 'config:set').args;
      expect(set.take(4), ['config:set', '--encoded', '--no-restart', 'n8n']);
      expect(decodeConfig(set), p.env);
      expect(p.url, 'http://n8n.dokku.test');
      expect(p.notes, contains('http://n8n.dokku.test'));
    });

    test('with a domain, HTTPS, PostgreSQL, a memory limit, another tag and no storage', () {
      final c = defaultChoices(n8n).copyWith(
        app: 'flows',
        tag: 'next',
        domain: ' flows.example.com ',
        letsencrypt: true,
        email: 'me@example.com',
        services: {'postgres'},
        mounts: {},
        memory: '1g',
        settings: {'GENERIC_TIMEZONE': 'Europe/Berlin'},
      );
      final p = planInstall(n8n, c, defaultDomain: 'flows.dokku.test');
      expect(commandsOf(p), [
        'apps:create flows',
        'config:set',
        'ports:set flows http:80:5678',
        'domains:set flows flows.example.com',
        'resource:limit --memory 1g flows',
        'postgres:create flows-db',
        'postgres:link flows-db flows --no-restart',
        'git:from-image flows docker.n8n.io/n8nio/n8n:next',
        'letsencrypt:set flows email me@example.com',
        'letsencrypt:enable flows',
        'letsencrypt:cron-job --add',
      ]);
      expect(p.env['N8N_PROTOCOL'], 'https');
      expect(p.env['N8N_SECURE_COOKIE'], 'true');
      expect(p.env['WEBHOOK_URL'], 'https://flows.example.com/');
      expect(p.env['TZ'], 'Europe/Berlin');
      expect(p.steps.last.quiet, isTrue, reason: 'a missing cron job is not worth stopping for');
      final link = p.steps.whereType<LinkStep>().single;
      expect(link.derive('postgres://postgres:s3cret@dokku-postgres-flows-db:5432/flows_db\n'), {
        'DB_TYPE': 'postgresdb',
        'DB_POSTGRESDB_HOST': 'dokku-postgres-flows-db',
        'DB_POSTGRESDB_PORT': '5432',
        'DB_POSTGRESDB_DATABASE': 'flows_db',
        'DB_POSTGRESDB_USER': 'postgres',
        'DB_POSTGRESDB_PASSWORD': 's3cret',
      });
    });

    test('a redis URL has no user name, passwords are decoded, and a query can be added', () {
      final outpost = templateOf('outpost')!;
      final redis = outpost.services.firstWhere((s) => s.type == 'redis');
      expect(deriveEnv(redis, 'redis://:p%40ss@dokku-redis-outpost-redis:6379\n'), {
        'REDIS_HOST': 'dokku-redis-outpost-redis',
        'REDIS_PORT': '6379',
        'REDIS_PASSWORD': 'p@ss',
        'REDIS_DATABASE': '0',
      });
      final pg = outpost.services.first;
      expect(deriveEnv(pg, 'postgres://u:p@h:5432/d')['POSTGRES_URL'], 'postgres://u:p@h:5432/d?sslmode=disable');
      final mq = outpost.services.last;
      expect(deriveEnv(mq, 'amqp://mq:p@dokku-rabbitmq-outpost-mq:5672/mq')['RABBITMQ_SERVER_URL'], 'amqp://mq:p@dokku-rabbitmq-outpost-mq:5672/mq');
    });

    test('a start command goes through DOKKU_DOCKERFILE_START_CMD', () {
      final t = templateOf('inngest')!;
      final p = planInstall(t, defaultChoices(t), defaultDomain: 'inngest.dokku.test');
      expect(p.env['DOKKU_DOCKERFILE_START_CMD'], 'inngest start');
      expect(p.env['INNGEST_SQLITE_DIR'], '/data');
      expect(p.env['INNGEST_EVENT_KEY'], isNot(p.env['INNGEST_SIGNING_KEY']));
      expect(commandsOf(p), contains('storage:mount inngest /var/lib/dokku/data/storage/inngest-data:/data'));
    });

    test('required services are on from the start and cannot be dropped by the plan', () {
      final t = templateOf('outpost')!;
      final p = planInstall(t, defaultChoices(t), defaultDomain: 'outpost.dokku.test');
      expect(commandsOf(p), containsAllInOrder([
        'postgres:create outpost-db',
        'postgres:link outpost-db outpost --no-restart',
        'redis:create outpost-redis',
        'redis:link outpost-redis outpost --no-restart',
        'rabbitmq:create outpost-mq',
        'rabbitmq:link outpost-mq outpost --no-restart',
        'git:from-image outpost hookdeck/outpost:latest',
      ]));
    });

    test('the preview decodes values, hides secrets and marks what a link provides', () {
      final p = planInstall(n8n, defaultChoices(n8n).copyWith(services: {'postgres'}), defaultDomain: 'n8n.dokku.test');
      final text = describePlan(p);
      expect(text, contains('\$ dokku config:set --no-restart n8n N8N_HOST=n8n.dokku.test'));
      expect(text, contains('N8N_ENCRYPTION_KEY=•••'));
      expect(text, isNot(contains(p.env['N8N_ENCRYPTION_KEY']!)));
      expect(text, contains('\$ dokku postgres:link n8n-db n8n --no-restart'));
      expect(text, contains('DB_POSTGRESDB_PASSWORD=<from DATABASE_URL>'));
      expect(text, isNot(contains('--encoded')));
    });

    test('an app without HTTP publishes its ports and leaves the proxy out', () {
      final t = templateOf('rustdesk')!;
      final p = planInstall(t, defaultChoices(t).copyWith(letsencrypt: true, email: 'me@example.com'), defaultDomain: 'rustdesk.dokku.test');
      expect(commandsOf(p), [
        'apps:create rustdesk',
        'storage:ensure-directory --chown false rustdesk-data',
        'storage:mount rustdesk /var/lib/dokku/data/storage/rustdesk-data:/data',
        'config:set',
        'docker-options:add rustdesk deploy -p 21115:21115',
        'docker-options:add rustdesk deploy -p 21116:21116',
        'docker-options:add rustdesk deploy -p 21116:21116/udp',
        'docker-options:add rustdesk deploy -p 21117:21117',
        'docker-options:add rustdesk deploy -p 21118:21118',
        'docker-options:add rustdesk deploy -p 21119:21119',
        'proxy:disable rustdesk',
        'scheduler-docker-local:set rustdesk init-process false',
        'git:from-image rustdesk rustdesk/rustdesk-server-s6:latest',
      ], reason: 'no ports:set and no certificate: nothing answers HTTP');
      expect(p.env, {'RELAY': 'rustdesk.dokku.test', 'ENCRYPTED_ONLY': '1', 'ALWAYS_USE_RELAY': 'N'});
      expect(p.notes, contains('/var/lib/dokku/data/storage/rustdesk-data/id_ed25519.pub'));
      expect(p.notes, contains('rustdesk.dokku.test'));
    });

    test('secrets are fresh and long', () {
      expect(generateSecret(), isNot(generateSecret()));
      expect(generateSecret(), matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('Problems', () {
    test('names, plugins, HTTPS, domains and memory are checked', () {
      final umami = templateOf('umami')!;
      final c = defaultChoices(umami);
      expect(installProblems(umami, c, plugins: {'postgres'}, apps: []), isEmpty);
      expect(installProblems(umami, c, plugins: {}, apps: []), ['The postgres plugin is not installed.']);
      expect(installProblems(umami, c.copyWith(app: 'Bad Name'), plugins: {'postgres'}, apps: []).first, contains('lowercase'));
      expect(installProblems(umami, c, plugins: {'postgres'}, apps: ['umami']).first, contains('already exists'));
      expect(installProblems(umami, c.copyWith(letsencrypt: true), plugins: {'postgres'}, apps: []),
          ['The letsencrypt plugin is not installed.', "Let's Encrypt needs an email address."]);
      expect(installProblems(umami, c.copyWith(letsencrypt: true, email: 'me@example.com'), plugins: {'postgres', 'letsencrypt'}, apps: []), isEmpty);
      expect(installProblems(umami, c.copyWith(domain: 'nope'), plugins: {'postgres'}, apps: []).first, contains('domain'));
      expect(installProblems(umami, c.copyWith(memory: 'lots'), plugins: {'postgres'}, apps: []).first, contains('Memory'));
      expect(installProblems(umami, c.copyWith(memory: '512m', domain: 'stats.example.com'), plugins: {'postgres'}, apps: []), isEmpty);
    });
  });
}
