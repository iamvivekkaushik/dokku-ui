import 'dart:io';

import 'package:dokku_console/core/host_scripts.dart';
import 'package:dokku_console/core/install_script.dart';
import 'package:dokku_console/core/tar.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProcessResult> _bash(List<String> args, String stdin) async {
  final p = await Process.start('bash', args);
  p.stdin.write(stdin);
  await p.stdin.close();
  final out = await p.stdout.transform(systemEncoding.decoder).join();
  final err = await p.stderr.transform(systemEncoding.decoder).join();
  return ProcessResult(p.pid, await p.exitCode, out, err);
}

void main() {
  group('makeTar', () {
    test('produces an archive that tar can extract', () async {
      final dir = await Directory.systemTemp.createTemp('dkc-tar-');
      addTearDown(() => dir.delete(recursive: true));
      const crt = '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
      final key = '-----BEGIN PRIVATE KEY-----\n${'A' * 1500}\n-----END PRIVATE KEY-----\n';
      await File('${dir.path}/c.tar').writeAsBytes(makeTar({'server.crt': crt, 'server.key': key}));
      final list = await Process.run('tar', ['-tf', 'c.tar'], workingDirectory: dir.path);
      expect('${list.stdout}'.trim().split('\n'), ['server.crt', 'server.key']);
      await Process.run('tar', ['-xf', 'c.tar'], workingDirectory: dir.path);
      expect(await File('${dir.path}/server.crt').readAsString(), crt);
      expect(await File('${dir.path}/server.key').readAsString(), key);
    });

    test('rejects path traversal in entry names', () {
      expect(() => makeTar({'../etc/passwd': 'x'}), throwsArgumentError);
      expect(() => makeTar({'a/b': 'x'}), throwsArgumentError);
    });
  });

  group('install script', () {
    const base = InstallOptions(serverIp: '203.0.113.10');
    final variants = <String, InstallOptions>{
      'bootstrap tag': base,
      'bootstrap branch': base.copyWith(versionMode: VersionMode.branch),
      'apt': base.copyWith(method: InstallMethod.apt, noRecommends: true),
      'source': base.copyWith(method: InstallMethod.source),
      'pasted key + custom domain': base.copyWith(
        keyMode: KeyMode.paste,
        publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFKN user@host',
        domainMode: DomainMode.custom,
        globalDomain: 'apps.example.com',
        createFirst: true,
      ),
    };

    variants.forEach((name, o) {
      test('$name is valid bash', () async {
        expect(validateInstallOptions(o), isEmpty);
        final r = await _bash(['-n'], installScriptText(o));
        expect(r.exitCode, 0, reason: '${r.stderr}');
      });
    });

    test('uses the chosen tag and global domain', () {
      final text = installScriptText(base.copyWith(dokkuTag: 'v0.35.20'));
      expect(text, contains('https://dokku.com/install/v0.35.20/bootstrap.sh'));
      expect(text, contains('DOKKU_TAG=v0.35.20'));
      expect(text, contains('dokku domains:set-global 203.0.113.10.sslip.io'));
    });

    test('refuses values that could inject shell', () {
      expect(validateInstallOptions(base.copyWith(dokkuTag: 'v1.0.0; rm -rf /')), isNotEmpty);
      expect(validateInstallOptions(base.copyWith(keyName: 'a b')), isNotEmpty);
      expect(validateInstallOptions(base.copyWith(domainMode: DomainMode.custom, globalDomain: r'x.com$(id)')), isNotEmpty);
      expect(validateInstallOptions(base.copyWith(keyMode: KeyMode.paste, publicKey: 'ssh-ed25519 AAAA\nmalicious')), isNotEmpty);
      expect(validateInstallOptions(base.copyWith(createFirst: true, firstApp: 'a;b')), isNotEmpty);
      expect(validateInstallOptions(base.copyWith(method: InstallMethod.source, sourceRepo: 'https://x/y.git; id')), isNotEmpty);
    });

    test('quotes a pasted key with awkward comment text', () async {
      final o = base.copyWith(keyMode: KeyMode.paste, publicKey: r"ssh-ed25519 AAAAC3Nz it's $(mine)");
      expect(validateInstallOptions(o), isEmpty);
      final line = buildInstallScript(o).firstWhere((l) => l.text.startsWith('PUBLIC_KEY=')).text;
      final r = await Process.run('bash', ['-c', '$line; printf \'%s\' "\$PUBLIC_KEY"']);
      expect(r.stdout, r"ssh-ed25519 AAAAC3Nz it's $(mine)");
    });
  });

  group('host scripts', () {
    test('are valid shell', () async {
      for (final s in [metricsScript, systemScript, preflightScript, pluginUpdatesScript, upgradeScript, sudoShim]) {
        final r = await _bash(['-n'], s);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
    });

    // The function is taken out of its root-only guard so that it can be tried here.
    test('the stand-in for sudo runs commands the way the scripts call it', () async {
      final function = sudoShim.split('\n')[1].trim();
      expect(function, startsWith('sudo() {'));
      final r = await _bash(['-s'], '''
set -euo pipefail
$function
sudo -n true && echo "flag ok"
sudo FOO=bar BAZ='a b' bash -c 'echo "env \$FOO/\$BAZ"'
echo "piped" | sudo tee /dev/null
echo 'echo "from stdin"' | sudo sh
sudo -n -E printf '%s\\n' "two words"
sudo false || echo "status \$?"
''');
      expect(r.stderr, isEmpty);
      expect('${r.stdout}'.trim().split('\n'), ['flag ok', 'env bar/a b', 'piped', 'from stdin', 'two words', 'status 1']);
    });

    test('splits sections', () {
      expect(sections('@@a\n1\n2\n@@b\n\n@@c\nx\n'), {'a': '1\n2', 'b': '', 'c': 'x'});
    });

    test('parses sizes', () {
      expect(parseSize('98MiB'), 98 * 1024 * 1024);
      expect(parseSize('1.5GiB'), 1.5 * 1024 * 1024 * 1024);
      expect(parseSize('512kB'), 512000);
      expect(parseSize('0B'), 0);
    });

    test('computes cpu, memory, disk and containers', () {
      final m = parseMetrics('''
@@load
0.46 0.51 0.48 1/812 12345
@@nproc
8
@@stat1
cpu  1000 0 500 8000 100 0 0 0 0 0
@@stat2
cpu  1100 0 550 8300 100 0 0 0 0 0
@@mem
MemTotal:       16000000 kB
MemAvailable:   12000000 kB
SwapTotal:       4000000 kB
SwapFree:        4000000 kB
@@disk
/dev/vda1 85899345920 42949672960 42949672960 50% /
@@uptime
3567890.12 100.00
@@stats
{"CPUPerc":"1.50%","MemUsage":"98MiB / 512MiB","Name":"demo-app.web.1"}
@@ps
{"ID":"b0af7e6995fb0123","Image":"dokku/demo-app:latest","Names":"demo-app.web.1","State":"running","Status":"Up 2 minutes"}
{"ID":"475779320b4d0123","Image":"dokku/demo-app:latest","Names":"demo-app.web.2","State":"exited","Status":"Exited (0)"}
@@end
''');
      expect(m.cores, 8);
      expect(m.load, [0.46, 0.51, 0.48]);
      expect(m.cpuPct!.round(), 33); // 150 busy of 450 total ticks
      expect(m.memTotal, 16000000.0 * 1024);
      expect(m.memAvailable, 12000000.0 * 1024);
      expect(m.diskDevice, '/dev/vda1');
      expect(m.diskUsed, 42949672960);
      expect(m.uptimeSec, closeTo(3567890.12, 0.001));
      expect(m.containers, hasLength(2));
      expect(m.containers[0].name, 'demo-app.web.1');
      expect(m.containers[0].id, 'b0af7e6995fb');
      expect(m.containers[0].cpuPct, 1.5);
      expect(m.containers[0].memBytes, 98 * 1024 * 1024);
      expect(m.containers[0].memLimit, 512 * 1024 * 1024);
      expect(m.containers[1].running, isFalse);
      expect(m.containers[1].cpuPct, isNull);
    });

    test('survives a host without docker access', () {
      final m = parseMetrics('@@load\n0 0 0\n@@nproc\n2\n@@stat1\ncpu 1 1 1 1\n@@stat2\ncpu 1 1 1 1\n@@mem\n@@disk\n@@uptime\n@@stats\n@@ps\n@@end\n');
      expect(m.dockerAvailable, isFalse);
      expect(m.containers, isEmpty);
      expect(m.cpuPct, isNull);
    });

    test('reads which plugins are behind their origin', () {
      expect(
        parsePluginUpdates('redis 8e55b9b e015292\npostgres b2b2b2b b2b2b2b\nmaintenance pinned 51cc5c3\n'
            'letsencrypt a1a1a1a error\napt error\n\n@@end\n'),
        {
          'redis': PluginState.outdated,
          'postgres': PluginState.current,
          'maintenance': PluginState.current,
          'letsencrypt': PluginState.unknown,
          'apt': PluginState.unknown,
        },
      );
      expect(parsePluginUpdates(''), isEmpty);
      expect(parsePluginUpdates('@@end\n'), isEmpty);
    });
  });
}
