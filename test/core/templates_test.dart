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
          if (m.uid != null) expect(m.uid, greaterThan(0), reason: '${t.id}: ${m.name}');
        }
        expect({for (final s in t.settings) s.id}.length, t.settings.length, reason: '${t.id}: setting ids are unique');
      }
    });

    test('categories are listed in order with their counts', () {
      final cats = templateCategories();
      expect(cats.keys, cats.keys.toList()..sort());
      expect(cats.values.reduce((a, b) => a + b), templates.length);
      expect(cats['Automation'], 3, reason: 'n8n, Node-RED and Windmill');
      for (final t in templates) {
        expect(cats.keys, contains(t.category), reason: t.id);
      }
    });

    test('the second batch is there, with what each needs', () {
      for (final id in ['wikijs', 'docmost', 'miniflux', 'gotify', 'ntfy', 'node-red', 'memos', 'vikunja', 'planka', 'mattermost', 'gitea', 'keycloak', 'windmill', 'open-webui', 'excalidraw']) {
        expect(templateOf(id), isNotNull, reason: id);
      }
      expect(templateOf('ntfy')?.startCommand, 'serve', reason: 'the image has ntfy as its entrypoint');
      expect(templateOf('keycloak')?.startCommand, 'start');
      expect(templateOf('gitea')?.publish, ['2222:2222']);
      expect(templateOf('docmost')?.services.map((s) => s.type), ['postgres', 'redis']);
      expect(templateOf('excalidraw')?.mounts, isEmpty);
      expect(templateOf('mattermost')?.mounts.map((m) => m.owner).toSet(), {'paketo'}, reason: 'Mattermost runs as uid 2000');
    });

    test('the templates whose image runs as another uid hand their storage over on the host', () {
      for (final id in ['grafana', 'pgadmin', 'verdaccio', 'hedgedoc', 'outline', 'formbricks', 'actual', 'searxng']) {
        expect(needsChown(templateOf(id)!), isTrue, reason: id);
      }
      expect(needsChown(templateOf('linkding')!), isFalse, reason: 'its entrypoint runs as root and chowns for itself');
      expect(templateOf('grafana')!.mounts.single.uid, 472);
      expect(templateOf('searxng')!.mounts.map((m) => m.uid), [977, 977]);
      expect(templateOf('outline')!.services.map((s) => s.type), ['postgres', 'redis']);
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

    test('a datastore elsewhere is set from its URL: nothing created or linked, and the preview hides it', () {
      final c = defaultChoices(n8n).copyWith(services: {'postgres'}, urls: {'postgres': ' postgres://n8n:s3cret@db.example.com:5432/n8n '});
      final p = planInstall(n8n, c, defaultDomain: 'n8n.dokku.test');
      expect(commandsOf(p), [
        'apps:create n8n',
        'storage:ensure-directory --chown heroku n8n-data',
        'storage:mount n8n /var/lib/dokku/data/storage/n8n-data:/home/node/.n8n',
        'config:set',
        'ports:set n8n http:80:5678',
        'git:from-image n8n docker.n8n.io/n8nio/n8n:latest',
      ]);
      expect(p.steps.whereType<LinkStep>(), isEmpty);
      expect(p.env['DATABASE_URL'], 'postgres://n8n:s3cret@db.example.com:5432/n8n');
      expect(p.env['DB_TYPE'], 'postgresdb');
      expect(p.env['DB_POSTGRESDB_HOST'], 'db.example.com');
      expect(p.env['DB_POSTGRESDB_USER'], 'n8n');
      expect(p.env['DB_POSTGRESDB_PASSWORD'], 's3cret');
      expect(p.hidden, containsAll(['N8N_ENCRYPTION_KEY', 'DATABASE_URL', 'DB_POSTGRESDB_PASSWORD']));
      expect(p.hidden, isNot(contains('DB_POSTGRESDB_HOST')));
      final text = describePlan(p);
      expect(text, contains('DATABASE_URL=•••'));
      expect(text, contains('DB_POSTGRESDB_PASSWORD=•••'));
      expect(text, contains('DB_POSTGRESDB_HOST=db.example.com'));
      expect(text, isNot(contains('s3cret')));
      expect(text, isNot(contains('<from DATABASE_URL>')));
    });

    test('URLs and plugins mix per service, and a URL with a query keeps it', () {
      final outpost = templateOf('outpost')!;
      final c = defaultChoices(outpost).copyWith(urls: {'redis': 'redis://:p%40ss@cache.example.com:6379', 'postgres': ''});
      final p = planInstall(outpost, c, defaultDomain: 'outpost.dokku.test');
      expect(commandsOf(p),
          containsAllInOrder(['postgres:create outpost-db', 'postgres:link outpost-db outpost --no-restart', 'rabbitmq:create outpost-mq']));
      expect(commandsOf(p), isNot(contains('redis:create outpost-redis')));
      expect(p.env['REDIS_URL'], 'redis://:p%40ss@cache.example.com:6379');
      expect(p.env['REDIS_HOST'], 'cache.example.com');
      expect(p.env['REDIS_PASSWORD'], 'p@ss');
      expect(p.hidden, containsAll(['REDIS_URL', 'REDIS_PASSWORD', 'API_KEY']));
      final pg = outpost.services.first;
      expect(deriveEnv(pg, 'postgres://u:p@db.example.com:5432/d?sslmode=require')['POSTGRES_URL'], 'postgres://u:p@db.example.com:5432/d?sslmode=require',
          reason: 'the query the template adds for the plugin service gives way to the one the URL has');
      final kc = templateOf('keycloak')!.services.single;
      expect(deriveEnv(kc, 'postgres://kc:p@db.example.com/keycloak')['KC_DB_URL'], 'jdbc:postgresql://db.example.com:5432/keycloak',
          reason: 'a URL without a port gets the default of its type');
    });

    test('a mount for another uid is handed over with chown on the host, which takes a shell login', () {
      final t = templateOf('grafana')!;
      final p = planInstall(t, defaultChoices(t), defaultDomain: 'grafana.dokku.test');
      expect(commandsOf(p), [
        'apps:create grafana',
        'storage:ensure-directory --chown false grafana-data',
        'chown 472:472 /var/lib/dokku/data/storage/grafana-data',
        'storage:mount grafana /var/lib/dokku/data/storage/grafana-data:/var/lib/grafana',
        'config:set',
        'ports:set grafana http:80:3000',
        'git:from-image grafana grafana/grafana:latest',
      ]);
      expect(p.steps[2], isA<HostStep>());
      expect(describePlan(p), contains('\n\$ chown 472:472 /var/lib/dokku/data/storage/grafana-data\n'));
      expect(describePlan(p), isNot(contains('dokku chown')));
      expect(installProblems(t, defaultChoices(t), plugins: {}, apps: []), isEmpty);
      expect(installProblems(t, defaultChoices(t), plugins: {}, apps: [], shell: false).single, contains('needs root'));
      final ephemeral = defaultChoices(t).copyWith(mounts: {});
      expect(installProblems(t, ephemeral, plugins: {}, apps: [], shell: false), isEmpty, reason: 'nothing to hand over');
      expect(planInstall(t, ephemeral, defaultDomain: 'grafana.dokku.test').steps.whereType<HostStep>(), isEmpty);
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
      expect(installProblems(umami, c, plugins: {}, apps: []),
          ['The postgres plugin is not installed. Install it, or give the URL of one running elsewhere.']);
      const elsewhere = {'postgres': 'postgres://umami:s3cret@db.example.com:5432/umami'};
      expect(installProblems(umami, c.copyWith(urls: elsewhere), plugins: {}, apps: []), isEmpty, reason: 'a URL needs no plugin');
      expect(installProblems(umami, c.copyWith(urls: {'postgres': 'db.example.com:5432'}), plugins: {}, apps: []),
          ['The postgres URL needs a scheme and a host, like postgres://user:password@host:5432/db.']);
      expect(installProblems(umami, c.copyWith(urls: {'postgres': '  '}), plugins: {}, apps: []).single, contains('plugin is not installed'),
          reason: 'blank means provision');
      expect(installProblems(umami, c.copyWith(app: 'Bad Name'), plugins: {'postgres'}, apps: []).first, contains('lowercase'));
      expect(installProblems(umami, c, plugins: {'postgres'}, apps: ['umami']).first, contains('already exists'));
      expect(installProblems(umami, c.copyWith(letsencrypt: true), plugins: {'postgres'}, apps: []),
          ['The letsencrypt plugin is not installed.', "Let's Encrypt needs an email address."]);
      expect(installProblems(umami, c.copyWith(letsencrypt: true, email: 'me@example.com'), plugins: {'postgres', 'letsencrypt'}, apps: []), isEmpty);
      expect(installProblems(umami, c.copyWith(domain: 'nope'), plugins: {'postgres'}, apps: []).first, contains('domain'));
      expect(installProblems(umami, c.copyWith(memory: 'lots'), plugins: {'postgres'}, apps: []).first, contains('Memory'));
      expect(installProblems(umami, c.copyWith(memory: '512m', domain: 'stats.example.com'), plugins: {'postgres'}, apps: []), isEmpty);
    });

    test('a datastore URL needs a scheme and a host', () {
      for (final ok in ['postgres://u:p@h:5432/d', 'redis://:p@h:6379', 'mongodb+srv://u:p@cluster.example.com/db', ' http://host:7700 ']) {
        expect(looksLikeServiceUrl(ok), isTrue, reason: ok);
      }
      for (final bad in ['', 'h:5432', 'postgres://', 'postgres://u:p@h a/d', 'db.example.com/d']) {
        expect(looksLikeServiceUrl(bad), isFalse, reason: bad);
      }
      expect(serviceUrlExample('redis'), 'redis://:password@host:6379');
      expect(serviceUrlExample('mariadb'), startsWith('mysql://'));
    });
  });
}
