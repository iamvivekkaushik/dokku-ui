import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stores.dart';

export 'key_file_io.dart';

/// Plain settings: host addresses, preferences, the activity log.
class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);
  final SharedPreferences _prefs;

  static Future<PrefsStore> open() async => PrefsStore(await SharedPreferences.getInstance());

  @override
  Future<String?> read(String key) async => _prefs.getString(key);
  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);
  @override
  Future<void> delete(String key) => _prefs.remove(key);
}

/// The device keystore: Keychain on Apple devices, Keystore on Android,
/// libsecret on Linux, Credential Manager on Windows.
class SecureStore implements KeyValueStore {
  const SecureStore();

  // On macOS the newer keychain needs a provisioning profile from a paid
  // developer account. The older one does not, so a build that is not signed
  // that way, such as the one attached to a release, can still store keys.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// As much as a key, a certificate or a .env file could reasonably be.
const maxTextFileBytes = 256 * 1024;

/// Lets the user pick a small text file (a key, a certificate, a .env file).
Future<({String name, String text})?> pickTextFile({int maxBytes = maxTextFileBytes}) async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.length > maxBytes) throw const FormatException('That file is too large to be a key or config file.');
  return (name: file.name, text: utf8.decode(bytes, allowMalformed: true));
}

/// Saves [text] to a location the user chooses. Returns false if they cancel.
Future<bool> saveTextFile(String fileName, String text) async {
  final uri = await FilePicker.saveFile(
    fileName: fileName,
    bytes: Uint8List.fromList(utf8.encode(text)),
    mimeType: 'text/plain',
  );
  return uri != null;
}
