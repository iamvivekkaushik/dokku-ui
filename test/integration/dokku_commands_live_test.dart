// Runs every kind of change the app makes against a real Dokku, on throwaway
// apps named e2e-*, through the app's own SSH layer. It shows that the exact
// arguments the screens send are accepted, and that values arrive unchanged.
//
// Skipped unless DOKKU_TEST_KEYS is set. See README, "Testing". The server
// must be able to pull DOKKU_TEST_IMAGE (default traefik/whoami:v1.10).
//
//   DOKKU_TEST_KEYS=/path/to/keys DOKKU_TEST_PORT=3022 flutter test test/integration
@Timeout(Duration(minutes: 45))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dokku_console/core/command.dart';
import 'package:dokku_console/core/parse.dart';
import 'package:dokku_console/core/tar.dart';
import 'package:dokku_console/core/templates.dart';
import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _keys = Platform.environment['DOKKU_TEST_KEYS'];
final _address = Platform.environment['DOKKU_TEST_HOST'] ?? '127.0.0.1';
final _port = int.parse(Platform.environment['DOKKU_TEST_PORT'] ?? '3022');
final _image = Platform.environment['DOKKU_TEST_IMAGE'] ?? 'traefik/whoami:v1.10';

/// An image with sh but no bash, the case Dokku's default shell does not cover.
final _shellImage = Platform.environment['DOKKU_TEST_SHELL_IMAGE'] ?? 'nginx:1.27-alpine';

const _app = 'e2e-app';

Host _host(String user) =>
    Host(id: 'live-$user', name: 'live', host: _address, port: _port, username: user, createdAt: DateTime(2026));

enum _Want {
  /// The command succeeds.
  ok,

  /// This Dokku does not have the command, and says so in a way the app recognises.
  unsupported,

  /// Dokku refuses, and the refusal is what is being checked.
  refused,

  /// Either outcome is fine: tidying up, or something the test server cannot do.
  any,
}

class _Step {
  const _Step(this.args, {this.user = 'dokku', this.stdin, this.want = _Want.ok, this.then, this.says});
  final List<String> args;
  final String user;
  final List<int>? stdin;
  final _Want want;

  /// A lookup that must show the change: its arguments and what its output has.
  final (List<String>, Object)? then;

  /// Text the output of the command itself must have.
  final Pattern? says;
}

/// A lookup whose JSON output has [key] set to exactly [value].
class _JsonValue {
  const _JsonValue(this.key, this.value);
  final String key;
  final String value;

  bool holds(String text) {
    try {
      return (jsonDecode(text.trim()) as Map)[key] == value;
    } on Object {
      return false;
    }
  }

  @override
  String toString() => '$key = ${jsonEncode(value)}';
}

/// Output that does not mention [text].
class _Without {
  const _Without(this.text);
  final String text;
  @override
  String toString() => 'no "$text"';
}

String _b64(String v) => base64.encode(utf8.encode(v));

Future<bool> _has(String program) async {
  try {
    return (await Process.run('which', [program])).exitCode == 0;
  } on Object {
    return false;
  }
}

void main() {
  final skip = _keys == null ? 'set DOKKU_TEST_KEYS to run against a live server' : null;
  late SshService ssh;
  late Directory scratch;

  setUpAll(() async {
    if (skip != null) return;
    ssh = SshService(loadSecrets: (_) async => HostSecrets(privateKey: File('$_keys/test').readAsStringSync()));
    scratch = await Directory.systemTemp.createTemp('dkc-live-');
  });

  tearDownAll(() async {
    if (skip != null) return;
    // Whatever happened above, nothing of this run is left on the server.
    for (final args in [
      ['--force', 'apps:destroy', _app],
      ['--force', 'apps:destroy', 'e2e-clone'],
      ['--force', 'apps:destroy', 'e2e-renamed'],
      ['--force', 'apps:destroy', 'e2e-shell'],
      ['--force', 'apps:destroy', 'e2e-store'],
      ['--force', 'apps:destroy', 'e2e-n8n'],
      ['--force', 'apps:destroy', 'e2e-rustdesk'],
      ['redis:destroy', 'e2e-cache', '--force'],
      ['network:destroy', '--force', 'e2e-net'],
    ]) {
      await ssh.dokku(_host('dokku'), args, timeout: const Duration(minutes: 5));
    }
    await ssh.dokku(_host('root'), ['ssh-keys:remove', 'e2e-key']);
    // Storage directories, also the ones a docker-in-docker host daemon made on its side.
    await ssh.exec(_host('root'), 'rm -rf /var/lib/dokku/data/storage/e2e-store-data /var/lib/dokku/data/storage/e2e-n8n-data /var/lib/dokku/data/storage/e2e-rustdesk-data');
    await ssh.exec(_host('root'), "docker run --rm -v /var/lib/dokku/data/storage:/s alpine:3.20 sh -c 'rm -rf /s/e2e-store-data /s/e2e-n8n-data /s/e2e-rustdesk-data'");
    ssh.dispose();
    await scratch.delete(recursive: true);
  });

  Future<void> run(List<_Step> steps) async {
    final problems = <String>[];
    for (final s in steps) {
      final h = _host(s.user);
      final r = await ssh.dokku(h, s.args, stdin: s.stdin, timeout: const Duration(minutes: 10));
      final out = stripAnsi(r.output);
      final shown = displayCommand(s.args);
      final good = switch (s.want) {
        _Want.ok => r.ok,
        _Want.unsupported => !r.ok && notSupported(r.output),
        _Want.refused => !r.ok,
        _Want.any => true,
      };
      if (!good) {
        problems.add('$shown as ${s.user}: wanted ${s.want.name}, exited ${r.code}\n$out');
        continue;
      }
      if (s.says != null && !out.contains(s.says!)) problems.add('$shown: expected its output to have ${s.says}\n$out');

      if (s.then case (final args, final expected)?) {
        final c = await ssh.dokku(h, args);
        final seen = stripAnsi(c.output);
        final holds = switch (expected) {
          final _JsonValue j => j.holds(c.stdout),
          final _Without w => !seen.contains(w.text),
          final Pattern p => seen.contains(p),
          _ => false,
        };
        if (!holds) problems.add('$shown: expected $expected in ${args.join(' ')}\n$seen');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n\n'));
  }

  // The groups share one throwaway app, so they run in this order.
  test('creates, locks and unlocks an app', () async {
    await run([
      const _Step(['--force', 'apps:destroy', _app], want: _Want.any),
      const _Step(['apps:create', _app], then: (['--quiet', 'apps:list'], _app)),
      _Step(const ['apps:lock', _app], then: (const ['apps:report', _app], RegExp(r'App locked:\s+true'))),
      _Step(const ['apps:unlock', _app], then: (const ['apps:report', _app], RegExp(r'App locked:\s+false'))),
      // Unlocking an app that is not locked fails; the app explains that outcome.
      const _Step(['apps:unlock', _app], want: _Want.refused, says: 'Unable to remove deploy lock'),
    ]);
  }, skip: skip);

  test('config values arrive exactly as typed', () async {
    const awkward = 'line one\nline "two" \$HOME `id` \'quoted\' & | ; \\ end';
    await run([
      _Step(['config:set', '--encoded', '--no-restart', _app, 'PLAIN=${_b64('value')}', 'AWKWARD=${_b64(awkward)}'],
          then: (const ['config:export', '--format', 'json', _app], const _JsonValue('AWKWARD', awkward))),
      const _Step(['config:unset', '--no-restart', _app, 'PLAIN'],
          then: (['config:export', '--format', 'json', _app], _Without('PLAIN'))),
    ]);
  }, skip: skip);

  test('deploys an image and sets git options', () async {
    await run([
      _Step(const ['git:set', _app, 'deploy-branch', 'main'],
          then: (const ['git:report', _app], RegExp(r'Git deploy branch:\s+main'))),
      const _Step(['git:set', _app, 'keep-git-dir', 'true']),
      const _Step(['git:set', _app, 'keep-git-dir', 'false']),
      _Step(['git:from-image', _app, _image], then: (const ['ps:report', _app], RegExp(r'Deployed:\s+true'))),
      const _Step(['ps:rebuild', _app]),
    ]);
  }, skip: skip);

  test('commands this Dokku may lack are recognised as such', () async {
    final version = RegExp(r'(\d+)\.(\d+)').firstMatch((await ssh.dokku(_host('dokku'), ['version'])).stdout);
    final minor = int.parse(version?[2] ?? '0');
    final old = version?[1] == '0' && minor < 38;
    await run([
      // Folded into apps:unlock in newer versions; the app then runs that.
      const _Step(['git:unlock', _app, '--force'], want: _Want.any),
      if (old) ...const [
        _Step(['builds:list', _app, '--format', 'json'], want: _Want.unsupported),
        _Step(['registry:logout', 'ghcr.io'], want: _Want.unsupported),
      ],
    ]);
    final unlock = await ssh.dokku(_host('dokku'), ['git:unlock', _app, '--force']);
    expect(unlock.ok || notSupported(unlock.output), isTrue, reason: unlock.output);
  }, skip: skip);

  test('sets the builder, its options and buildpacks', () async {
    const node = 'https://github.com/heroku/heroku-buildpack-nodejs.git';
    const ruby = 'https://github.com/heroku/heroku-buildpack-ruby.git';
    await run([
      _Step(const ['builder:set', _app, 'selected', 'dockerfile'],
          then: (const ['builder:report', _app], RegExp(r'Builder selected:\s+dockerfile'))),
      // Without a value the setting is cleared, which is how "auto" is chosen.
      _Step(const ['builder:set', _app, 'selected'], then: (const ['builder:report', _app], RegExp(r'Builder selected:\s*\n'))),
      const _Step(['builder-dockerfile:set', _app, 'dockerfile-path', 'docker/Dockerfile']),
      const _Step(['builder-dockerfile:set', _app, 'dockerfile-path']),
      const _Step(['builder:set', _app, 'build-dir', 'services/api']),
      const _Step(['builder:set', _app, 'build-dir']),
      const _Step(['buildpacks:add', _app, node]),
      _Step(const ['buildpacks:add', '--index', '1', _app, ruby],
          then: (const ['buildpacks:report', _app], RegExp('Buildpacks list:\\s+$ruby,$node'))),
      // Moving one up is two writes.
      const _Step(['buildpacks:set', '--index', '1', _app, node]),
      _Step(const ['buildpacks:set', '--index', '2', _app, ruby],
          then: (const ['buildpacks:report', _app], RegExp('Buildpacks list:\\s+$node,$ruby'))),
      const _Step(['buildpacks:remove', _app, ruby]),
      _Step(const ['buildpacks:clear', _app], then: (const ['buildpacks:report', _app], RegExp(r'Buildpacks list:\s*\n'))),
    ]);
  }, skip: skip);

  test('scales, restarts and limits processes', () async {
    await run([
      _Step(const ['ps:scale', _app, 'web=2'], then: (const ['ps:scale', _app], RegExp(r'web:\s+2'))),
      const _Step(['ps:scale', _app, 'web=1']),
      const _Step(['ps:stop', _app]),
      const _Step(['ps:start', _app]),
      const _Step(['ps:restart', _app]),
      _Step(const ['ps:set', _app, 'restart-policy', 'always'],
          then: (const ['ps:report', _app], RegExp(r'Ps restart policy:\s+always'))),
      const _Step(['ps:set', _app, 'restart-policy', 'on-failure:10']),
      const _Step(['resource:limit', '--cpu', '1', '--memory', '256m', _app]),
      _Step(const ['resource:reserve', '--memory', '128m', _app],
          then: (const ['resource:report', _app], RegExp(r'_default_ reserve memory:\s+128m'))),
      // Taking one limit away: clear the defaults, then set the others again.
      const _Step(['resource:limit-clear', '--process-type', '_default_', _app]),
      _Step(const ['resource:limit', '--memory', '256m', _app],
          then: (const ['resource:report', _app], RegExp(r'_default_ limit memory:\s+256m\n\s+_default_ reserve'))),
      const _Step(['resource:limit-clear', _app]),
      _Step(const ['resource:reserve-clear', _app], then: (const ['resource:report', _app], RegExp(r'information\s*$'))),
      _Step(const ['checks:disable', _app, 'web'],
          then: (const ['checks:report', _app], RegExp(r'Checks disabled list:\s+web'))),
      _Step(const ['checks:skip', _app, 'web'], then: (const ['checks:report', _app], RegExp(r'Checks skipped list:\s+web'))),
      _Step(const ['checks:enable', _app, 'web'],
          then: (const ['checks:report', _app], RegExp(r'Checks disabled list:\s+none'))),
      const _Step(['checks:run', _app]),
      _Step(const ['scheduler:set', _app, 'selected', 'docker-local'],
          then: (const ['scheduler:report', _app], RegExp(r'Scheduler selected:\s+docker-local'))),
      const _Step(['cron:list', _app, '--format', 'json']),
    ]);
  }, skip: skip);

  test('an emptied resource field is ignored by Dokku, which is why the app clears first', () async {
    await run([
      const _Step(['resource:limit', '--cpu', '2', _app]),
      _Step(const ['resource:limit', '--cpu', '', _app], then: (const ['resource:report', _app], RegExp(r'_default_ limit cpu:\s+2'))),
      const _Step(['resource:limit-clear', _app]),
    ]);
  }, skip: skip);

  test('domains, ports, proxy and nginx settings', () async {
    await run([
      const _Step(['domains:add', _app, 'e2e.example.com'], then: (['domains:report', _app], 'e2e.example.com')),
      _Step(const ['ports:add', _app, 'http:8080:80'],
          then: (const ['ports:report', _app], RegExp(r'Ports map:\s+.*http:8080:80'))),
      const _Step(['ports:remove', _app, 'http:8080:80']),
      const _Step(['nginx:set', _app, 'hsts', 'false']),
      _Step(const ['proxy:build-config', _app], then: (const ['nginx:report', _app], RegExp(r'Nginx hsts:\s+false'))),
      const _Step(['nginx:set', _app, 'hsts-include-subdomains', 'true']),
      const _Step(['nginx:set', _app, 'hsts-preload', 'false']),
      _Step(const ['proxy:disable', _app], then: (const ['proxy:report', _app], RegExp(r'Proxy enabled:\s+false'))),
      const _Step(['proxy:enable', _app]),
      _Step(const ['proxy:set', _app, 'nginx'], then: (const ['proxy:report', _app], RegExp(r'Proxy type:\s+nginx'))),
      const _Step(['domains:remove', _app, 'e2e.example.com'], then: (['domains:report', _app], _Without('e2e.example.com'))),
    ]);
  }, skip: skip);

  test('a port mapping that was only detected cannot be removed', () async {
    final report = stripAnsi((await ssh.dokku(_host('dokku'), ['ports:report', _app])).stdout);
    final detected = RegExp(r'Ports map detected:\s+(\S+)').firstMatch(report)?[1];
    if (detected == null || RegExp(r'Ports map:\s+\S').hasMatch(report)) return;
    await run([
      _Step(['ports:remove', _app, detected], want: _Want.any, then: (const ['ports:report', _app], 'Ports map detected:       '.trim())),
    ]);
    final after = stripAnsi((await ssh.dokku(_host('dokku'), ['ports:report', _app])).stdout);
    expect(after, contains(detected), reason: 'which is why the app offers no remove button for it');
  }, skip: skip);

  test('uploads a certificate as an archive on standard input', () async {
    if (!await _has('openssl')) return markTestSkipped('openssl is needed to make a certificate');
    final made = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
      '-keyout', '${scratch.path}/server.key', '-out', '${scratch.path}/server.crt',
      '-subj', '/CN=e2e.example.com', '-addext', 'subjectAltName=DNS:e2e.example.com',
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final archive = makeTar({
      'server.crt': File('${scratch.path}/server.crt').readAsStringSync(),
      'server.key': File('${scratch.path}/server.key').readAsStringSync(),
    });
    await run([
      _Step(const ['certs:add', _app], stdin: archive, then: (const ['certs:report', _app], RegExp(r'Ssl enabled:\s+true'))),
      _Step(const ['certs:report', _app], says: 'e2e.example.com'),
      _Step(const ['certs:remove', _app], then: (const ['certs:report', _app], RegExp(r'Ssl enabled:\s+false'))),
    ]);
  }, skip: skip);

  test('storage, docker options and networks', () async {
    const mount = '/var/lib/dokku/data/storage/e2e-data:/data';
    await run([
      const _Step(['storage:ensure-directory', 'e2e-data']),
      const _Step(['storage:ensure-directory', '--chown', 'heroku', 'e2e-data']),
      const _Step(['storage:ensure-directory', '--chown', 'paketo', 'e2e-data']),
      const _Step(['storage:mount', _app, mount],
          then: (['storage:list', _app, '--format', 'json'], '/var/lib/dokku/data/storage/e2e-data')),
      const _Step(['storage:unmount', _app, mount],
          then: (['storage:list', _app, '--format', 'json'], _Without('e2e-data'))),
      const _Step(['docker-options:add', _app, 'deploy', '--shm-size=64m'],
          then: (['docker-options:report', _app], '--shm-size=64m')),
      // One argument although it has a space in it.
      const _Step(['docker-options:add', _app, 'run', '--env FOO=a b'], then: (['docker-options:report', _app], '--env FOO=a b')),
      const _Step(['docker-options:remove', _app, 'run', '--env FOO=a b']),
      const _Step(['docker-options:remove', _app, 'deploy', '--shm-size=64m'],
          then: (['docker-options:report', _app], _Without('--shm-size=64m'))),
      const _Step(['network:destroy', '--force', 'e2e-net'], want: _Want.any),
      const _Step(['network:create', 'e2e-net'], then: (['network:list'], 'e2e-net')),
      _Step(const ['network:set', _app, 'attach-post-create', 'e2e-net'],
          then: (const ['network:report', _app], RegExp(r'Network attach post create:\s+e2e-net'))),
      _Step(const ['network:set', _app, 'attach-post-create'],
          then: (const ['network:report', _app], RegExp(r'Network attach post create:\s*\n'))),
      const _Step(['network:set', _app, 'bind-all-interfaces', 'true']),
      const _Step(['network:set', _app, 'bind-all-interfaces', 'false']),
      const _Step(['network:destroy', '--force', 'e2e-net'], want: _Want.any),
    ]);
  }, skip: skip);

  test('registry settings, clone, rename and destroy', () async {
    await run([
      const _Step(['registry:set', _app, 'push-on-release', 'true']),
      const _Step(['registry:set', _app, 'push-on-release', 'false']),
      _Step(const ['registry:set', _app, 'server', 'ghcr.io'],
          then: (const ['registry:report', _app], RegExp(r'Registry server:\s+ghcr.io'))),
      const _Step(['registry:set', _app, 'image-repo', 'acme/e2e']),
      const _Step(['registry:set', _app, 'server']),
      _Step(const ['registry:set', _app, 'image-repo'],
          then: (const ['registry:report', _app], RegExp(r'Registry image repo:\s*\n'))),
      const _Step(['--force', 'apps:destroy', 'e2e-clone'], want: _Want.any),
      const _Step(['--force', 'apps:destroy', 'e2e-renamed'], want: _Want.any),
      const _Step(['apps:clone', _app, 'e2e-clone'], then: (['--quiet', 'apps:list'], 'e2e-clone')),
      const _Step(['apps:rename', 'e2e-clone', 'e2e-renamed'], then: (['--quiet', 'apps:list'], 'e2e-renamed')),
      const _Step(['--force', 'apps:destroy', 'e2e-renamed'], then: (['--quiet', 'apps:list'], _Without('e2e-renamed'))),
    ]);
  }, skip: skip);

  test('enter opens a shell in a running container', () async {
    await run([
      const _Step(['--force', 'apps:destroy', 'e2e-shell'], want: _Want.any),
      const _Step(['apps:create', 'e2e-shell']),
      _Step(['git:from-image', 'e2e-shell', _shellImage], then: (const ['ps:report', 'e2e-shell'], RegExp(r'Deployed:\s+true'))),
    ]);

    Future<(String, StreamExit)> session(List<String> args, {List<String> type = const []}) async {
      final out = StringBuffer();
      final s = await ssh.dokkuStream(_host('dokku'), args, pty: const Pty(), onData: (c, _) => out.write(c));
      for (final line in type) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        s.write('$line\n');
      }
      final exit = await s.done.timeout(const Duration(seconds: 30));
      return (stripAnsi('$out'), exit);
    }

    // A fourth argument is a command to run, which is why the app sends web.1 as one word.
    final (wrong, wrongExit) = await session(['enter', 'e2e-shell', 'web', '1']);
    expect(wrongExit.code, isNot(0));
    expect(wrong, contains('exec: "1"'));

    // Dokku starts bash, which this image lacks; the terminal recognises this and opens sh.
    final (noBash, noBashExit) = await session(['enter', 'e2e-shell', 'web.1']);
    expect(noBashExit.code, isNot(0));
    expect(missingProgram.firstMatch(noBash)?.group(1), '/bin/bash');

    final (shell, shellExit) = await session(['enter', 'e2e-shell', 'web.1', 'sh'], type: ['echo hi-\$((20+22))', 'exit']);
    expect(shell, contains('hi-42'));
    expect(shellExit.code, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  /// Runs every step of a Store install the way the app does, without a screen.
  Future<void> installPlan(InstallPlan plan) async {
    final h = _host('dokku');
    for (final step in plan.steps) {
      final r = await ssh.dokku(h, step.args, timeout: const Duration(minutes: 15));
      if (!r.ok && step.quiet) continue;
      expect(r.ok, isTrue, reason: '${displayCommand(step.args)} exited ${r.code}\n${stripAnsi(r.output)}');
      if (step is LinkStep && step.service.env.isNotEmpty) {
        final url = await ssh.dokku(h, ['config:get', plan.app, step.service.from]);
        final set = await ssh.dokku(h, configSetArgs(plan.app, step.derive(url.stdout)));
        expect(set.ok, isTrue, reason: stripAnsi(set.output));
      }
    }
  }

  /// In the throwaway container, app containers run on the host's daemon, which
  /// mounts storage from its own filesystem, root-owned, where Dokku's chown never
  /// happened. Gives that directory the owner the image runs as; on a real host
  /// this repeats what storage:ensure-directory did.
  Future<void> prepareStorage(String dir, String owner) =>
      ssh.exec(_host('root'), 'docker run --rm -v /var/lib/dokku/data/storage/$dir:/m alpine:3.20 chown $owner /m');

  Future<String> inApp(String app, String command) async =>
      (await ssh.exec(_host('root'), 'docker exec \$(docker ps -q --filter name=$app.web.1) $command')).stdout;

  Future<String> httpStatus(String domain, [String path = '/']) async {
    final r = await ssh.exec(_host('root'), 'curl -s -o /dev/null -w "%{http_code}" -H "Host: $domain" http://127.0.0.1$path');
    return r.stdout.trim();
  }

  test('installs a Store template end to end', () async {
    // The suite's image stands in for a real app; the commands are the planner's.
    final colon = _image.lastIndexOf(':');
    final (image, tag) = colon > _image.lastIndexOf('/') ? (_image.substring(0, colon), _image.substring(colon + 1)) : (_image, 'latest');
    final t = AppTemplate(
      id: 'e2e-store',
      name: 'Store probe',
      category: 'Test',
      tagline: 'A template made of the test image.',
      description: '',
      homepage: 'https://example.com',
      image: image,
      tags: [tag],
      port: 80,
      glyph: 'sp',
      hue: 0xFFFFFFFF,
      mounts: const [TemplateMount('/data', name: 'data', what: 'data')],
      env: const {'WHOAMI_NAME': '{app} at {url}'},
      settings: const [TemplateSetting(['PROBE'], 'Probe', value: 'x y')],
      secrets: const ['PROBE_SECRET'],
      notes: 'Open {url}.',
    );
    final plan = planInstall(t, defaultChoices(t).copyWith(domain: 'probe.dokku.test', memory: '256m'), defaultDomain: 'e2e-store.dokku.test');
    await installPlan(plan);

    final h = _host('dokku');
    Future<String> out(List<String> args) async => stripAnsi((await ssh.dokku(h, args)).stdout);
    expect(await out(['ps:report', 'e2e-store']), contains(RegExp(r'Deployed:\s+true')));
    expect(await out(['ports:report', 'e2e-store']), contains(RegExp(r'Ports map:\s+http:80:80')));
    expect(await out(['storage:list', 'e2e-store']), contains('/var/lib/dokku/data/storage/e2e-store-data:/data'));
    expect(await out(['domains:report', 'e2e-store']), contains(RegExp(r'Domains app vhosts:\s+probe\.dokku\.test')));
    expect((await out(['config:get', 'e2e-store', 'WHOAMI_NAME'])).trim(), 'e2e-store at http://probe.dokku.test');
    expect((await out(['config:get', 'e2e-store', 'PROBE'])).trim(), 'x y');
    expect((await out(['config:get', 'e2e-store', 'PROBE_SECRET'])).trim(), plan.env['PROBE_SECRET']);
    expect(await out(['resource:report', 'e2e-store']), contains('256m'));
    expect(await httpStatus('probe.dokku.test'), '200', reason: 'the app answers on its domain through the proxy');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  // Pulls the real n8n image, so it only runs when asked for.
  test('the n8n template comes up and answers', () async {
    final t = templateOf('n8n')!;
    final plan = planInstall(t, defaultChoices(t).copyWith(app: 'e2e-n8n'), defaultDomain: 'e2e-n8n.dokku.test');
    await prepareStorage('e2e-n8n-data', '1000:1000');
    await installPlan(plan);
    var status = '';
    for (var i = 0; i < 45 && status != '200'; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      status = await httpStatus('e2e-n8n.dokku.test', '/healthz');
    }
    expect(status, '200', reason: 'n8n should answer /healthz through the proxy');
    expect(await inApp('e2e-n8n', 'ls /home/node/.n8n'), contains('config'), reason: 'n8n wrote its config to the mounted directory');
  }, skip: skip ?? (Platform.environment['DOKKU_TEST_STORE'] == null ? 'set DOKKU_TEST_STORE=1 to pull and run n8n' : null),
      timeout: const Timeout(Duration(minutes: 20)));

  test('the RustDesk template publishes its ports without the proxy', () async {
    final t = templateOf('rustdesk')!;
    final plan = planInstall(t, defaultChoices(t).copyWith(app: 'e2e-rustdesk'), defaultDomain: 'e2e-rustdesk.dokku.test');
    await installPlan(plan);
    final h = _host('dokku');
    expect(stripAnsi((await ssh.dokku(h, ['ps:report', 'e2e-rustdesk'])).stdout), contains(RegExp(r'Running:\s+true')));
    expect(stripAnsi((await ssh.dokku(h, ['proxy:report', 'e2e-rustdesk'])).stdout), contains(RegExp(r'Proxy enabled:\s+false')));
    final ports = await ssh.exec(_host('root'), 'docker port \$(docker ps -q --filter name=e2e-rustdesk.web.1)');
    for (final p in ['21115/tcp -> 0.0.0.0:21115', '21116/tcp -> 0.0.0.0:21116', '21116/udp -> 0.0.0.0:21116', '21117/tcp -> 0.0.0.0:21117', '21119/tcp -> 0.0.0.0:21119']) {
      expect(ports.stdout, contains(p), reason: 'published on the host');
    }
    // hbbs writes its key pair to the mounted directory on first start.
    var keys = '';
    for (var i = 0; i < 15 && !keys.contains('id_ed25519.pub'); i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      keys = await inApp('e2e-rustdesk', 'ls /data');
    }
    expect(keys, contains('id_ed25519.pub'));
  }, skip: skip ?? (Platform.environment['DOKKU_TEST_STORE'] == null ? 'set DOKKU_TEST_STORE=1 to run the RustDesk server' : null),
      timeout: const Timeout(Duration(minutes: 10)));

  test('runs a one-off command in the background', () async {
    await run([
      _Step(const ['run:detached', _app, '/whoami', '--port', '9999'],
          then: (const ['run:list', _app], RegExp('$_app\\.run\\.\\d+'))),
      const _Step(['run:stop', _app], want: _Want.any),
    ]);
  }, skip: skip);

  test('datastore services', () async {
    final plugins = await ssh.dokku(_host('dokku'), ['plugin:list']);
    if (!RegExp(r'^\s*redis\s+\S+\s+enabled', multiLine: true).hasMatch(plugins.stdout)) {
      return markTestSkipped('the redis plugin is not installed on this server');
    }
    await run([
      const _Step(['redis:destroy', 'e2e-cache', '--force'], want: _Want.any),
      // Where the Docker daemon is not the server's own the container cannot
      // start and this fails, but the service is still recorded.
      const _Step(['redis:create', 'e2e-cache'], want: _Want.any, then: (['redis:list'], 'e2e-cache')),
      _Step(const ['redis:link', 'e2e-cache', _app], then: (const ['redis:info', 'e2e-cache'], RegExp('Links:\\s+$_app'))),
      const _Step(['config:export', '--format', 'json', _app], says: 'REDIS_URL'),
      const _Step(['redis:unlink', 'e2e-cache', _app]),
      const _Step(['redis:expose', 'e2e-cache', '16379'], want: _Want.any),
      const _Step(['redis:unexpose', 'e2e-cache'], want: _Want.any),
      const _Step(['redis:stop', 'e2e-cache'], want: _Want.any),
      const _Step(['redis:start', 'e2e-cache'], want: _Want.any),
      const _Step(['redis:backup-auth', 'e2e-cache', 'AKIAEXAMPLE', 'not-a-real-secret', 'us-east-1', 'v4', 'https://s3.example.com']),
      const _Step(['redis:backup-schedule', 'e2e-cache', '0 2 * * *', 'e2e-bucket'], want: _Want.any),
      const _Step(['redis:backup-unschedule', 'e2e-cache'], want: _Want.any),
      const _Step(['redis:destroy', 'e2e-cache', '--force'], then: (['redis:list'], _Without('e2e-cache'))),
    ]);
  }, skip: skip);

  test('SSH keys and plugins need root, and work as root', () async {
    if (!await _has('ssh-keygen')) return markTestSkipped('ssh-keygen is needed to make a key');
    final made = await Process.run('ssh-keygen', ['-t', 'ed25519', '-N', '', '-C', 'e2e@live', '-q', '-f', '${scratch.path}/e2e_key']);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final publicKey = utf8.encode(File('${scratch.path}/e2e_key.pub').readAsStringSync());
    await run([
      const _Step(['ssh-keys:remove', 'e2e-key'], user: 'root', want: _Want.any),
      _Step(const ['ssh-keys:add', 'e2e-key'], stdin: publicKey, want: _Want.refused, says: 'must be run as root'),
      _Step(const ['ssh-keys:add', 'e2e-key'], user: 'root', stdin: publicKey, then: (const ['ssh-keys:list', '--format', 'json'], 'e2e-key')),
      const _Step(['ssh-keys:remove', 'e2e-key'], user: 'root', then: (['ssh-keys:list', '--format', 'json'], _Without('e2e-key'))),
      const _Step(['plugin:install', 'https://github.com/dokku/dokku-letsencrypt.git'], want: _Want.refused, says: 'must be run as root'),
    ]);
  }, skip: skip);

  test('server-wide settings', () async {
    final before = words(parseReport((await ssh.dokku(_host('dokku'), ['domains:report', '--global'])).stdout)['domains global vhosts']);
    await run([
      const _Step(['domains:set-global', 'e2e-one.example.com', 'e2e-two.example.com'],
          then: (['domains:report', '--global'], 'e2e-two.example.com')),
      if (before.isNotEmpty) _Step(['domains:set-global', ...before], then: (const ['domains:report', '--global'], before.first)),
      const _Step(['events:on']),
    ]);
  }, skip: skip);

  test('destroys the app', () async {
    await run([
      const _Step(['--force', 'apps:destroy', _app], then: (['--quiet', 'apps:list'], _Without(_app))),
    ]);
  }, skip: skip);
}
