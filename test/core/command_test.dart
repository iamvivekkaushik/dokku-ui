import 'dart:io';

import 'package:dokku_console/core/command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shq', () {
    test('leaves simple words alone', () {
      expect(shq('demo-app'), 'demo-app');
      expect(shq('http:80:5000'), 'http:80:5000');
      expect(shq('/var/lib/dokku/data:/app'), '/var/lib/dokku/data:/app');
    });

    test('quotes empty strings', () => expect(shq(''), "''"));

    // The real guarantee: whatever goes in comes out of a shell unchanged.
    for (final value in [
      'a b', "it's", r'$(id)', '`id`', '; rm -rf /', 'a"b', 'x && y', '*', '~', 'line1\nline2', 'tab\there',
      "'; touch /tmp/pwned; '", r'\', r'$HOME', '#comment', '!history', 'é ü 日本',
    ]) {
      test('round-trips ${value.replaceAll('\n', r'\n')} through sh', () async {
        final r = await Process.run('sh', ['-c', "printf '%s' ${shq(value)}"]);
        expect(r.stdout, value);
      });
    }
  });

  group('validateDokkuArgs', () {
    test('accepts subcommands with global flags first', () {
      expect(validateDokkuArgs(['--quiet', 'apps:list']), ['--quiet', 'apps:list']);
      expect(validateDokkuArgs(['config:set', '--no-restart', 'app', 'K=v w']), hasLength(4));
      expect(validateDokkuArgs(['logs', 'app', '-t']), hasLength(3));
      expect(validateDokkuArgs(['builder-dockerfile:set', 'app', 'dockerfile-path']), hasLength(3));
    });

    for (final args in [
      ['apps:list; id'], [r'$(id)'], ['../bin/sh'], ['Apps:List'], ['--quiet'], <String>[], ['apps:list', 'a\u0000b'],
    ]) {
      test('rejects $args', () => expect(() => validateDokkuArgs(args), throwsA(isA<ArgError>())));
    }
  });

  test('isPrivileged flags commands dokku only allows for root', () {
    expect(isPrivileged(['plugin:install', 'https://x/y.git']), isTrue);
    expect(isPrivileged(['ssh-keys:add', 'name']), isTrue);
    expect(isPrivileged(['--quiet', 'plugin:update']), isTrue);
    expect(isPrivileged(['plugin:list']), isFalse);
    expect(isPrivileged(['ssh-keys:list']), isFalse);
    expect(isPrivileged(['apps:create', 'x']), isFalse);
  });

  test('isReadOnly separates lookups from changes', () {
    for (final a in [
      ['apps:list'], ['--quiet', 'apps:list'], ['ps:report', 'x'], ['config:export', '--format', 'json', 'x'],
      ['urls', 'x'], ['logs', 'x', '-t'], ['logs:failed', '--all'], ['ps:scale', 'x'], ['redis:info', 'c'], ['version'],
    ]) {
      expect(isReadOnly(a), isTrue, reason: '$a');
    }
    for (final a in [
      ['apps:create', 'x'], ['ps:scale', 'x', 'web=2'], ['config:set', 'x', 'A=b'], ['ps:restart', 'x'],
      ['redis:link', 'c', 'x'], ['git:from-image', 'x', 'img'],
    ]) {
      expect(isReadOnly(a), isFalse, reason: '$a');
    }
  });

  group('redactArgs', () {
    test('hides config values but keeps keys', () {
      expect(redactArgs(['config:set', '--encoded', '--no-restart', 'app', 'TOKEN=c2VjcmV0', 'A=b']),
          ['config:set', '--encoded', '--no-restart', 'app', 'TOKEN=•••', 'A=•••']);
    });
    test('hides backup credentials', () {
      expect(redactArgs(['postgres:backup-auth', 'db', 'AKIA123', 'secret', 'us-east-1']),
          ['postgres:backup-auth', 'db', '•••', '•••', 'us-east-1']);
    });
    test('hides a registry password passed as an argument', () {
      expect(redactArgs(['registry:login', 'ghcr.io', 'bot', 'hunter2']), ['registry:login', 'ghcr.io', 'bot', '•••']);
      expect(redactArgs(['registry:login', '--password-stdin', 'ghcr.io', 'bot']),
          ['registry:login', '--password-stdin', 'ghcr.io', 'bot']);
    });
    test('hides service passwords on create', () {
      expect(redactArgs(['redis:create', 'cache', '--password', 'pw', '--image-version', '7']),
          ['redis:create', 'cache', '--password', '•••', '--image-version', '7']);
    });
    test('leaves other commands untouched', () {
      final args = ['domains:add', 'app', 'a=b.example.com'];
      expect(redactArgs(args), args);
    });
    test('display command never contains the secret', () {
      expect(displayCommand(['config:set', 'app', 'TOKEN=hunter2']), 'dokku config:set app TOKEN=•••');
    });
    test('hides credentials inside a repository address', () {
      final args = ['git:sync', '--build', 'app', 'https://bot:ghp_secret@github.com/acme/api.git', 'main'];
      expect(redactArgs(args), ['git:sync', '--build', 'app', 'https://bot:•••@github.com/acme/api.git', 'main']);
      expect(displayCommand(args), isNot(contains('ghp_secret')));
      expect(redactUrl('https://ghp_secret@github.com/acme/api.git'), 'https://•••@github.com/acme/api.git');
    });
    test('leaves addresses without a secret as they are', () {
      for (final url in [
        'https://github.com/acme/api.git',
        'https://git.example.com:8443/team/a@b.git',
        'ssh://git@github.com/acme/api.git',
        'git@github.com:acme/api.git',
        'ghcr.io/acme/api:1.4.2',
      ]) {
        expect(redactUrl(url), url);
      }
    });
  });

  group('remoteCommand', () {
    test('sends bare arguments for the dokku user', () {
      expect(remoteCommand(['apps:list'], username: 'dokku', sudo: false), 'apps:list');
      expect(remoteCommand(['config:set', 'a', 'K=v w'], username: 'dokku', sudo: false), "config:set a 'K=v w'");
    });
    test('prefixes dokku for shell users and sudo when needed', () {
      expect(remoteCommand(['apps:list'], username: 'root', sudo: false), 'cd / && dokku apps:list');
      expect(remoteCommand(['apps:list'], username: 'deploy', sudo: true), 'cd / && sudo -n dokku apps:list');
      expect(remoteCommand(['plugin:update'], username: 'deploy', sudo: false), 'cd / && sudo -n dokku plugin:update');
      expect(remoteCommand(['plugin:update'], username: 'root', sudo: false), 'cd / && dokku plugin:update');
    });
  });

  group('splitArgs', () {
    test('honours quotes and escapes', () {
      expect(splitArgs('ps:report demo-app'), ['ps:report', 'demo-app']);
      expect(splitArgs('config:set app "A=b c" \'D=e f\''), ['config:set', 'app', 'A=b c', 'D=e f']);
      expect(splitArgs(r'run app echo a\ b'), ['run', 'app', 'echo', 'a b']);
      expect(splitArgs('  spaced   out  '), ['spaced', 'out']);
      expect(splitArgs('a ""'), ['a', '']);
    });
    test('rejects an unterminated quote', () => expect(() => splitArgs('a "b'), throwsA(isA<ArgError>())));
  });
}
