import 'package:dokku_console/core/format.dart';
import 'package:dokku_console/core/parse.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixtures below are verbatim output captured from Dokku 0.35.20.

const psReport = '''
=====> demo-app ps information
       Deployed:                      true
       Processes:                     2
       Ps can scale:                  true
       Ps restart policy:             on-failure:10
       Restore:                       true
       Running:                       true
       Status web 1:                  running (CID: b0af7e6995f)
       Status web 2:                  exited (CID: 475779320b4)
=====> worker-app ps information
       Deployed:                      false
       Processes:                     0
       Running:                       false
''';

void main() {
  group('parseReports', () {
    test('splits sections per app and lower-cases keys', () {
      final r = parseReports(psReport);
      expect(r.keys, ['demo-app', 'worker-app']);
      expect(r['demo-app']!['deployed'], 'true');
      expect(r['demo-app']!['ps restart policy'], 'on-failure:10');
      expect(r['worker-app']!['processes'], '0');
    });

    test('keeps empty values, trims padding, merges same-named sections', () {
      final r = parseReport('''
=====> demo-app domains information
       Domains app enabled:           true                     
       Domains app vhosts:            demo-app.dokku.test demo.example.com
       Domains global vhosts:         dokku.test               
=====> demo-app git information
       Git source image:                                       
''');
      expect(r['domains app vhosts'], 'demo-app.dokku.test demo.example.com');
      expect(r['domains global vhosts'], 'dokku.test');
      expect(r['git source image'], '');
    });

    test('keeps colons inside values', () {
      final r = parseReport('''
=====> demo-app ports information
       Ports map:                     
       Ports map detected:            http:80:5000 https:443:5000
''');
      expect(r['ports map'], '');
      expect(r['ports map detected'], 'http:80:5000 https:443:5000');
    });

    test('ignores ANSI colour codes', () {
      expect(parseReport('\x1b[1m=====> app ps information\x1b[0m\n       Running:   \x1b[32mtrue\x1b[0m\n')['running'],
          'true');
    });
  });

  group('process status', () {
    final r = parseReports(psReport);
    test('lists containers in order', () {
      expect(procStatuses(r['demo-app']!), const [
        ProcStatus(type: 'web', index: 1, state: 'running', cid: 'b0af7e6995f'),
        ProcStatus(type: 'web', index: 2, state: 'exited', cid: '475779320b4'),
      ]);
    });
    test('derives app health', () {
      expect(appHealth(r['demo-app']), AppHealth.degraded);
      expect(appHealth(r['worker-app']), AppHealth.undeployed);
      expect(appHealth({'deployed': 'true', 'running': 'true', 'status web 1': 'running (CID: abc)'}), AppHealth.running);
      expect(appHealth({'deployed': 'true', 'running': 'false', 'status web 1': 'exited (CID: abc)'}), AppHealth.stopped);
      expect(appHealth(null), AppHealth.stopped);
    });
  });

  test('parseScale reads the scale table', () {
    expect(parseScale('-----> Scaling for demo-app\nproctype: qty\n--------: ---\nweb:  2\nworker:  0\n'),
        {'web': 2, 'worker': 0});
  });

  test('splitDockerOptions splits on option boundaries', () {
    expect(
      splitDockerOptions('--restart=on-failure:10 --shm-size=256m -v /var/lib/dokku/data/storage/demo-data:/app/storage '),
      ['--restart=on-failure:10', '--shm-size=256m', '-v /var/lib/dokku/data/storage/demo-data:/app/storage'],
    );
    expect(splitDockerOptions('--build-arg FOO=bar'), ['--build-arg FOO=bar']);
    expect(splitDockerOptions('   '), isEmpty);
    expect(splitDockerOptions(null), isEmpty);
  });

  group('parseStorage', () {
    test('reads json', () {
      expect(
        parseStorage('[\n  {\n    "host_path": "/var/lib/dokku/data/storage/demo-data",\n    "container_path": "/app/data",\n    "volume_options": ""\n  }\n]'),
        const [Mount(host: '/var/lib/dokku/data/storage/demo-data', container: '/app/data')],
      );
    });
    test('falls back to plain text', () {
      expect(parseStorage('-----> demo-app volume bind-mounts:\n       /srv/a:/app/a\n       /srv/b:/app/b:ro\n'), const [
        Mount(host: '/srv/a', container: '/app/a'),
        Mount(host: '/srv/b', container: '/app/b', options: 'ro'),
      ]);
    });
  });

  group('parseSshKeys', () {
    test('reads json', () {
      final k = parseSshKeys(
          '[{ "fingerprint": "SHA256:8NGt", "name": "tester", "SSHCOMMAND_ALLOWED_KEYS": "no-agent-forwarding", "public-key": "ssh-ed25519 AAAA test" }]');
      expect(k.single.fingerprint, 'SHA256:8NGt');
      expect(k.single.name, 'tester');
      expect(k.single.keyType, 'ssh-ed25519');
      expect(k.single.comment, 'test');
    });
    test('reads the text format', () {
      final k = parseSshKeys('SHA256:8NGt NAME="tester" SSHCOMMAND_ALLOWED_KEYS="no-agent-forwarding,no-user-rc"\n');
      expect(k.single.name, 'tester');
      expect(k.single.allowed, 'no-agent-forwarding,no-user-rc');
    });
  });

  test('parsePlugins separates core from third-party plugins', () {
    final p = parsePlugins('''
plugn: 0.15.0
  00_dokku-standard    0.35.20 enabled    dokku core standard plugin
  scheduler-docker-local 0.35.20 enabled    dokku core scheduler-docker-local plugin
  redis                2.1.0 enabled    dokku redis service plugin
  maintenance          0.8.0 disabled   dokku maintenance plugin
''');
    expect(p.map((x) => x.name), ['00_dokku-standard', 'scheduler-docker-local', 'redis', 'maintenance']);
    expect(p.where((x) => !x.core).map((x) => x.name), ['redis', 'maintenance']);
    expect(p.last.enabled, isFalse);
  });

  group('cron', () {
    test('reads json', () {
      expect(parseCron('[{"id":"abc","app":"a","command":"node x.js","schedule":"@daily"}]'),
          const [CronTask(id: 'abc', schedule: '@daily', command: 'node x.js')]);
      expect(parseCron('[]'), isEmpty);
    });
    test('reads the table', () {
      expect(
        parseCron('ID  Schedule  Command\ncGhw  */15 * * * *  python -m billing.dunning --dry-run=false\nxyz   @daily     node index.js\n'),
        const [
          CronTask(id: 'cGhw', schedule: '*/15 * * * *', command: 'python -m billing.dunning --dry-run=false'),
          CronTask(id: 'xyz', schedule: '@daily', command: 'node index.js'),
        ],
      );
    });
    test('describes schedules', () {
      expect(cronHuman('*/15 * * * *'), 'every 15 min');
      expect(cronHuman('0 3 * * *'), 'daily at 03:00');
      expect(cronHuman('@daily'), 'daily');
      expect(cronHuman('5 4 1 * *'), '5 4 1 * *');
    });
  });

  group('logs and events', () {
    test('parses a docker-local log line with nanoseconds', () {
      final l = parseLogLine('\x1b[36m2026-09-29T11:48:08.123456789Z app[web.1]:\x1b[0m GET /healthz 200 2ms');
      expect(l.proc, 'web.1');
      expect(l.msg, 'GET /healthz 200 2ms');
      expect(l.level, LogLevel.info);
      expect(l.ts, matches(r'^\d\d:\d\d:\d\d$'));
    });
    test('handles CRLF from a PTY stream', () {
      final l = parseLogLine('2026-09-29T11:48:08Z app[web.1]: hello\r');
      expect(l.proc, 'web.1');
      expect(l.msg, 'hello');
    });
    test('classifies severity', () {
      expect(parseLogLine('2026-09-29T11:48:08Z app[web.1]: ERROR ECONNRESET upstream').level, LogLevel.error);
      expect(parseLogLine('2026-09-29T11:48:08Z app[worker.1]: WARN retrying webhook').level, LogLevel.warn);
      expect(parseLogLine(' !     App demo-app has not been deployed').level, LogLevel.error);
    });
    test('keeps unstructured lines', () {
      final l = parseLogLine('-----> Running in ephemeral container');
      expect(l.proc, '');
      expect(l.msg, '-----> Running in ephemeral container');
    });
    test('parses an event line', () {
      final e = parseEvent(
          '2026-09-29T11:05:45.678873+00:00 926f1ed67355 dokku-event[25606]: INVOKED: post-deploy( demo-app 5000 ) NAME=tester FINGERPRINT=SHA256:8NG DOKKU_PID=23490')!;
      expect(e.kind, 'post-deploy');
      expect(e.text, 'demo-app 5000');
      expect(e.user, 'tester');
      expect(e.date, isNotNull);
    });
    test('separates changes from internal triggers', () {
      for (final k in ['post-deploy', 'pre-deploy', 'post-create', 'post-delete', 'post-config-update', 'post-domains-update', 'receive-app', 'post-stop']) {
        expect(isKeyEvent(k), isTrue, reason: k);
      }
      for (final k in ['scheduler-detect', 'config-get', 'proxy-type', 'proxy-is-enabled', 'scheduler-app-status', 'user-auth']) {
        expect(isKeyEvent(k), isFalse, reason: k);
      }
    });
  });

  group('datastores and resources', () {
    test('reads service names', () {
      expect(parseServiceNames('=====> Redis services\ncache\nqueue-2\n'), ['cache', 'queue-2']);
      expect(parseServiceNames('NAME   VERSION      STATUS   EXPOSED PORTS  LINKS\ncache  redis:7.2.4  running  -              demo-app\n'), ['cache']);
      expect(parseServiceNames(' !     There are no Redis services\n'), isEmpty);
    });
    test('groups resource limits by process type', () {
      expect(parseResource({'_default_ limit cpu': '1', '_default_ limit memory': '512m', 'web reserve memory': '128m'}), {
        '_default_': {'limit-cpu': '1', 'limit-memory': '512m'},
        'web': {'reserve-memory': '128m'},
      });
    });
    test('reads a letsencrypt report', () {
      final r = parseLetsencrypt('=====> app letsencrypt information\n       Letsencrypt active:            true\n       Letsencrypt computed email:    ops@example.com\n');
      expect(r['active'], 'true');
      expect(r['computed email'], 'ops@example.com');
    });
  });

  group('env files', () {
    test('parses quoting, comments and export', () {
      final pairs = parseEnvFile('''
# comment
NODE_ENV=production
export PORT=5000
QUOTED="a b # not a comment"
SINGLE='\$HOME stays'
MULTI="line1\\nline2"
TRAILING=value # comment
EMPTY=
not a pair
URL=postgres://u:p@h:5432/db?sslmode=require
''');
      expect(pairs.map((e) => [e.key, e.value]), [
        ['NODE_ENV', 'production'], ['PORT', '5000'], ['QUOTED', 'a b # not a comment'], ['SINGLE', r'$HOME stays'],
        ['MULTI', 'line1\nline2'], ['TRAILING', 'value'], ['EMPTY', ''], ['URL', 'postgres://u:p@h:5432/db?sslmode=require'],
      ]);
    });
    test('guesses which keys hold secrets', () {
      for (final k in ['DATABASE_URL', 'JWT_SIGNING_KEY', 'STRIPE_SECRET_KEY', 'API_TOKEN', 'SMTP_PASSWORD']) {
        expect(isSecretKey(k), isTrue, reason: k);
      }
      for (final k in ['NODE_ENV', 'PORT', 'LOG_LEVEL', 'DOKKU_PROXY_PORT']) {
        expect(isSecretKey(k), isFalse, reason: k);
      }
    });
  });

  test('stripAnsi removes colours, titles and carriage returns', () {
    expect(stripAnsi('\x1b[1G\x1b[33mwarn\x1b[0m\r\nnext\x1b]0;title\x07'), 'warn\nnext');
  });

  test('notSupported recognises a command or flag this Dokku does not have', () {
    expect(notSupported(' !     `builds:list` is not a dokku command.\n !     See `dokku help` for a list of available commands.'), isTrue);
    expect(notSupported(' !     Invalid flag passed, valid flags: --force'), isTrue);
    expect(notSupported('unknown flag: --format'), isTrue);
    // What Dokku 0.35.20 prints for git:unlock, which it lists but no longer has.
    expect(notSupported('/var/lib/dokku/plugins/enabled/git/subcommands/unlock: line 6: cmd-git-unlock: command not found'), isTrue);
    expect(notSupported(' !     App demo-app is not deployed'), isFalse);
    expect(notSupported('bash: npm: command not found'), isFalse, reason: 'a program missing inside the app is a real failure');
    expect(notSupported(''), isFalse);
  });

  test('isNewerVersion compares dotted versions', () {
    expect(isNewerVersion('v0.38.31', '0.35.20'), isTrue);
    expect(isNewerVersion('0.35.20', '0.35.20'), isFalse);
    expect(isNewerVersion('0.35.9', '0.35.20'), isFalse);
    expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion(null, '0.35.20'), isFalse);
    // A version that could not be read must not look out of date.
    expect(isNewerVersion('v0.38.31', ''), isFalse);
    expect(isNewerVersion('v0.38.31', 'unknown'), isFalse);
    expect(isNewerVersion('', '0.35.20'), isFalse);
  });

  test('decodes base64 values and names the ones that are not', () {
    final (:vars, :bad) = decodeEnvValues([
      const MapEntry('A', 'aGVsbG8gd29ybGQ='),
      const MapEntry('B', 'aGk'),
      const MapEntry('C', ''),
      const MapEntry('D', 'not base64!'),
      const MapEntry('E', ' aGk= '),
      const MapEntry('F', 'aGVsbG8-d29ybGQ'),
      const MapEntry('G', 'aGVs\r\nbG8=\n'),
      const MapEntry('H', '/w=='),
    ]);
    expect(vars.map((e) => [e.key, e.value]), [
      ['A', 'hello world'], ['B', 'hi'], ['C', ''], ['E', 'hi'], ['F', 'hello>world'], ['G', 'hello'],
    ]);
    expect(bad, ['D', 'H'], reason: 'garbage, and base64 of bytes that are not text');
  });

  group('format', () {
    final now = DateTime.utc(2026, 9, 29, 12);
    test('relative time from epoch seconds, milliseconds and ISO strings', () {
      expect(ago(now.millisecondsSinceEpoch ~/ 1000 - 120, now: now), '2m ago');
      expect(ago(now.millisecondsSinceEpoch - 7200000, now: now), '2h ago');
      expect(ago('2026-09-27T12:00:00Z', now: now), '2d ago');
      expect(ago('1790679841', now: DateTime.fromMillisecondsSinceEpoch(1790679841000 + 30000)), 'just now');
      expect(ago(null), '—');
    });
    test('reads the certificate date format Dokku prints', () {
      expect(daysUntil('Dec  9 06:24:00 2026 GMT', now: now), 70);
      expect(daysUntil('', now: now), isNull);
    });
    test('sizes and durations', () {
      expect(formatBytes(98 * 1024 * 1024), '98.0 MiB');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(null), '—');
      expect(formatDuration(3567890), '41d 07h');
      expect(formatDuration(3700), '1h 01m');
      expect(formatMs(234), '234 ms');
      expect(formatMs(2400), '2.4s');
    });
  });
}
