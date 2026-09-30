/// Releases of this app on GitHub, and what each platform takes from one.
library;

import 'dart:convert';

import 'parse.dart' show isNewerVersion;
import 'version.dart';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.url,
    required this.notes,
    required this.assets,
    this.publishedAt,
  });

  /// `1.2.0`, from the tag `v1.2.0`.
  final String version;
  final String tag;

  /// The release page.
  final String url;

  /// The release body: the changelog section, then what GitHub appends.
  final String notes;

  /// Attached files, by name.
  final Map<String, String> assets;
  final DateTime? publishedAt;

  bool get isNewer => isNewerVersion(version, appVersion);

  String? assetUrl(String platform) => assets[assetName(platform)];
}

/// The file the release job attaches for [platform], named as Dart names
/// operating systems. Null where there is no build.
String? assetName(String platform) => switch (platform) {
      'android' => 'dokku-console-android.apk',
      'linux' => 'dokku-console-linux-x64.tar.gz',
      'macos' => 'dokku-console-macos.zip',
      'windows' => 'dokku-console-windows-x64.zip',
      _ => null,
    };

/// One release as the GitHub API describes it; null for anything else.
AppRelease? parseRelease(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final tag = decoded['tag_name'];
  if (tag is! String || tag.isEmpty) return null;
  final assets = decoded['assets'];
  return AppRelease(
    version: tag.replaceFirst(RegExp(r'^v'), ''),
    tag: tag,
    url: decoded['html_url'] as String? ?? '$releasesUrl/tag/$tag',
    notes: decoded['body'] as String? ?? '',
    publishedAt: DateTime.tryParse(decoded['published_at'] as String? ?? ''),
    assets: {
      if (assets is List)
        for (final a in assets)
          if (a is Map && a['name'] is String && a['browser_download_url'] is String) a['name'] as String: a['browser_download_url'] as String,
    },
  );
}

enum NoteKind { heading, bullet, text }

class NoteLine {
  const NoteLine(this.kind, this.text);
  final NoteKind kind;
  final String text;
}

final _generated = RegExp(r"^## What.s Changed", multiLine: true);
final _heading = RegExp(r'^#+\s*');
final _bullet = RegExp(r'^[-*]\s+');
final _marks = RegExp(r'\*\*|`');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');

/// The release notes as lines to show: the changelog part, without the list
/// of commits GitHub appends, and without markdown marks.
List<NoteLine> releaseNotes(String body) {
  final cut = _generated.firstMatch(body)?.start;
  final text = (cut == null ? body : body.substring(0, cut)).replaceAll('\r', '');
  String plain(String s) => s.replaceAll(_marks, '').replaceAllMapped(_link, (m) => m[1]!);
  return [
    for (final raw in text.split('\n'))
      if (raw.trim().isNotEmpty)
        if (raw.trim().startsWith('#'))
          NoteLine(NoteKind.heading, raw.trim().replaceFirst(_heading, ''))
        else if (_bullet.hasMatch(raw.trim()))
          NoteLine(NoteKind.bullet, plain(raw.trim().replaceFirst(_bullet, '')))
        else
          NoteLine(NoteKind.text, plain(raw.trim())),
  ];
}
