import 'package:dokku_console/data/stores.dart';
import 'package:dokku_console/state/core.dart';
import 'package:dokku_console/state/jobs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample deploy@laptop\n';

({ProviderContainer scope, FakeSsh ssh, JobsNotifier jobs}) _start(Map<String, dynamic> answers) {
  final ssh = FakeSsh({...answers});
  final scope = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      plainStoreProvider.overrideWithValue(MemoryStore()),
      secureStoreProvider.overrideWithValue(MemoryStore()),
      sshServiceProvider.overrideWithValue(ssh),
    ],
  );
  addTearDown(scope.dispose);
  return (scope: scope, ssh: ssh, jobs: scope.read(jobsProvider.notifier));
}

void main() {
  group('advice after a failure', () {
    test('is chosen from what Dokku printed', () {
      expect(remediation(' !     `builds:list` is not a dokku command.'), contains('does not have that command'));
      expect(remediation(' !     This command must be run as root'), contains('needs root'));
      expect(remediation(' !     App demo-app is currently being deployed or locked'), contains('A deploy lock is held'));
      expect(remediation('Could not resolve host: github.com'), contains('could not reach the internet'));
      expect(remediation(' !     service cache is linked to demo-app'), contains('Unlink the service'));
      expect(remediation('something else entirely'), contains('non-zero exit status'));
    });

    // Seen on Dokku 0.35.20: clearing a lock that is not there fails.
    test('does not claim a lock is held when there was none to remove', () {
      final advice = remediation(' !     Unable to remove deploy lock');
      expect(advice, contains('no deploy lock'));
      expect(advice, isNot(contains('is held')));
    });
  });

  group('jobs', () {
    test('a failed job is kept, explained and written to the activity log', () async {
      final t = _start({'ps:restart demo-app': failed(' !     App demo-app is not deployed\n')});
      final r = await t.jobs.run(dokkuHost, ['ps:restart', 'demo-app']);
      expect(r.ok, isFalse);
      expect(t.scope.read(jobsProvider).single.status, JobStatus.failed);
      expect(t.scope.read(failedJobProvider)?.command, 'dokku ps:restart demo-app');
      final log = await t.scope.read(activityLogProvider).load();
      expect([for (final e in log) (e.command, e.ok)], [('dokku ps:restart demo-app', false)]);
    });

    test('a quiet failure stays in the dock without opening the error dialog', () async {
      final t = _start({'letsencrypt:cron-job --add': failed(' !     crontab: not found\n')});
      await t.jobs.run(dokkuHost, ['letsencrypt:cron-job', '--add'], quiet: true);
      expect(t.scope.read(jobsProvider).single.status, JobStatus.failed);
      expect(t.scope.read(failedJobProvider), isNull);
    });

    test('a probe for a command this Dokku lacks leaves no trace', () async {
      final t = _start({'git:unlock demo-app --force': unknownCommand('git:unlock')});
      final r = await t.jobs.run(dokkuHost, ['git:unlock', 'demo-app', '--force'], probe: true);
      expect(r.ok, isFalse);
      expect(t.scope.read(jobsProvider), isEmpty);
      expect(t.scope.read(failedJobProvider), isNull);
      expect(await t.scope.read(activityLogProvider).load(), isEmpty);
    });

    test('a probe that fails for another reason is reported like any failure', () async {
      final t = _start({'git:unlock demo-app --force': failed(' !     Permission denied\n')});
      await t.jobs.run(dokkuHost, ['git:unlock', 'demo-app', '--force'], probe: true);
      expect(t.scope.read(jobsProvider).single.status, JobStatus.failed);
      expect(t.scope.read(failedJobProvider), isNotNull);
    });

    test('retrying sends what the command was given the first time', () async {
      final t = _start({'ssh-keys:add deploy': failed(' !     Could not reach the key store\n')});
      await t.jobs.run(dokkuHost, ['ssh-keys:add', 'deploy'], stdin: _publicKey);
      final failedJob = t.scope.read(jobsProvider).single;

      t.ssh.fixtures.remove('ssh-keys:add deploy');
      final again = await t.jobs.retry(failedJob);
      expect(again.ok, isTrue);
      expect([for (final i in t.ssh.inputs) '${i.args.join(' ')} < ${i.stdin}'], [
        'ssh-keys:add deploy < $_publicKey',
        'ssh-keys:add deploy < $_publicKey',
      ]);
      expect([for (final j in t.scope.read(jobsProvider)) j.status], [JobStatus.ok], reason: 'the failed attempt is replaced');
    });

    test('retrying a certificate upload sends the archive again', () async {
      final t = _start({'certs:add demo-app': failed(' !     Unable to read certificate\n')});
      const files = {'server.crt': '-----BEGIN CERTIFICATE-----\nMIIB\n', 'server.key': '-----BEGIN PRIVATE KEY-----\nMIIE\n'};
      await t.jobs.run(dokkuHost, ['certs:add', 'demo-app'], files: files);
      await t.jobs.retry(t.scope.read(jobsProvider).single);
      expect(t.ssh.inputs, hasLength(2));
      expect(t.ssh.inputs.last.stdin, t.ssh.inputs.first.stdin);
      expect(t.ssh.inputs.last.stdin, contains('BEGIN PRIVATE KEY'));
    });

    test('what a job was sent is forgotten once the job is dismissed', () async {
      final t = _start({'registry:login --password-stdin ghcr.io bot': failed(' !     unauthorized\n')});
      await t.jobs.run(dokkuHost, ['registry:login', '--password-stdin', 'ghcr.io', 'bot'], stdin: 'hunter2');
      final failedJob = t.scope.read(jobsProvider).single;
      t.jobs.dismiss(failedJob.id);
      await t.jobs.retry(failedJob);
      expect(t.ssh.inputs.map((i) => i.stdin), ['hunter2'], reason: 'the retry has nothing left to send');
    });

    test('secrets never reach the job title, the command shown or the activity log', () async {
      final t = _start({});
      await t.jobs.run(dokkuHost, ['config:set', '--encoded', 'demo-app', 'API_TOKEN=aHVudGVyMg==']);
      await t.jobs.run(dokkuHost, ['git:sync', '--build', 'demo-app', 'https://bot:ghp_secret@github.com/acme/api.git']);
      final shown = [
        for (final j in t.scope.read(jobsProvider)) '${j.title} ${j.command}',
        for (final e in await t.scope.read(activityLogProvider).load()) e.command,
      ].join('\n');
      expect(shown, isNot(contains('aHVudGVyMg')));
      expect(shown, isNot(contains('ghp_secret')));
      expect(shown, contains('API_TOKEN=•••'));
    });
  });
}
