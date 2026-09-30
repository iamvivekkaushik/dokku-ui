import 'dart:io';

import 'package:dokku_console/core/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version constant, pubspec.yaml and the changelog agree', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp('^version: *${RegExp.escape(appVersion)}\\+\\d+\\s*\$', multiLine: true).hasMatch(pubspec), isTrue,
        reason: 'lib/core/version.dart says $appVersion; set the same version in pubspec.yaml');
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(RegExp('^## ${RegExp.escape(appVersion)}\\b', multiLine: true).hasMatch(changelog), isTrue,
        reason: 'CHANGELOG.md has no section for $appVersion');
  });
}
