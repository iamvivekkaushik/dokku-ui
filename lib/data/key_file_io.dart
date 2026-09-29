import 'dart:io';

/// Reads a private key from a path on this device. `~` means the home folder.
Future<String> readKeyFile(String path) {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final resolved = path.startsWith('~') ? '$home${path.substring(1)}' : path;
  return File(resolved).readAsString();
}

/// Key files only make sense where there is a home folder to keep them in.
bool get keyFilesSupported => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

Future<List<String>> resolveHost(String host) async {
  try {
    return [for (final a in await InternetAddress.lookup(host)) a.address];
  } on Object {
    return [];
  }
}
