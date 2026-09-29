// Runs against a real SSH server with Dokku. Skipped unless DOKKU_TEST_KEYS
// points at a directory holding the test keys. See README, "Testing".
//
//   DOKKU_TEST_KEYS=/path/to/keys DOKKU_TEST_PORT=3022 flutter test test/integration
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dokku_console/data/models.dart';
import 'package:dokku_console/data/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _keys = Platform.environment['DOKKU_TEST_KEYS'];
final _address = Platform.environment['DOKKU_TEST_HOST'] ?? '127.0.0.1';
final _port = int.parse(Platform.environment['DOKKU_TEST_PORT'] ?? '3022');

String key(String name) => File('$_keys/$name').readAsStringSync();

Host host({String user = 'dokku', String id = 'h1', int? port, String? hostKey, AuthMethod auth = AuthMethod.key, String? keyPath}) => Host(
    id: id, name: 'test', host: _address, port: port ?? _port, username: user, auth: auth, keyPath: keyPath, hostKey: hostKey, createdAt: DateTime(2026));

SshService service({String keyName = 'test', String? passphrase, void Function(String type, String fp)? onPin}) => SshService(
      loadSecrets: (_) async => HostSecrets(privateKey: key(keyName), passphrase: passphrase),
      readKeyFile: (p) => File(p).readAsString(),
      pinHostKey: (_, type, fp) async => onPin?.call(type, fp),
    );

void main() {
  final skip = _keys == null ? 'set DOKKU_TEST_KEYS to run against a live server' : null;

  group('connection test', () {
    test('reports every step for the dokku user', () async {
      final steps = await service().test(host(), HostSecrets(privateKey: key('test'))).toList();
      final last = {for (final s in steps) s.step: s};
      expect(last.keys, [0, 1, 2, 3]);
      expect(last.values.map((s) => s.status), everyElement(StepStatus.ok));
      expect(last[1]!.hostKey, startsWith('SHA256:'));
      expect(last[3]!.dokkuVersion, matches(r'^\d+\.\d+\.\d+$'));
    }, skip: skip);

    test('works for root', () async {
      final steps = await service().test(host(user: 'root'), HostSecrets(privateKey: key('test'))).toList();
      expect(steps.last.status, StepStatus.ok);
      expect(steps.last.dokkuVersion, isNotNull);
    }, skip: skip);

    test('accepts an RSA key', () async {
      final steps = await service().test(host(), HostSecrets(privateKey: key('test_rsa'))).toList();
      expect(steps.last.status, StepStatus.ok);
    }, skip: skip);

    test('accepts a passphrase-protected key', () async {
      final steps = await service().test(host(), HostSecrets(privateKey: key('test_enc'), passphrase: 'correct horse')).toList();
      expect(steps.last.status, StepStatus.ok);
    }, skip: skip);

    test('explains a wrong or missing passphrase', () async {
      final wrong = await service().test(host(), HostSecrets(privateKey: key('test_enc'), passphrase: 'nope')).toList();
      expect(wrong.last.status, StepStatus.fail);
      expect(wrong.last.step, 2);
      expect(wrong.last.text, contains('passphrase'));
      final missing = await service().test(host(), HostSecrets(privateKey: key('test_enc'))).toList();
      expect(missing.last.status, StepStatus.fail);
      expect(missing.last.text, contains('passphrase'));
    }, skip: skip);

    test('explains a key the server does not know', () async {
      final steps = await service().test(host(), HostSecrets(privateKey: key('unknown'))).toList();
      expect(steps.last.status, StepStatus.fail);
      expect(steps.last.step, 2);
      expect(steps.last.text, contains('rejected this key'));
    }, skip: skip);

    test('explains garbage instead of a key', () async {
      final steps = await service().test(host(), const HostSecrets(privateKey: 'not a key')).toList();
      expect(steps.last.status, StepStatus.fail);
      expect(steps.last.text, contains('private key'));
    }, skip: skip);

    test('reads a key from a file path', () async {
      final steps = await service().test(host(auth: AuthMethod.keyFile, keyPath: '$_keys/test'), const HostSecrets()).toList();
      expect(steps.last.status, StepStatus.ok);
    }, skip: skip);

    test('refuses a changed host key', () async {
      final steps = await service().test(host(hostKey: 'SHA256:notTheRealKey'), HostSecrets(privateKey: key('test'))).toList();
      expect(steps.last.status, StepStatus.fail);
      expect(steps.last.step, 1);
      expect(steps.last.text, 'host key changed');
      expect(steps.last.detail, contains('SHA256:notTheRealKey'));
      expect(steps.last.presentedKey, startsWith('SHA256:'));
      expect(steps.last.presentedKey, isNot('SHA256:notTheRealKey'));

      // Accepting the key that was presented is what "Trust new key" does.
      final again = await service().test(host(), HostSecrets(privateKey: key('test'))).toList();
      expect(again.last.status, StepStatus.ok);
      expect(again.last.hostKey, steps.last.presentedKey);
    }, skip: skip);

    test('explains an unreachable port', () async {
      final steps = await service().test(host(port: 1), HostSecrets(privateKey: key('test'))).toList();
      expect(steps.last.status, StepStatus.fail);
      expect(steps.last.step, 0);
      expect(steps.last.text, contains('Could not reach'));
    }, skip: skip);
  });

  group('commands', () {
    late SshService ssh;
    setUp(() => ssh = service());
    tearDown(() => ssh.dispose());

    test('runs a dokku command and pins the host key', () async {
      String? pinned;
      ssh.dispose();
      ssh = service(onPin: (_, fp) => pinned = fp);
      final r = await ssh.dokku(host(), ['--quiet', 'apps:list']);
      expect(r.code, 0);
      expect(r.stdout.split('\n'), contains('demo-app'));
      expect(r.command, 'dokku --quiet apps:list');
      expect(pinned, startsWith('SHA256:'));
      expect(ssh.status('h1').state, ConnState.connected);
    }, skip: skip);

    test('reports a failing command', () async {
      final r = await ssh.dokku(host(), ['apps:report', 'no-such-app']);
      expect(r.code, isNot(0));
      expect(r.output, contains('no-such-app'));
    }, skip: skip);

    for (final user in ['dokku', 'root']) {
      test('arguments survive the remote shell unchanged as $user', () async {
        const value = 'a b\$c;"q\'z `id` \$(whoami) && touch /tmp/pwned';
        final h = host(user: user, id: user);
        final set = await ssh.dokku(h, ['config:set', '--no-restart', 'demo-app', 'TRICKY=$value']);
        expect(set.code, 0, reason: set.output);
        final get = await ssh.dokku(h, ['config:get', 'demo-app', 'TRICKY']);
        expect(get.stdout.trimRight(), value);
        expect(set.command, isNot(contains('whoami')), reason: 'secrets are redacted from the shown command');
      }, skip: skip);
    }

    test('base64 values keep newlines intact', () async {
      const value = 'line one\nline two\n\ttabbed "quoted"';
      final set = await ssh.dokku(host(), ['config:set', '--encoded', '--no-restart', 'demo-app', 'MULTI=${base64.encode(utf8.encode(value))}']);
      expect(set.code, 0, reason: set.output);
      final export = await ssh.dokku(host(), ['config:export', '--format', 'json', 'demo-app']);
      expect((jsonDecode(export.stdout) as Map)['MULTI'], value);
    }, skip: skip);

    test('sends stdin', () async {
      final r = await ssh.exec(host(user: 'root'), 'cat; echo done', stdin: utf8.encode('from stdin\n'));
      expect(r.stdout, 'from stdin\ndone\n');
    }, skip: skip);

    test('separates stdout, stderr and the exit code', () async {
      final r = await ssh.exec(host(user: 'root'), 'echo out; echo err >&2; exit 7');
      expect(r.stdout, 'out\n');
      expect(r.stderr, 'err\n');
      expect(r.code, 7);
    }, skip: skip);

    test('collects large output completely', () async {
      final r = await ssh.exec(host(user: 'root'), 'seq 1 200000');
      expect(r.stdout.trim().split('\n'), hasLength(200000));
      expect(r.stdout.trim().split('\n').last, '200000');
    }, skip: skip);

    test('handles many commands at once', () async {
      final h = host(user: 'root');
      final results = await Future.wait([for (var i = 0; i < 30; i++) ssh.exec(h, 'echo $i')]);
      expect(results.map((r) => r.stdout.trim()), [for (var i = 0; i < 30; i++) '$i']);
    }, skip: skip);

    test('batches dokku commands', () async {
      final rs = await ssh.dokkuAll(host(), [['--quiet', 'apps:list'], ['ps:report'], ['apps:report', 'no-such-app']]);
      expect(rs.map((r) => r.ok), [true, true, false]);
    }, skip: skip);

    test('a timeout returns promptly and leaves the connection usable', () async {
      final h = host(user: 'root');
      final watch = Stopwatch()..start();
      final r = await ssh.exec(h, 'sleep 20', timeout: const Duration(seconds: 1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(r.signal, 'TIMEOUT');
      expect((await ssh.exec(h, 'echo still-here')).stdout.trim(), 'still-here');
    }, skip: skip);

    test('reconnects after the connection is dropped', () async {
      final h = host();
      expect((await ssh.dokku(h, ['version'])).ok, isTrue);
      ssh.drop(h.id);
      expect((await ssh.dokku(h, ['version'])).ok, isTrue);
    }, skip: skip);

    test('rejects an invalid subcommand before connecting', () {
      expect(() => ssh.dokku(host(), ['apps:list; id']), throwsA(anything));
    }, skip: skip);

    test('ping measures the round trip', () async {
      final s = await ssh.ping(host());
      expect(s.state, ConnState.connected);
      expect(s.rttMs, isNotNull);
    }, skip: skip);

    test('a changed host key stops a command before anything is sent', () async {
      final changed = host(hostKey: 'SHA256:notTheRealKey', id: 'changed');
      await expectLater(ssh.dokku(changed, ['version']), throwsA(isA<HostKeyMismatch>()));
      expect(ssh.status('changed').state, ConnState.disconnected);
      expect(ssh.status('changed').hostKeyChanged, isTrue);
      expect((await ssh.ping(changed)).hostKeyChanged, isTrue);
      expect((await ssh.ping(host(port: 1, id: 'dead'))).hostKeyChanged, isFalse);
    }, skip: skip);

    test('ping reports an unreachable host', () async {
      final s = await ssh.ping(host(port: 1, id: 'dead'));
      expect(s.state, ConnState.disconnected);
      expect(s.error, isNotEmpty);
    }, skip: skip);
  });

  group('streams', () {
    late SshService ssh;
    setUp(() => ssh = service());
    tearDown(() => ssh.dispose());

    test('delivers output as it arrives and the exit code at the end', () async {
      final chunks = <String>[];
      final s = await ssh.stream(host(user: 'root'), 'for i in 1 2 3; do echo line \$i; sleep 0.2; done; exit 4',
          onData: (c, _) => chunks.add(c));
      final exit = await s.done;
      expect(chunks.join(), 'line 1\nline 2\nline 3\n');
      expect(chunks.length, greaterThan(1), reason: 'output should arrive in pieces, not all at the end');
      expect(exit.code, 4);
    }, skip: skip);

    test('a follow-mode stream can be stopped, repeatedly, without leaking channels', () async {
      final h = host(user: 'root');
      for (var i = 0; i < 12; i++) {
        final out = StringBuffer();
        final s = await ssh.stream(h, 'echo started; tail -f /dev/null',
            pty: const Pty(), onData: (c, _) => out.write(c));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect('$out', contains('started'));
        final watch = Stopwatch()..start();
        s.kill();
        final exit = await s.done;
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(exit.signal, isNotNull);
      }
      // More streams were opened than the channel limit; this only works if they were released.
      final out = StringBuffer();
      final last = await ssh.stream(h, 'echo after', onData: (c, _) => out.write(c));
      await last.done;
      expect('$out', 'after\n');
      // The bracket keeps the pattern from matching this command's own shell.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final left = await ssh.exec(h, 'pgrep -fc "[t]ail -f /dev/null" || true');
      expect(left.stdout.trim(), '0', reason: 'remote processes must be gone after kill');
    }, skip: skip);

    test('dokku logs -t gets a terminal and stops cleanly', () async {
      final out = StringBuffer();
      final s = await ssh.dokkuStream(host(), ['events', '-t'], onData: (c, _) => out.write(c));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      s.kill();
      await s.done.timeout(const Duration(seconds: 3));
    }, skip: skip);

    test('an interactive shell echoes, runs commands and exits', () async {
      final out = StringBuffer();
      final s = await ssh.stream(host(user: 'root'), '', shell: true, onData: (c, _) => out.write(c));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      s.write('echo hi-\$((20+22))\n');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      s.resize(120, 40);
      s.write('stty size\n');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      s.write('exit\n');
      final exit = await s.done.timeout(const Duration(seconds: 5));
      expect('$out', contains('hi-42'));
      expect('$out', contains('40 120'));
      expect(exit.code, 0);
    }, skip: skip);

    test('dokku enter-style commands work through the dokku user with a terminal', () async {
      final out = StringBuffer();
      final s = await ssh.dokkuStream(host(), ['apps:report', 'demo-app'],
          pty: const Pty(), onData: (c, _) => out.write(c));
      await s.done.timeout(const Duration(seconds: 20));
      expect('$out', contains('App dir'));
    }, skip: skip);
  });
}
