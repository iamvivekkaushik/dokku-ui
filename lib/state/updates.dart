import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/updates.dart';
import '../core/version.dart';
import '../data/self_update.dart';

/// The newest release on GitHub, or null when it cannot be reached. Looked up
/// once per run; "Check again" asks once more.
final appReleaseProvider = FutureProvider<AppRelease?>((ref) async {
  try {
    final r = await http
        .get(Uri.parse(latestReleaseApi), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    return parseRelease(r.body);
  } on Object {
    return null;
  }
});

/// A release newer than this build, or null.
final updateProvider = Provider<AppRelease?>((ref) {
  final r = ref.watch(appReleaseProvider).value;
  return r != null && r.isNewer ? r : null;
});

/// The operating system as Dart names it; tests pretend to be another.
final platformProvider = Provider<String>((ref) => Platform.operatingSystem);

final selfUpdaterProvider = Provider<SelfUpdater>((ref) => SelfUpdater());
