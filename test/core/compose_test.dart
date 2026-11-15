import 'dart:convert';

import 'package:dokku_console/core/compose.dart';
import 'package:dokku_console/core/templates.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> decodeConfig(List<String> args) => {
      for (final a in args.skip(4)) a.substring(0, a.indexOf('=')): utf8.decode(base64.decode(a.substring(a.indexOf('=') + 1))),
    };

List<String> commandsOf(Iterable<PlanStep> steps) => [for (final s in steps) s.args.first == 'config:set' ? 'config:set' : s.args.join(' ')];

ComposeFile read(String yaml, [Map<String, String> values = const {}]) => ComposeSource.parse(yaml).resolve(values);

ComposeService only(String yaml, [Map<String, String> values = const {}]) => read(yaml, values).services.single;

const docmost = '''
name: docmost
services:
  docmost:
    image: docmost/docmost:latest
    depends_on: [db, redis]
    environment:
      APP_URL: 'http://localhost:3000'
      APP_SECRET: '\${APP_SECRET}'
      DATABASE_URL: 'postgresql://docmost:\${POSTGRES_PASSWORD}@db:5432/docmost?schema=public'
      REDIS_URL: 'redis://redis:6379'
    ports:
      - "3000:3000"
    restart: unless-stopped
    volumes:
      - docmost:/app/data/storage
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/postgresql/data
  redis:
    image: redis:7.2-alpine
    restart: unless-stopped
    volumes:
      - redis_data:/data
volumes:
  docmost:
  db_data:
  redis_data:
''';

void main() {
  group('Interpolation', () {
    String sub(String s, [Map<String, String> values = const {}]) => interpolate(s, values);

    test('substitutes the forms Compose knows', () {
      const v = {'A': 'x', 'EMPTY': ''};
      expect(sub(r'$A ${A} ${MISSING}', v), 'x x ');
      expect(sub(r'${A:-d} ${EMPTY:-d} ${MISSING:-d}', v), 'x d d');
      expect(sub(r'${A-d} ${EMPTY-d} ${MISSING-d}', v), 'x  d');
      expect(sub(r'${A:+r} ${EMPTY:+r} ${MISSING:+r}', v), 'r  ');
      expect(sub(r'${A+r} ${EMPTY+r} ${MISSING+r}', v), 'r r ');
      expect(sub(r'$$A costs $$5, $1 and ${A}', v), r'$A costs $5, $1 and x');
      expect(sub(r'${MISSING:-${A}-suffix}', v), 'x-suffix', reason: 'a default may hold a variable');
      expect(sub(r'unterminated ${A', v), r'unterminated ${A');
      expect(sub(r'${not valid}', v), r'${not valid}');
    });

    test('hears of every variable, those in an unused default as well', () {
      final seen = <String, ComposeVariable>{};
      interpolate(r'${A:-${B}} $C ${D:?set D}', const {'A': 'a'}, refer: (v) => seen[v.name] = seen[v.name]?.merge(v) ?? v);
      expect(seen.keys, ['A', 'B', 'C', 'D']);
      expect(seen['A']!.fallback, r'${B}');
      expect(seen['D']!.required, isTrue);
      expect(seen['D']!.message, 'set D');
    });

    test('names a required variable that is not set, only where it is used', () {
      final missing = <String>[];
      interpolate(r'${A:?} ${B?} ${C:?} ${OK:-${D:?}}', const {'B': '', 'C': '', 'OK': 'y'}, missing: (v) => missing.add(v.name));
      expect(missing, ['A', 'C'], reason: '? accepts empty, :? does not, and the unused default is not read');
    });

    test('passwords without a default are generated; URLs, users and files are not', () {
      for (final n in ['POSTGRES_PASSWORD', 'APP_SECRET', 'JWT_SECRET', 'SECRET_KEY_BASE', 'API_TOKEN', 'ENCRYPTION_KEY', 'DB_PASS']) {
        expect(ComposeVariable(n).generated, isTrue, reason: n);
      }
      for (final n in ['DATABASE_URL', 'POSTGRES_PASSWORD_FILE', 'DB_USER', 'TZ', 'PWD', 'MONKEY', 'KEY_ID']) {
        expect(ComposeVariable(n).generated, isFalse, reason: n);
      }
      expect(const ComposeVariable('DB_PASSWORD', fallback: 'changeme').generated, isFalse, reason: 'it has a default');
    });
  });

  group('Reading', () {
    test('rejects what is not a compose file', () {
      expect(() => ComposeSource.parse('services: [a'), throwsFormatException);
      expect(() => ComposeSource.parse('version: "3"'), throwsFormatException);
      expect(() => ComposeSource.parse('services: {}'), throwsFormatException);
      expect(() => ComposeSource.parse('- just\n- a list'), throwsFormatException);
    });

    test('odd but valid shapes degrade instead of failing', () {
      final f = read('''
services:
  a:
  b: [1, 2]
  c:
    image: nginx
    volumes: {data: /x}
    ports: 8080
    environment: FOO
    networks: [front]
''');
      expect(f.services.map((s) => s.name), ['a', 'b', 'c']);
      expect(f.services[0].deployable, isFalse);
      expect(f.services[2].mounts, isEmpty);
      expect(f.services[2].ports, isEmpty);
      expect(f.services[2].environment, {'FOO': null});
    });

    test('applies YAML merge keys: explicit keys win, then the maps in the order given', () {
      final s = only('''
x-a: &a {image: a, user: "1", restart: always}
x-b: &b {image: b, user: "2", hostname: b}
services:
  web:
    <<: [*a, *b]
    image: mine
''');
      expect(s.image, 'mine');
      expect(s.options.map((o) => o.flag), containsAll(['--user 1', '--hostname b']));
      expect(s.restart, 'always');
      expect(s.leftOut, isEmpty, reason: 'x- keys and merge keys are not reported');
    });

    test('reads environment from a map or a list, and keeps names without a value', () {
      expect(only('services: {a: {image: x, environment: {A: 1, B: true, C: , D: "x=y"}}}').environment,
          {'A': '1', 'B': 'true', 'C': null, 'D': 'x=y'});
      final s = only('services: {a: {image: x, environment: ["A=1", "B", "C=x=y"]}}');
      expect(s.environment, {'A': '1', 'B': null, 'C': 'x=y'});
      expect(s.variables['B']!.fromShell, isTrue);
    });

    test('reads every port form', () {
      final s = only('''
services:
  a:
    image: x
    ports:
      - 80
      - "8080:80"
      - "127.0.0.1:5432:5432"
      - "127.0.0.1::9000"
      - "[::1]:6379:6379"
      - "53:53/udp"
      - "8000-8010:8000-8010"
      - {target: 443, published: "8443", host_ip: 0.0.0.0, protocol: tcp}
      - "not a port"
    expose: [3000, "4000/udp"]
''');
      expect(s.ports.map((p) => p.publish),
          ['80', '8080:80', '127.0.0.1:5432:5432', '127.0.0.1::9000', '[::1]:6379:6379', '53:53/udp', '8000-8010:8000-8010', '0.0.0.0:8443:443']);
      expect(s.ports.map((p) => p.loopback), [false, false, true, true, true, false, false, false]);
      expect(s.httpPorts, [80, 5432, 9000, 6379, 443, 3000], reason: 'one TCP port each, no ranges, no UDP');
    });

    test('tells volumes, host paths and paths beside the file apart', () {
      final s = only('''
services:
  a:
    image: x
    volumes:
      - data:/var/lib/data
      - /srv/media:/media:ro
      - ./uploads:/app/uploads
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./.env:/app/.env
      - .:/app
      - ~/backups:/backups
      - ./config:/config:ro
      - /app/node_modules
      - type: tmpfs
        target: /tmp
      - {type: bind, source: ./certs, target: /certs, read_only: true}
      - "/srv/with space:/x"
''');
      final m = {for (final x in s.mounts) x.target: x};
      expect(m.keys, isNot(contains('/tmp')), reason: 'a tmpfs is a docker option');
      expect(s.options.map((o) => o.flag), contains('--tmpfs /tmp'));
      expect(m['/var/lib/data']!.kind, MountKind.volume);
      expect(m['/media']!.kind, MountKind.host);
      expect(m['/media']!.readOnly, isTrue);
      expect(m['/app/uploads']!.kind, MountKind.project);
      expect(m['/app/node_modules']!.kind, MountKind.anonymous);
      expect(m['/etc/nginx/nginx.conf']!.file, isTrue);
      expect(m['/app/.env']!.file, isTrue);
      expect(m['/app']!.root, isTrue);
      expect(m['/backups']!.kind, MountKind.project, reason: "~ is the user's home under Compose, not the server's");
      expect(m['/certs']!.kind, MountKind.project);
      expect(m['/x']!.usable, isFalse, reason: 'Dokku runs docker options through the shell');
      expect([for (final x in s.mounts) if (x.keptByDefault) x.target], ['/var/lib/data', '/media', '/app/uploads', '/backups'],
          reason: 'data is kept; a config file, the project itself and read-only paths are not');
    });

    test('a command string is split like a shell, and the start command is quoted for one', () {
      final s = only(r'''
services:
  a:
    image: x
    command: sh -c "echo $$HOME && exec run --name 'two words'"
''');
      expect(s.command, ['sh', '-c', r'echo $HOME && exec run --name ' "'two words'"]);
      expect(s.startCommand, r"sh -c 'echo $HOME && exec run --name '\''two words'\'''");
      final e = only('services: {a: {image: x, entrypoint: ["/bin/sh", "-c"], command: ["echo hi"]}}');
      expect(e.options.first, (phases: 'deploy,run', flag: '--entrypoint /bin/sh'));
      expect(e.startCommand, "-c 'echo hi'", reason: 'the rest of the entrypoint goes before the command');
      expect(only('services: {a: {image: x, entrypoint: ""}}').options.first.flag, "--entrypoint ''");
    });

    test('maps limits, restart policies and docker flags', () {
      final s = only('''
services:
  a:
    image: x
    restart: "no"
    mem_limit: 1.5g
    cpus: 0.5
    user: "1000:1000"
    working_dir: /srv/app
    cap_add: [NET_ADMIN]
    privileged: true
    extra_hosts: ["host.docker.internal=host-gateway", "db:10.0.0.2"]
    sysctls: {net.core.somaxconn: 1024}
    ulimits: {nproc: 65535, nofile: {soft: 20000, hard: 40000}}
    init: true
    healthcheck: {test: ["CMD", "true"]}
    labels: [a=b]
    deploy:
      replicas: 2
      placement: {constraints: []}
''');
      expect(s.restart, 'no');
      expect(s.memory, '1536m');
      expect(s.cpus, '0.5');
      expect(s.replicas, 2);
      expect(s.init, isTrue);
      expect(s.options.map((o) => o.flag), [
        "--user 1000:1000",
        '--workdir /srv/app',
        '--cap-add NET_ADMIN',
        '--privileged',
        '--add-host host.docker.internal:host-gateway',
        '--add-host db:10.0.0.2',
        '--sysctl net.core.somaxconn=1024',
        '--ulimit nproc=65535',
        '--ulimit nofile=20000:40000',
      ]);
      expect(s.leftOut, ['healthcheck', 'labels', 'deploy.placement']);
      final d = only('services: {a: {image: x, deploy: {resources: {limits: {memory: 512M, cpus: "2"}}, restart_policy: {condition: on-failure, max_attempts: 3}}}}');
      expect([d.memory, d.cpus, d.restart], ['512m', '2', 'on-failure:3']);
      expect(only('services: {a: {image: x, restart: sometimes, mem_limit: lots}}').restart, isNull);
    });

    test('gathers the names a service answers to', () {
      final f = read('''
services:
  web:
    image: x
    links: ["db:database", "cache"]
  db:
    image: postgres
    container_name: pg
    networks:
      backend:
        aliases: [postgres, db]
  cache:
    image: redis
''');
      expect(f.service('db')!.aliases, ['pg', 'postgres', 'database']);
      expect(f.service('web')!.dependsOn, ['db', 'cache']);
      expect(f.ordered.map((s) => s.name), ['db', 'cache', 'web']);
    });

    test('dependencies go first, and a cycle does not hang', () {
      final f = read('''
services:
  a: {image: x, depends_on: {b: {condition: service_healthy}}}
  b: {image: x, depends_on: [c]}
  c: {image: x, depends_on: [a]}
  d: {image: x}
''');
      expect(f.ordered.map((s) => s.name), ['c', 'b', 'a', 'd']);
    });

    test('a service is put on the web, the host or the network by what it publishes', () {
      final f = read('''
services:
  web: {image: ghcr.io/acme/web:1, ports: ["8080:3000"]}
  db: {image: postgres:16, ports: ["5432:5432"]}
  local: {image: x, ports: ["127.0.0.1:9000:9000"]}
  dns: {image: x, ports: ["53:53/udp"]}
  worker: {image: x, expose: [3000]}
  caddy: {image: caddy:2, ports: ["80:80", "443:443"]}
''');
      expect({for (final s in f.services) s.name: s.defaultExposure},
          {'web': Exposure.web, 'db': Exposure.internal, 'local': Exposure.internal, 'dns': Exposure.host, 'worker': Exposure.internal, 'caddy': Exposure.web});
      expect([for (final s in f.services) if (s.bundledProxy) s.name], ['caddy']);
      expect(f.service('db')!.imageRef, 'postgres:16');
      expect(read('services: {a: {image: nginx}}').services.single.imageRef, 'nginx:latest');
      expect(read('services: {a: {image: "localhost:5000/app"}}').services.single.imageRef, 'localhost:5000/app:latest');
      expect(read('services: {a: {image: "app@sha256:abc"}}').services.single.imageRef, 'app@sha256:abc');
    });
  });

  group('Plan', () {
    final source = ComposeSource.parse(docmost);
    final values = {'APP_SECRET': 'a' * 64, 'POSTGRES_PASSWORD': 'p' * 64};

    ComposeChoices choices([ComposeChoices Function(ComposeChoices c)? change]) {
      final c = defaultComposeChoices(source);
      final fixed = ComposeChoices(project: c.project, services: c.services, mounts: c.mounts, generated: values);
      return change == null ? fixed : change(fixed);
    }

    ComposePlan plan(ComposeChoices c) => planCompose(source.resolve(c.effective), c, vhost: 'dokku.test');

    test('the defaults: every service, its volumes, and a random value for each password', () {
      final c = defaultComposeChoices(source);
      expect(c.project, 'docmost');
      expect(c.services, {'docmost', 'db', 'redis'});
      expect(c.mounts, {'docmost:/app/data/storage', 'db:/var/lib/postgresql/data', 'redis:/data'});
      expect(c.generated.keys, {'APP_SECRET', 'POSTGRES_PASSWORD'});
      expect(c.generated.values, everyElement(hasLength(64)));
    });

    test('runs the network, then each service after what it depends on', () {
      final p = plan(choices());
      expect(p.steps.first.args, ['network:create', 'docmost']);
      expect(p.steps.first.unless, ['network:exists', 'docmost']);
      expect(p.apps.map((a) => a.app), ['docmost-db', 'docmost-redis', 'docmost']);
      expect(commandsOf(p.apps[0].steps), [
        'apps:create docmost-db',
        'network:set docmost-db initial-network docmost',
        'docker-options:add docmost-db deploy --network-alias db',
        'storage:mount docmost-db docmost_db_data:/var/lib/postgresql/data',
        'config:set',
        'checks:disable docmost-db web',
        'proxy:disable docmost-db',
        'scheduler-docker-local:set docmost-db init-process false',
        'ps:set docmost-db restart-policy unless-stopped',
        'git:from-image docmost-db postgres:16-alpine',
      ]);
      expect(commandsOf(p.apps[1].steps), contains('storage:mount docmost-redis docmost_redis_data:/data'));
      expect(commandsOf(p.apps[1].steps), isNot(contains('config:set')), reason: 'redis sets nothing');
      expect(commandsOf(p.apps[2].steps), [
        'apps:create docmost',
        'network:set docmost initial-network docmost',
        'docker-options:add docmost deploy --network-alias docmost',
        'storage:mount docmost docmost_docmost:/app/data/storage',
        'config:set',
        'ports:set docmost http:80:3000',
        'checks:disable docmost web',
        'scheduler-docker-local:set docmost init-process false',
        'ps:set docmost restart-policy unless-stopped',
        'git:from-image docmost docmost/docmost:latest',
      ]);
      expect(p.apps[2].url, 'http://docmost.dokku.test');
      final env = decodeConfig(p.apps[2].steps.firstWhere((s) => s.args.first == 'config:set').args);
      expect(env['DATABASE_URL'], 'postgresql://docmost:${'p' * 64}@db:5432/docmost?schema=public',
          reason: 'the service name works as a host on the network');
      expect(env['APP_SECRET'], 'a' * 64);
      expect(decodeConfig(p.apps[0].steps.firstWhere((s) => s.args.first == 'config:set').args)['POSTGRES_PASSWORD'], 'p' * 64,
          reason: 'both services get the same password');
    });

    test('the preview hides passwords wherever they turn up, and reads as shell', () {
      final text = describeComposePlan(plan(choices()));
      expect(text, startsWith('\$ dokku network:exists docmost || dokku network:create docmost\n\n# db: postgres:16-alpine\n'));
      expect(text, contains('POSTGRES_PASSWORD=•••'));
      expect(text, contains('DATABASE_URL=•••'));
      expect(text, contains('APP_URL=•••'), reason: 'a URL may carry a password');
      expect(text, contains('POSTGRES_USER=docmost'));
      expect(text, isNot(contains('p' * 20)));
      expect(text, isNot(contains('a' * 20)));
    });

    test('follows the choices: exposure, port, domain, mounts and HTTPS', () {
      final p = plan(choices((c) => c.copyWith(
            services: {'docmost', 'db'},
            exposure: {'db': Exposure.host, 'docmost': Exposure.web},
            domains: {'docmost': 'wiki.example.com'},
            mounts: {'db:/var/lib/postgresql/data'},
            letsencrypt: true,
            email: 'me@example.com',
          )));
      expect(p.apps.map((a) => a.app), ['docmost-db', 'docmost']);
      expect(commandsOf(p.apps[0].steps), containsAllInOrder(['checks:disable docmost-db web', 'proxy:disable docmost-db']));
      expect(commandsOf(p.apps[0].steps), isNot(contains(startsWith('docker-options:add docmost-db deploy -p'))), reason: 'the file publishes nothing for db');
      expect(commandsOf(p.apps[1].steps), [
        'apps:create docmost',
        'network:set docmost initial-network docmost',
        'docker-options:add docmost deploy --network-alias docmost',
        'config:set',
        'ports:set docmost http:80:3000',
        'scheduler-docker-local:set docmost init-process false',
        'ps:set docmost restart-policy unless-stopped',
        'domains:set docmost wiki.example.com',
        'git:from-image docmost docmost/docmost:latest',
        'letsencrypt:set docmost email me@example.com',
        'letsencrypt:enable docmost',
      ], reason: 'no volume and no host port: zero-downtime deploys stay on');
      expect(p.apps[1].url, 'https://wiki.example.com');
      expect(commandsOf(p.steps).last, 'letsencrypt:cron-job --add');
    });

    test('host ports, other ports beside the web one, and the PORT the file sets', () {
      final f = read('''
services:
  app:
    image: x
    environment: {PORT: "4000"}
    ports: ["8080:4000", "9229:9229", "5000-5001:5000-5001"]
  game:
    image: y
    environment: {PORT: "27015"}
    ports: ["27015:27015/udp", "27015:27015"]
''');
      final c = ComposeChoices(project: 'p', services: {'app', 'game'}, mounts: const {}, exposure: {'game': Exposure.host});
      final p = planCompose(f, c, vhost: 'dokku.test');
      expect(commandsOf(p.apps[0].steps), containsAllInOrder([
        'ports:set p-app http:80:4000',
        'docker-options:add p-app deploy -p 9229:9229',
        'docker-options:add p-app deploy -p 5000-5001:5000-5001',
        'checks:disable p-app web',
      ]));
      expect(commandsOf(p.apps[1].steps), containsAllInOrder([
        'ports:set p-game http:27015:27015',
        'docker-options:add p-game deploy -p 27015:27015/udp',
        'docker-options:add p-game deploy -p 27015:27015',
        'checks:disable p-game web',
        'proxy:disable p-game',
      ]));
      final port = planCompose(f, c.copyWith(ports: {'app': 9229}), vhost: 'dokku.test');
      expect(commandsOf(port.apps[0].steps), containsAllInOrder(['ports:set p-app http:80:9229', 'docker-options:add p-app deploy -p 8080:4000']));
    });

    test('a directory beside the file becomes a storage directory; a file is mounted where it is copied to', () {
      final f = read('''
services:
  web:
    image: nginx
    volumes: ["./site data:/usr/share/nginx/html", "./conf/nginx.conf:/etc/nginx/nginx.conf:ro"]
''');
      final m = f.services.single.mounts;
      final c = ComposeChoices(project: 'site', services: {'web'}, mounts: {for (final x in m) x.id});
      expect(commandsOf(planCompose(f, c, vhost: 'dokku.test').apps.single.steps), containsAllInOrder([
        'storage:ensure-directory --chown false site-site-data',
        'storage:mount site-web /var/lib/dokku/data/storage/site-site-data:/usr/share/nginx/html',
        'storage:mount site-web /var/lib/dokku/data/storage/site-conf-nginx.conf:/etc/nginx/nginx.conf:ro',
      ]));
    });

    test('variables come from what was typed, then the .env beside the file, then a generated value', () {
      final c = choices((c) => c.copyWith(dotenv: 'POSTGRES_PASSWORD=from-dotenv\nAPP_SECRET="quoted"\n', values: {'APP_SECRET': 'typed', 'X': ''}));
      expect(c.effective, {'APP_SECRET': 'typed', 'POSTGRES_PASSWORD': 'from-dotenv'});
      final env = decodeConfig(plan(c).apps[0].steps.firstWhere((s) => s.args.first == 'config:set').args);
      expect(env['POSTGRES_PASSWORD'], 'from-dotenv');
    });

    test('env files: .env is the one pasted for variables, others have their own text', () {
      final f = read('''
services:
  a:
    image: x
    env_file: [.env, ./config/app.env]
    environment: [FROM_SHELL, UNSET, OWN=1]
''');
      final c = ComposeChoices(
          project: 'p',
          services: {'a'},
          mounts: const {},
          dotenv: 'A=1\nOWN=2\nFROM_SHELL=yes',
          envFiles: {'./config/app.env': 'B=2'});
      expect(f.envFilesOf({'a'}), {'.env': ['a'], './config/app.env': ['a']});
      expect(decodeConfig(planCompose(f, c, vhost: 'd.test').apps.single.steps.firstWhere((s) => s.args.first == 'config:set').args),
          {'A': '1', 'OWN': '1', 'FROM_SHELL': 'yes', 'B': '2'}, reason: 'environment wins over env_file; an unset name is left out');
    });

    test('names what blocks the deploy', () {
      final f = read('''
services:
  web: {image: x, ports: ["443:443", "8080:8080"]}
  db: {image: "\${DB_IMAGE:?pick a database image}"}
  build_only: {build: .}
''');
      final c = ComposeChoices(project: 'Bad Name', services: {'web', 'db', 'build_only'}, mounts: const {}, exposure: {'web': Exposure.host});
      expect(composeProblems(f, c, plugins: const {}, apps: const []), [
        'Name the project with lowercase letters, digits and dashes.',
        "web publishes port 443 on the host, which Dokku's proxy holds. Put it on the web, or keep it internal.",
        'Set DB_IMAGE: pick a database image.',
      ], reason: 'a service whose image is a variable stays chosen until it is set');
      expect(composeProblems(read('services: {db: {image: "\${IMG}"}}'), ComposeChoices(project: 'p', services: {'db'}, mounts: const {}),
          plugins: const {}, apps: const []), ['The image of db comes out empty. Set the variables it is made of.']);
      final ok = c.copyWith(project: 'shop', exposure: {'web': Exposure.web}, ports: {'web': 443}, values: {'DB_IMAGE': 'postgres'});
      final g = ComposeSource.parse('''
services:
  web: {image: x, ports: ["443:443", "8080:8080"]}
  db: {image: "\${DB_IMAGE:?pick a database image}"}
  build_only: {build: .}
''').resolve(ok.effective);
      expect(composeProblems(g, ok, plugins: const {}, apps: const ['shop-db']), ['An app named shop-db already exists.'],
          reason: 'with 443 behind the proxy, 8080 alone goes on the host');
      expect(composeProblems(g, ok.copyWith(project: 'bridge'), plugins: const {}, apps: const []),
          ["bridge is one of Docker's own networks. Choose another project name."]);
      expect(composeProblems(g, ok.copyWith(project: 'a' * 60), plugins: const {}, apps: const []).first, contains('too long'));
      expect(composeProblems(g, ok.copyWith(letsencrypt: true, domains: {'web': 'nope'}), plugins: const {}, apps: const []), [
        'That does not look like a domain: nope.',
        'The letsencrypt plugin is not installed.',
        "Let's Encrypt needs an email address.",
      ]);
      expect(composeProblems(g, ok.copyWith(services: {'build_only'}), plugins: const {}, apps: const []), ['Choose at least one service to deploy.']);
    });

    test('two services that would share an app name are caught', () {
      final f = read('services: {my_app: {image: x}, my-app: {image: y}}');
      final c = ComposeChoices(project: 'p', services: {'my_app', 'my-app'}, mounts: const {});
      expect(composeProblems(f, c, plugins: const {}, apps: const []), ['Two services would both be the app p-my-app.']);
    });

    test('a named volume keeps the name the file gives it, and an external one its own', () {
      final f = read('''
services:
  a: {image: x, volumes: ["data:/data", "shared:/shared", "plain:/plain"]}
volumes:
  data: {name: my-data}
  shared: {external: true}
  plain: {}
''');
      expect([for (final m in f.services.single.mounts) composeMountSource(f, 'proj', m)], ['my-data', 'shared', 'proj_plain']);
    });
  });
}
