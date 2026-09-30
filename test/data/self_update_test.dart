import 'dart:io';

import 'package:dokku_console/data/self_update.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bundle as `flutter build linux` leaves it, holding [binary].
Directory _bundle(Directory root, String name, {String binary = 'old', String lib = 'stale.so'}) {
  final dir = Directory('${root.path}/$name')..createSync(recursive: true);
  Directory('${dir.path}/lib').createSync();
  Directory('${dir.path}/data').createSync();
  File('${dir.path}/dokku_console').writeAsStringSync(binary);
  File('${dir.path}/lib/$lib').writeAsStringSync(lib);
  return dir;
}

/// A release archive as CI packs it: one top-level folder.
Future<File> _archive(Directory root, Directory folder) async {
  final file = File('${root.path}/release.tar.gz');
  final tar = await Process.run('tar', ['-czf', file.path, '-C', folder.parent.path, folder.uri.pathSegments.where((s) => s.isNotEmpty).last]);
  expect(tar.exitCode, 0, reason: '${tar.stderr}');
  return file;
}

Set<String> _names(Directory dir) => {for (final e in dir.listSync()) e.uri.pathSegments.where((s) => s.isNotEmpty).last};

void main() {
  late Directory root;
  late HttpServer server;
  File? served;
  var status = 200;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dkc-update-');
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = status;
      if (status == 200 && served != null) {
        req.response.headers.contentLength = served!.lengthSync();
        await req.response.addStream(served!.openRead());
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  String url() => 'http://127.0.0.1:${server.port}/dokku-console-linux-x64.tar.gz';

  test('swaps the bundle for the one in the archive and leaves nothing behind', () async {
    final bundle = _bundle(root, 'dokku-console');
    final src = Directory('${root.path}/src');
    served = await _archive(root, _bundle(src, 'dokku-console', binary: 'new', lib: 'fresh.so'));
    final progress = <double>[];
    final updater = SelfUpdater(bundle: bundle, executable: 'dokku_console');
    expect(updater.canUpdateInPlace, isTrue);

    await updater.update(url(), onProgress: progress.add);

    expect(File('${bundle.path}/dokku_console').readAsStringSync(), 'new');
    expect(File('${bundle.path}/lib/fresh.so').existsSync(), isTrue);
    expect(File('${bundle.path}/lib/stale.so').existsSync(), isFalse, reason: 'the old folder is replaced, not merged');
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    expect(_names(root), {'dokku-console', 'src', 'release.tar.gz'}, reason: 'no archive, staging or old folder is left');
  });

  test('an archive without the binary changes nothing', () async {
    final bundle = _bundle(root, 'dokku-console');
    final other = Directory('${root.path}/src/dokku-console')..createSync(recursive: true);
    File('${other.path}/README').writeAsStringSync('not a bundle');
    served = await _archive(root, other);

    await expectLater(SelfUpdater(bundle: bundle, executable: 'dokku_console').update(url()), throwsA(isA<StateError>()));
    expect(File('${bundle.path}/dokku_console').readAsStringSync(), 'old');
    expect(_names(root), {'dokku-console', 'src', 'release.tar.gz'});
  });

  test('a failed download changes nothing', () async {
    final bundle = _bundle(root, 'dokku-console');
    status = 404;

    await expectLater(SelfUpdater(bundle: bundle, executable: 'dokku_console').update(url()), throwsA(isA<StateError>()));
    expect(File('${bundle.path}/dokku_console').readAsStringSync(), 'old');
    expect(_names(root), {'dokku-console'});
  });
}
