import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { redactArgs } from '../shared/redact';
import { ArgError, isPrivileged, shq, validateDokkuArgs } from '../server/quote';

describe('shq', () => {
  it('leaves simple words alone', () => {
    expect(shq('demo-app')).toBe('demo-app');
    expect(shq('http:80:5000')).toBe('http:80:5000');
    expect(shq('/var/lib/dokku/data:/app')).toBe('/var/lib/dokku/data:/app');
  });

  it('quotes empty strings', () => {
    expect(shq('')).toBe("''");
  });

  // The real guarantee: whatever goes in comes out of a shell unchanged.
  it.each([
    'a b', "it's", '$(id)', '`id`', '; rm -rf /', 'a"b', 'x && y', '*', '~', 'line1\nline2', 'tab\there', "'; touch /tmp/pwned; '", '\\', '$HOME', '#comment', '!history', 'é ü 日本',
  ])('round-trips %j through sh', (value) => {
    const out = execFileSync('sh', ['-c', `printf '%s' ${shq(value)}`], { encoding: 'utf8' });
    expect(out).toBe(value);
  });
});

describe('validateDokkuArgs', () => {
  it('accepts subcommands with global flags first', () => {
    expect(validateDokkuArgs(['--quiet', 'apps:list'])).toEqual(['--quiet', 'apps:list']);
    expect(validateDokkuArgs(['config:set', '--no-restart', 'app', 'K=v w'])).toHaveLength(4);
    expect(validateDokkuArgs(['logs', 'app', '-t'])).toHaveLength(3);
    expect(validateDokkuArgs(['builder-dockerfile:set', 'app', 'dockerfile-path'])).toHaveLength(3);
  });

  it.each([
    [['apps:list; id']],
    [['$(id)']],
    [['../bin/sh']],
    [['Apps:List']],
    [['--quiet']],
    [[]],
    [['apps:list', 'a\0b']],
    [['apps:list', 42]],
    ['apps:list'],
    [null],
  ])('rejects %j', (args) => {
    expect(() => validateDokkuArgs(args)).toThrow(ArgError);
  });
});

describe('isPrivileged', () => {
  it('flags commands dokku only allows for root', () => {
    expect(isPrivileged(['plugin:install', 'https://x/y.git'])).toBe(true);
    expect(isPrivileged(['ssh-keys:add', 'name'])).toBe(true);
    expect(isPrivileged(['--quiet', 'plugin:update'])).toBe(true);
    expect(isPrivileged(['plugin:list'])).toBe(false);
    expect(isPrivileged(['ssh-keys:list'])).toBe(false);
    expect(isPrivileged(['apps:create', 'x'])).toBe(false);
  });
});

describe('redactArgs', () => {
  it('hides config values but keeps keys', () => {
    expect(redactArgs(['config:set', '--encoded', '--no-restart', 'app', 'TOKEN=c2VjcmV0', 'A=b'])).toEqual(['config:set', '--encoded', '--no-restart', 'app', 'TOKEN=•••', 'A=•••']);
  });

  it('hides backup credentials', () => {
    expect(redactArgs(['postgres:backup-auth', 'db', 'AKIA123', 'secret', 'us-east-1'])).toEqual(['postgres:backup-auth', 'db', '•••', '•••', 'us-east-1']);
  });

  it('hides a registry password passed as an argument', () => {
    expect(redactArgs(['registry:login', 'ghcr.io', 'bot', 'hunter2'])).toEqual(['registry:login', 'ghcr.io', 'bot', '•••']);
    expect(redactArgs(['registry:login', '--password-stdin', 'ghcr.io', 'bot'])).toEqual(['registry:login', '--password-stdin', 'ghcr.io', 'bot']);
  });

  it('hides service passwords on create', () => {
    expect(redactArgs(['redis:create', 'cache', '--password', 'pw', '--image-version', '7'])).toEqual(['redis:create', 'cache', '--password', '•••', '--image-version', '7']);
  });

  it('leaves other commands untouched', () => {
    const args = ['domains:add', 'app', 'a=b.example.com'];
    expect(redactArgs(args)).toEqual(args);
  });
});
