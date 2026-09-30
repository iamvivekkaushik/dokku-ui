/// Replaces this app's own files with a newer release where that is possible:
/// the Linux bundle, a folder the user unpacked and can write to.
library;

import 'dart:io';

import 'package:http/http.dart' as http;

class SelfUpdater {
  /// [bundle] and [executable] stand in for this process's own, in tests.
  SelfUpdater({this._bundle, this._executable});
  final Directory? _bundle;
  final String? _executable;

  /// The folder this build runs from, when it is a Linux bundle.
  Directory? get bundle {
    if (_bundle != null) return _bundle;
    if (!Platform.isLinux) return null;
    final dir = File(Platform.resolvedExecutable).parent;
    final isBundle = Directory('${dir.path}/lib').existsSync() && Directory('${dir.path}/data').existsSync();
    return isBundle ? dir : null;
  }

  /// Whether the folder next to the bundle can be written, which the swap needs.
  bool get canUpdateInPlace {
    final dir = bundle;
    if (dir == null) return false;
    try {
      File('${dir.parent.path}/.dokku-console-write-test')
        ..writeAsStringSync('')
        ..deleteSync();
      return true;
    } on Object {
      return false;
    }
  }

  /// Downloads the bundle at [url], unpacks it beside this one, swaps the two
  /// folders and removes the old one. This process keeps its open files, so it
  /// runs on; a restart runs the new build. [onProgress] gets 0 to 1 while
  /// downloading.
  Future<void> update(String url, {void Function(double fraction)? onProgress}) async {
    final dir = bundle;
    if (dir == null) throw StateError('This build cannot replace itself. Download the release instead.');
    final parent = dir.parent.path;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final archive = File('$parent/.dokku-console-$stamp.tar.gz');
    final staging = Directory('$parent/.dokku-console-$stamp');
    final old = Directory('${dir.path}.old-$stamp');
    final exeName = _executable ?? Uri.file(Platform.resolvedExecutable).pathSegments.last;
    try {
      await _download(url, archive, onProgress);
      await staging.create();
      final tar = await Process.run('tar', ['-xzf', archive.path, '--strip-components=1', '-C', staging.path]);
      if (tar.exitCode != 0) throw StateError('Could not unpack the release: ${'${tar.stderr}'.trim()}');
      if (!File('${staging.path}/$exeName').existsSync()) throw StateError('The release does not contain $exeName.');
      await dir.rename(old.path);
      try {
        await staging.rename(dir.path);
      } on Object {
        await old.rename(dir.path);
        rethrow;
      }
      await old.delete(recursive: true);
    } finally {
      if (archive.existsSync()) archive.deleteSync();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  Future<void> _download(String url, File to, void Function(double)? onProgress) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) throw StateError('The download failed: HTTP ${response.statusCode}.');
      final total = response.contentLength ?? 0;
      var got = 0;
      final sink = to.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  /// Starts the new build and ends this one.
  Future<void> restart() async {
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}
