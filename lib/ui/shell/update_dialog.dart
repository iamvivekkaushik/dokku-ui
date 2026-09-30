import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/updates.dart';
import '../../core/version.dart';
import '../../state/updates.dart';
import '../widgets/kit.dart';

Future<void> showUpdateDialog(BuildContext context) => showAppDialog<void>(context, (_) => const UpdateDialog());

Future<void> _open(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on Object {
    // Nothing to hand the link to.
  }
}

enum _Phase { idle, working, done, failed }

/// This build, the newest release, what changed, and the way to get it here.
class UpdateDialog extends ConsumerStatefulWidget {
  const UpdateDialog({super.key});

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  var _phase = _Phase.idle;
  double? _progress;
  String _error = '';

  Future<void> _updateInPlace(String url) async {
    final updater = ref.read(selfUpdaterProvider);
    setState(() {
      _phase = _Phase.working;
      _progress = 0;
    });
    try {
      await updater.update(url, onProgress: (f) {
        if (mounted) setState(() => _progress = f);
      });
      if (mounted) setState(() => _phase = _Phase.done);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = '$e'.replaceFirst(RegExp(r'^(Bad state|Exception): '), '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = ref.watch(platformProvider);
    final lookup = ref.watch(appReleaseProvider);
    final release = lookup.value;
    final newer = release != null && release.isNewer;
    final updater = ref.read(selfUpdaterProvider);
    final asset = release?.assetUrl(platform);
    final inPlace = newer && platform == 'linux' && asset != null && updater.canUpdateInPlace;
    final subtitle = newer
        ? 'You have $appVersion'
        : lookup.isLoading
            ? 'Asking GitHub…'
            : release == null
                ? 'Could not reach GitHub to check.'
                : 'This is the latest release.';

    final String how;
    if (!newer) {
      how = '';
    } else if (inPlace) {
      how = 'Replaces the files in ${updater.bundle?.path} and restarts. Your hosts and keys are kept.';
    } else if (platform == 'linux') {
      how = 'Download the bundle, unpack it over the current folder and run install.sh again. '
          'This build cannot replace itself where it is.';
    } else if (platform == 'android') {
      how = 'Downloads the APK. Open it when the download finishes to install over this version.';
    } else if (platform == 'macos') {
      how = 'Downloads the app. Drag it over the one in Applications.';
    } else if (platform == 'windows') {
      how = 'Downloads the zip. Quit the app, unpack it over the current folder and start it again.';
    } else {
      how = 'There is no build for this platform on the release; build it from source.';
    }

    final actions = switch (_phase) {
      _Phase.working => [Btn('Updating…', size: BtnSize.md, variant: BtnVariant.primary, loading: true)],
      _Phase.done => [
          Btn('Later', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          Btn('Restart now', size: BtnSize.md, variant: BtnVariant.primary, onPressed: updater.restart),
        ],
      _Phase.failed => [
          Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          if (release != null) Btn('Open release', size: BtnSize.md, icon: LucideIcons.externalLink, onPressed: () => _open(release.url)),
        ],
      _Phase.idle => [
          if (!newer) Btn('Check again', size: BtnSize.md, loading: lookup.isLoading, onPressed: () => ref.invalidate(appReleaseProvider)),
          Btn(newer ? 'Later' : 'Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          if (newer)
            Btn(
              inPlace
                  ? 'Update and restart'
                  : platform == 'android'
                      ? 'Download APK'
                      : asset != null
                          ? 'Download'
                          : 'Open release',
              size: BtnSize.md,
              variant: BtnVariant.primary,
              icon: inPlace ? LucideIcons.download : LucideIcons.externalLink,
              onPressed: inPlace ? () => _updateInPlace(asset) : () => _open(asset ?? release.url),
            ),
        ],
    };

    return AppDialog(
      title: newer ? '${release.version} is available' : 'Dokku Console $appVersion',
      subtitle: subtitle,
      width: 520,
      dismissible: _phase != _Phase.working,
      leading: LinkText('All releases', onTap: () => _open(releasesUrl)),
      actions: actions,
      children: [
        if (newer) ...[
          if (release.publishedAt != null) Text('Released ${dateOnly(release.publishedAt!.toIso8601String())}', style: T.meta),
          _Notes(release.notes),
          Text(how, style: T.sans(12.5, color: C.muted, height: 1.5)),
        ],
        if (_phase == _Phase.working) ...[
          LinearProgressIndicator(value: _progress == null || _progress! >= 1 ? null : _progress, minHeight: 4, color: C.fg, backgroundColor: C.w(.1)),
          Text(_progress != null && _progress! >= 1 ? 'Unpacking and swapping the folders…' : 'Downloading…', style: T.meta),
        ],
        if (_phase == _Phase.done)
          AlertBox(tone: Tone.ok, text: 'Updated. This window still runs $appVersion; restart to run ${release?.version}.'),
        if (_phase == _Phase.failed) AlertBox(tone: Tone.bad, title: 'The update did not go through', text: _error),
      ],
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes(this.body);
  final String body;

  @override
  Widget build(BuildContext context) {
    final lines = releaseNotes(body);
    if (lines.isEmpty) return Text('No notes for this release.', style: T.small);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(color: C.w(.02), border: Border.all(color: C.lineSoft), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final l in lines)
          switch (l.kind) {
            NoteKind.heading => Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(l.text, style: T.sans(12, weight: FontWeight.w600)),
              ),
            NoteKind.bullet => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: T.sans(12.5, color: C.muted, height: 1.5)),
                  Expanded(child: Text(l.text, style: T.sans(12.5, color: C.soft, height: 1.5))),
                ]),
              ),
            NoteKind.text => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(l.text, style: T.sans(12.5, color: C.soft, height: 1.5)),
              ),
          },
      ]),
    );
  }
}
