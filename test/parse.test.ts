import { describe, expect, it } from 'vitest';
import { appHealth, cronHuman, isKeyEvent, isSecretKey, parseCron, parseEnvFile, parseEvent, parseLogLine, parsePlugins, parseReport, parseReports, parseResource, parseScale, parseServiceNames, parseSshKeys, parseStorage, procStatuses, splitDockerOptions, stripAnsi } from '../src/lib/parse';

// Fixtures below are verbatim output captured from Dokku 0.35.20.

const PS_REPORT = `=====> demo-app ps information
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
`;

describe('parseReports', () => {
  it('splits sections per app and lower-cases keys', () => {
    const r = parseReports(PS_REPORT);
    expect(Object.keys(r)).toEqual(['demo-app', 'worker-app']);
    expect(r['demo-app'].deployed).toBe('true');
    expect(r['demo-app']['ps restart policy']).toBe('on-failure:10');
    expect(r['worker-app'].processes).toBe('0');
  });

  it('keeps empty values and trims padding', () => {
    const r = parseReport(`=====> demo-app domains information
       Domains app enabled:           true                     
       Domains app vhosts:            demo-app.dokku.test demo.example.com
       Domains global vhosts:         dokku.test               
=====> demo-app git information
       Git source image:                                       
`);
    expect(r['domains app vhosts']).toBe('demo-app.dokku.test demo.example.com');
    expect(r['domains global vhosts']).toBe('dokku.test');
  });

  it('keeps colons inside values', () => {
    const r = parseReport(`=====> demo-app ports information
       Ports map:                     
       Ports map detected:            http:80:5000 https:443:5000
`);
    expect(r['ports map']).toBe('');
    expect(r['ports map detected']).toBe('http:80:5000 https:443:5000');
  });

  it('ignores ANSI colour codes', () => {
    expect(parseReport('\x1b[1m=====> app ps information\x1b[0m\n       Running:   \x1b[32mtrue\x1b[0m\n').running).toBe('true');
  });
});

describe('process status', () => {
  const r = parseReports(PS_REPORT);
  it('lists containers in order', () => {
    expect(procStatuses(r['demo-app'])).toEqual([
      { type: 'web', index: 1, state: 'running', cid: 'b0af7e6995f' },
      { type: 'web', index: 2, state: 'exited', cid: '475779320b4' },
    ]);
  });
  it('derives app health', () => {
    expect(appHealth(r['demo-app'])).toBe('degraded');
    expect(appHealth(r['worker-app'])).toBe('undeployed');
    expect(appHealth({ deployed: 'true', running: 'true', 'status web 1': 'running (CID: abc)' })).toBe('running');
    expect(appHealth({ deployed: 'true', running: 'false', 'status web 1': 'exited (CID: abc)' })).toBe('stopped');
    expect(appHealth(undefined)).toBe('stopped');
  });
});

describe('parseScale', () => {
  it('reads the scale table', () => {
    expect(parseScale(`-----> Scaling for demo-app
proctype: qty
--------: ---
web:  2
worker:  0
`)).toEqual({ web: 2, worker: 0 });
  });
});

describe('splitDockerOptions', () => {
  it('splits on option boundaries, keeping values with spaces', () => {
    expect(splitDockerOptions('--restart=on-failure:10 --shm-size=256m -v /var/lib/dokku/data/storage/demo-data:/app/storage ')).toEqual([
      '--restart=on-failure:10', '--shm-size=256m', '-v /var/lib/dokku/data/storage/demo-data:/app/storage',
    ]);
    expect(splitDockerOptions('--build-arg FOO=bar')).toEqual(['--build-arg FOO=bar']);
    expect(splitDockerOptions('   ')).toEqual([]);
    expect(splitDockerOptions(undefined)).toEqual([]);
  });
});

describe('parseStorage', () => {
  it('reads json', () => {
    expect(parseStorage('[\n  {\n    "host_path": "/var/lib/dokku/data/storage/demo-data",\n    "container_path": "/app/data",\n    "volume_options": ""\n  }\n]')).toEqual([{ host: '/var/lib/dokku/data/storage/demo-data', container: '/app/data', options: '' }]);
  });
  it('falls back to plain text', () => {
    expect(parseStorage('-----> demo-app volume bind-mounts:\n       /srv/a:/app/a\n       /srv/b:/app/b:ro\n')).toEqual([
      { host: '/srv/a', container: '/app/a', options: '' },
      { host: '/srv/b', container: '/app/b', options: 'ro' },
    ]);
  });
});

describe('parseSshKeys', () => {
  it('reads json', () => {
    const keys = parseSshKeys('[{ "fingerprint": "SHA256:8NGt", "name": "tester", "SSHCOMMAND_ALLOWED_KEYS": "no-agent-forwarding", "public-key": "ssh-ed25519 AAAA test" }]');
    expect(keys).toEqual([{ fingerprint: 'SHA256:8NGt', name: 'tester', allowed: 'no-agent-forwarding', publicKey: 'ssh-ed25519 AAAA test' }]);
  });
  it('reads the text format', () => {
    const keys = parseSshKeys('SHA256:8NGt NAME="tester" SSHCOMMAND_ALLOWED_KEYS="no-agent-forwarding,no-user-rc"\n');
    expect(keys[0]).toMatchObject({ fingerprint: 'SHA256:8NGt', name: 'tester', allowed: 'no-agent-forwarding,no-user-rc' });
  });
});

describe('parsePlugins', () => {
  it('separates core from third-party plugins', () => {
    const p = parsePlugins(`plugn: 0.15.0
  00_dokku-standard    0.35.20 enabled    dokku core standard plugin
  scheduler-docker-local 0.35.20 enabled    dokku core scheduler-docker-local plugin
  redis                2.1.0 enabled    dokku redis service plugin
  maintenance          0.8.0 disabled   dokku maintenance plugin
`);
    expect(p.map((x) => x.name)).toEqual(['00_dokku-standard', 'scheduler-docker-local', 'redis', 'maintenance']);
    expect(p.filter((x) => !x.core).map((x) => x.name)).toEqual(['redis', 'maintenance']);
    expect(p[3].enabled).toBe(false);
  });
});

describe('parseCron', () => {
  it('reads json', () => {
    expect(parseCron('[{"id":"abc","app":"a","command":"node x.js","schedule":"@daily"}]')).toEqual([{ id: 'abc', schedule: '@daily', command: 'node x.js' }]);
    expect(parseCron('[]')).toEqual([]);
  });
  it('reads the table', () => {
    expect(parseCron('ID  Schedule  Command\ncGhw  */15 * * * *  python -m billing.dunning --dry-run=false\nxyz   @daily     node index.js\n')).toEqual([
      { id: 'cGhw', schedule: '*/15 * * * *', command: 'python -m billing.dunning --dry-run=false' },
      { id: 'xyz', schedule: '@daily', command: 'node index.js' },
    ]);
  });
  it('describes schedules', () => {
    expect(cronHuman('*/15 * * * *')).toBe('every 15 min');
    expect(cronHuman('0 3 * * *')).toBe('daily at 03:00');
    expect(cronHuman('@daily')).toBe('daily');
    expect(cronHuman('5 4 1 * *')).toBe('5 4 1 * *');
  });
});

describe('logs and events', () => {
  it('parses a docker-local log line', () => {
    const l = parseLogLine('\x1b[36m2026-09-29T11:48:08.123456789Z app[web.1]:\x1b[0m GET /healthz 200 2ms');
    expect(l.proc).toBe('web.1');
    expect(l.msg).toBe('GET /healthz 200 2ms');
    expect(l.level).toBe('info');
    expect(l.ts).toMatch(/^\d\d:\d\d:\d\d$/);
  });
  it('classifies severity', () => {
    expect(parseLogLine('2026-09-29T11:48:08Z app[web.1]: ERROR ECONNRESET upstream').level).toBe('error');
    expect(parseLogLine('2026-09-29T11:48:08Z app[worker.1]: WARN retrying webhook').level).toBe('warn');
    expect(parseLogLine(' !     App demo-app has not been deployed').level).toBe('error');
  });
  it('keeps unstructured lines', () => {
    expect(parseLogLine('-----> Running in ephemeral container')).toMatchObject({ proc: '', msg: '-----> Running in ephemeral container' });
  });
  it('parses an event line', () => {
    const e = parseEvent('2026-09-29T11:05:45.678873+00:00 926f1ed67355 dokku-event[25606]: INVOKED: post-deploy( demo-app 5000 ) NAME=tester FINGERPRINT=SHA256:8NG DOKKU_PID=23490');
    expect(e).toMatchObject({ kind: 'post-deploy', text: 'demo-app 5000', user: 'tester' });
  });
  it('separates changes from internal triggers', () => {
    for (const k of ['post-deploy', 'pre-deploy', 'post-create', 'post-delete', 'post-config-update', 'post-domains-update', 'receive-app', 'post-stop']) expect(isKeyEvent(k), k).toBe(true);
    for (const k of ['scheduler-detect', 'config-get', 'proxy-type', 'proxy-is-enabled', 'scheduler-app-status', 'user-auth']) expect(isKeyEvent(k), k).toBe(false);
  });
});

describe('datastores and resources', () => {
  it('reads service names', () => {
    expect(parseServiceNames('=====> Redis services\ncache\nqueue-2\n')).toEqual(['cache', 'queue-2']);
    expect(parseServiceNames('NAME   VERSION      STATUS   EXPOSED PORTS  LINKS\ncache  redis:7.2.4  running  -              demo-app\n')).toEqual(['cache']);
    expect(parseServiceNames(' !     There are no Redis services\n')).toEqual([]);
  });
  it('groups resource limits by process type', () => {
    expect(parseResource({ '_default_ limit cpu': '1', '_default_ limit memory': '512m', 'web reserve memory': '128m' })).toEqual({
      _default_: { 'limit-cpu': '1', 'limit-memory': '512m' },
      web: { 'reserve-memory': '128m' },
    });
  });
});

describe('env files', () => {
  it('parses quoting, comments and export', () => {
    expect(parseEnvFile(`# comment
NODE_ENV=production
export PORT=5000
QUOTED="a b # not a comment"
SINGLE='$HOME stays'
MULTI="line1\\nline2"
TRAILING=value # comment
EMPTY=
not a pair
URL=postgres://u:p@h:5432/db?sslmode=require
`)).toEqual([
      ['NODE_ENV', 'production'], ['PORT', '5000'], ['QUOTED', 'a b # not a comment'], ['SINGLE', '$HOME stays'], ['MULTI', 'line1\nline2'],
      ['TRAILING', 'value'], ['EMPTY', ''], ['URL', 'postgres://u:p@h:5432/db?sslmode=require'],
    ]);
  });
  it('guesses which keys hold secrets', () => {
    for (const k of ['DATABASE_URL', 'JWT_SIGNING_KEY', 'STRIPE_SECRET_KEY', 'API_TOKEN', 'SMTP_PASSWORD']) expect(isSecretKey(k), k).toBe(true);
    for (const k of ['NODE_ENV', 'PORT', 'LOG_LEVEL', 'DOKKU_PROXY_PORT']) expect(isSecretKey(k), k).toBe(false);
  });
});

describe('stripAnsi', () => {
  it('removes colours, titles and carriage returns', () => {
    expect(stripAnsi('\x1b[1G\x1b[33mwarn\x1b[0m\r\nnext\x1b]0;title\x07')).toBe('warn\nnext');
  });
});
