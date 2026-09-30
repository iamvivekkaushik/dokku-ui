import 'package:dokku_console/core/updates.dart';
import 'package:dokku_console/core/version.dart';
import 'package:flutter_test/flutter_test.dart';

const _api = '''
{"tag_name":"v9.9.9","html_url":"https://github.com/iamvivekkaushik/dokku-ui/releases/tag/v9.9.9",
 "published_at":"2026-10-01T10:00:00Z",
 "body":"### Added\\r\\n- A Store of **templates**.\\r\\n- Notes with a [link](https://example.com).\\r\\n\\r\\n## What's Changed\\r\\n* Add a Store by @x in #1\\r\\n",
 "assets":[{"name":"dokku-console-android.apk","browser_download_url":"https://dl/a.apk"},
           {"name":"dokku-console-linux-x64.tar.gz","browser_download_url":"https://dl/l.tar.gz"},
           {"name":"dokku-console-macos.zip","browser_download_url":"https://dl/m.zip"},
           {"name":"dokku-console-windows-x64.zip","browser_download_url":"https://dl/w.zip"},
           {"name":"odd","size":1}]}
''';

void main() {
  group('Releases', () {
    test('a release as the API describes it', () {
      final r = parseRelease(_api)!;
      expect(r.version, '9.9.9');
      expect(r.tag, 'v9.9.9');
      expect(r.isNewer, isTrue);
      expect(r.publishedAt, DateTime.utc(2026, 10, 1, 10));
      expect(r.assetUrl('android'), 'https://dl/a.apk');
      expect(r.assetUrl('linux'), 'https://dl/l.tar.gz');
      expect(r.assetUrl('macos'), 'https://dl/m.zip');
      expect(r.assetUrl('windows'), 'https://dl/w.zip');
      expect(r.assets.length, 4, reason: 'an asset without a download URL is left out');
    });

    test('anything else is not a release', () {
      expect(parseRelease('not json'), isNull);
      expect(parseRelease('[1]'), isNull);
      expect(parseRelease('{"name":"x"}'), isNull);
    });

    test('this build and older ones are not updates', () {
      AppRelease at(String v) => AppRelease(version: v, tag: 'v$v', url: '', notes: '', assets: const {});
      expect(at(appVersion).isNewer, isFalse);
      expect(at('0.9.0').isNewer, isFalse);
      expect(at('99.0.0').isNewer, isTrue);
      expect(at('soon').isNewer, isFalse);
    });

    test('the file per platform', () {
      expect(assetName('linux'), 'dokku-console-linux-x64.tar.gz');
      expect(assetName('windows'), 'dokku-console-windows-x64.zip');
      expect(assetName('ios'), isNull);
    });

    test('notes keep the changelog part, plainly', () {
      final lines = releaseNotes(parseRelease(_api)!.notes);
      expect(lines.map((l) => (l.kind, l.text)), [
        (NoteKind.heading, 'Added'),
        (NoteKind.bullet, 'A Store of templates.'),
        (NoteKind.bullet, 'Notes with a link.'),
      ]);
      expect(releaseNotes(''), isEmpty);
      expect(releaseNotes('Just a line.').single.kind, NoteKind.text);
    });
  });
}
