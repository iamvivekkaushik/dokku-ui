import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/command.dart';
import '../../../core/format.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../actions.dart';
import '../../widgets/kit.dart';

const _longRun = Duration(minutes: 30);

final _repoPattern = RegExp(r'^(https?://|git@|ssh://)\S+$');
final _imagePattern = RegExp(r'^\S+$');
final _deployCommand = RegExp(r'git:(sync|from-image)|ps:(rebuild|restart)|builds:');

class DeploysTab extends StatelessWidget {
  const DeploysTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context) => TwoCol(
        left: [_GitCard(host, app), _SyncCard(host, app), _ImageCard(host, app)],
        right: [_BuildsCard(host, app)],
      );
}

class _GitCard extends ConsumerStatefulWidget {
  const _GitCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_GitCard> createState() => _GitCardState();
}

class _GitCardState extends ConsumerState<_GitCard> with Busy {
  final _branch = SyncedController();

  @override
  void dispose() {
    _branch.dispose();
    super.dispose();
  }

  Future<void> _clearStaleLock() => busy<ExecResult>('stale', () async {
        final app = widget.app;
        final run = DokkuRunner(ref, widget.host);
        // git:unlock was folded into apps:unlock in Dokku 0.34.
        final r = await run(['git:unlock', app, '--force'], title: 'Clear stale lock', probe: true);
        if (r.ok || !notSupported(r.output)) return r;
        return run(['apps:unlock', app], title: 'Clear stale lock');
      });

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final git = ref.report(host, 'git', app);
    final appReport = ref.report(host, 'apps', app);
    final g = git.data;

    final deployBranch =
        firstFilled([g?['git deploy branch'], g?['git computed deploy branch'], g?['git global deploy branch']], 'master');
    if (g != null) _branch.sync(deployBranch);
    final branch = _branch.text.trim();
    final sha = g?['git sha'] ?? '';
    final locked = isYes(appReport.data?['app locked']);
    final keepGit = isYes(firstFilled([g?['git keep git dir'], g?['git computed keep git dir']], ''));
    final remote = host.gitRemote(app);

    return Panel.column(children: [
      PanelHead('Git',
          trailing: Text('rev ${sha.isEmpty || sha == 'HEAD' ? '—' : sha.substring(0, sha.length.clamp(0, 7))} · $deployBranch',
              style: T.meta)),
      if (git.loading) const LoadingRows(rows: 3),
      if (git.error != null) EmptyBox('Could not read the git settings of $app: ${git.errorText}'),
      if (g != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Field(
              'Git remote',
              child: Row(children: [
                Expanded(
                  child: Container(
                    // As tall as the input below it.
                    constraints: BoxConstraints(minHeight: 30 + touchPad(context)),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                        color: C.field, border: Border.all(color: C.lineStrong), borderRadius: BorderRadius.circular(7)),
                    child: Text(remote, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: C.soft)),
                  ),
                ),
                const SizedBox(width: 6),
                CopyBtn(remote, label: 'Copy'),
              ]),
            ),
            const SizedBox(height: 12),
            Field(
              'Deploy branch',
              hint: 'Pushes to other branches are stored but not deployed.',
              child: Row(children: [
                Expanded(child: AppInput(controller: _branch.controller, hint: deployBranch, onChanged: (_) => setState(() {}))),
                const SizedBox(width: 6),
                Btn('Save',
                    loading: isBusy('branch'),
                    onPressed: branch.isEmpty || branch == deployBranch
                        ? null
                        : () => busy('branch', () => runDokku(context, ref, host, ['git:set', app, 'deploy-branch', branch]))),
              ]),
            ),
            const SizedBox(height: 12),
            Container(height: 1, color: C.lineSoft),
            const SizedBox(height: 12),
            SwitchRow(
              title: 'Keep .git directory',
              desc: 'Makes the repository history available inside the build.',
              value: keepGit,
              busy: isBusy('keepgit'),
              onChanged: (v) => busy('keepgit', () => runDokku(context, ref, host, ['git:set', app, 'keep-git-dir', '$v'])),
            ),
            const SizedBox(height: 12),
            SwitchRow(
              title: 'Deploy lock',
              desc: locked
                  ? 'Deploys are blocked. Pushes are rejected until it is unlocked.'
                  : 'Deploys are allowed. Lock to reject pushes for a while.',
              value: locked,
              busy: isBusy('lock'),
              // Until the lock state is known the switch could only guess.
              onChanged: appReport.data == null
                  ? null
                  : (v) => busy('lock', () => runDokku(context, ref, host, [v ? 'apps:lock' : 'apps:unlock', app])),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Stale git lock', style: T.body),
                  const SizedBox(height: 2),
                  Text('Clear it only if an earlier deploy was interrupted.', style: T.hint),
                ]),
              ),
              const SizedBox(width: 12),
              Btn('Clear lock', loading: isBusy('stale'), onPressed: _clearStaleLock),
            ]),
          ]),
        ),
      CmdFooter('\$ ${displayCommand(['git:set', app, 'deploy-branch', branch.isEmpty ? deployBranch : branch])}'
          '  ·  apps:${locked ? 'unlock' : 'lock'} $app  ·  git:unlock $app --force'),
    ]);
  }
}

class _SyncCard extends ConsumerStatefulWidget {
  const _SyncCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_SyncCard> createState() => _SyncCardState();
}

class _SyncCardState extends ConsumerState<_SyncCard> with Busy {
  final _repo = TextEditingController();
  final _gitRef = TextEditingController();
  var _build = true;

  @override
  void dispose() {
    _repo.dispose();
    _gitRef.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final repo = _repo.text.trim(), gitRef = _gitRef.text.trim();
    final args = ['git:sync', if (_build) '--build', app, repo, if (gitRef.isNotEmpty) gitRef];
    final shown = [
      displayCommand(['git:sync', if (_build) '--build', app]),
      repo.isEmpty ? '<git-url>' : shq(redactUrl(repo)),
      if (gitRef.isNotEmpty) shq(gitRef),
    ].join(' ');

    final repoInput = AppInput(
      controller: _repo,
      hint: 'https://github.com/acme/api-gateway.git',
      keyboardType: TextInputType.url,
      onChanged: (_) => setState(() {}),
    );
    final refInput = AppInput(controller: _gitRef, hint: 'ref (optional)', onChanged: (_) => setState(() {}));

    return Panel.column(children: [
      const PanelHead('Sync from repository', note: 'deploy without a push'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          LayoutBuilder(
            builder: (context, box) => box.maxWidth < 460
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [repoInput, const SizedBox(height: 8), refInput],
                  )
                : Row(children: [
                    Expanded(child: repoInput),
                    const SizedBox(width: 8),
                    SizedBox(width: 150, child: refInput),
                  ]),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: AppCheckbox(value: _build, onChanged: (v) => setState(() => _build = v), label: 'Build after sync (--build)'),
          ),
        ]),
      ),
      CmdFooter(
        '\$ $shown',
        action: Btn('Sync & deploy',
            variant: BtnVariant.primary,
            size: BtnSize.md,
            loading: isBusy('sync'),
            onPressed: _repoPattern.hasMatch(repo)
                ? () => busy('sync', () => runDokku(context, ref, host, args, title: 'Sync $app', timeout: _longRun))
                : null),
      ),
    ]);
  }
}

class _ImageCard extends ConsumerStatefulWidget {
  const _ImageCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_ImageCard> createState() => _ImageCardState();
}

class _ImageCardState extends ConsumerState<_ImageCard> with Busy {
  final _image = TextEditingController();

  @override
  void dispose() {
    _image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final image = _image.text.trim();

    return Panel.column(children: [
      PanelHead('Deploy an image', trailing: Text('git:from-image', style: T.meta)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: AppInput(controller: _image, hint: 'ghcr.io/acme/api:1.4.2', onChanged: (_) => setState(() {}))),
            const SizedBox(width: 8),
            Btn('Deploy image',
                loading: isBusy('image'),
                onPressed: _imagePattern.hasMatch(image)
                    ? () => busy(
                        'image',
                        () => runDokku(context, ref, host, ['git:from-image', app, image],
                            title: 'Deploy $image', timeout: _longRun))
                    : null),
          ]),
          const SizedBox(height: 6),
          Text('To roll back, deploy an earlier tag of the image.', style: T.sans(11, color: C.dim, height: 1.45)),
        ]),
      ),
      CmdFooter('\$ ${displayCommand(['git:from-image', app])} ${image.isEmpty ? '<image>' : shq(image)}'),
    ]);
  }
}

class _Build {
  const _Build({required this.id, required this.kind, required this.status, required this.source, required this.startedAt, required this.duration});

  factory _Build.fromJson(Map<String, dynamic> j) {
    String text(String key) => j[key] == null ? '' : '${j[key]}';
    return _Build(
      id: text('id'),
      kind: text('kind'),
      status: firstFilled([text('display_status'), text('status')], 'unknown'),
      source: text('source'),
      startedAt: text('started_at'),
      duration: text('duration'),
    );
  }

  final String id;
  final String kind;
  final String status;
  final String source;
  final String startedAt;
  final String duration;
}

/// `builds:list` arrived in Dokku 0.38; [supported] is false on older servers.
typedef _History = ({bool supported, List<_Build> builds});

_History _parseBuilds(ExecResult r) {
  if (notSupported(r.output)) return (supported: false, builds: const []);
  if (!r.ok) throw DokkuError(r);
  final text = r.stdout.trim();
  if (!text.startsWith('[')) return (supported: true, builds: const []);
  try {
    final list = (jsonDecode(text) as List).cast<Map<String, dynamic>>();
    return (supported: true, builds: [for (final b in list) _Build.fromJson(b)]);
  } on FormatException {
    return (supported: true, builds: const []);
  }
}

final _good = RegExp(r'succe|deployed|ok', caseSensitive: false);
final _bad = RegExp(r'fail|error', caseSensitive: false);
final _active = RegExp(r'running|build', caseSensitive: false);

Tone _statusTone(String status) {
  if (_good.hasMatch(status)) return Tone.ok;
  if (_bad.hasMatch(status)) return Tone.bad;
  return _active.hasMatch(status) ? Tone.info : Tone.mute;
}

class _BuildsCard extends ConsumerStatefulWidget {
  const _BuildsCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_BuildsCard> createState() => _BuildsCardState();
}

class _BuildsCardState extends ConsumerState<_BuildsCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final history = ref.dokku(host, ['builds:list', app, '--format', 'json'], _parseBuilds,
        lenient: true, refresh: const Duration(seconds: 15));
    final supported = history.data?.supported;
    final builds = history.data?.builds ?? const <_Build>[];
    // Older servers keep no history, so fall back to what this console started.
    final activity = supported == false ? ref.watch(activityProvider(host.id)) : null;
    final deploys = [
      for (final e in activity?.value ?? const <ActivityEntry>[])
        if (e.command.split(' ').contains(app) && _deployCommand.hasMatch(e.command)) e,
    ].take(10).toList();

    return Panel.column(children: [
      PanelHead('Builds & releases',
          trailing: Wrap(spacing: 8, runSpacing: 6, children: [
            if (supported == true)
              Btn('Cancel running build',
                  loading: isBusy('cancel'),
                  onPressed: () => busy('cancel', () => runDokku(context, ref, host, ['builds:cancel', app]))),
            Btn('Trigger rebuild',
                loading: isBusy('rebuild'),
                onPressed: () =>
                    busy('rebuild', () => runDokku(context, ref, host, ['ps:rebuild', app], title: 'Rebuild $app', timeout: _longRun))),
          ])),
      if (history.loading) const LoadingRows(),
      if (history.error != null) EmptyBox('Could not read the build history of $app: ${history.errorText}'),
      if (supported == true) ...[
        if (builds.isEmpty) const EmptyBox('No builds recorded for this app yet.'),
        if (builds.isNotEmpty) _BuildTable(builds, onOutput: (b) => showAppDialog<void>(context, (_) => _BuildOutput(host, app, b.id))),
      ],
      if (supported == false) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.lineSoft))),
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Build history ('),
              TextSpan(text: 'builds:list', style: T.mono(11, color: C.muted)),
              const TextSpan(text: ') needs Dokku 0.38 or newer. Showing deploys started from this console.'),
            ]),
            style: T.hint,
          ),
        ),
        if (activity!.isLoading && !activity.hasValue) const LoadingRows(),
        if (activity.hasError && !activity.hasValue) EmptyBox('Could not read the history of changes: ${activity.error}'),
        if (activity.hasValue && deploys.isEmpty) const EmptyBox('No deploys from this console yet.'),
        for (final (i, e) in deploys.indexed)
          PanelRow(
            first: i == 0,
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(e.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code),
                  const SizedBox(height: 2),
                  Text('${ago(e.at)} · ${formatMs(e.durationMs)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
                ]),
              ),
              const SizedBox(width: 12),
              Pill(e.ok ? 'deployed' : 'exit ${e.code ?? '?'}', tone: e.ok ? Tone.ok : Tone.bad, mono: true, dot: false),
            ]),
          ),
      ],
      CmdFooter('\$ ${displayCommand(['builds:list', app])}  ·  builds:output $app <id>  ·  ps:rebuild $app'),
    ]);
  }
}

class _BuildTable extends StatelessWidget {
  const _BuildTable(this.builds, {required this.onOutput});
  final List<_Build> builds;
  final ValueChanged<_Build> onOutput;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // On a phone the status moves under the build instead of squeezing it.
        final wide = box.maxWidth >= 460;
        final action = 76 + touchPad(context);
        return Column(children: [
          THead([
            th(wide ? 'build · source' : 'build · status'),
            if (wide) th('status', width: 104, align: TextAlign.right),
            SizedBox(width: action),
          ]),
          for (final (i, b) in builds.indexed)
            PanelRow(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('${b.id} · ${b.kind}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: i == 0 ? C.fg : C.muted)),
                    const SizedBox(height: 2),
                    Text(
                      '${b.source.isEmpty ? '—' : b.source} · ${ago(b.startedAt)}${b.duration.isEmpty ? '' : ' · ${b.duration}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.meta,
                    ),
                    if (!wide) ...[
                      const SizedBox(height: 6),
                      Pill(b.status, tone: _statusTone(b.status), mono: true, dot: false),
                    ],
                  ]),
                ),
                if (wide)
                  SizedBox(
                    width: 104,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Pill(b.status, tone: _statusTone(b.status), mono: true, dot: false),
                    ),
                  ),
                SizedBox(
                  width: action,
                  child: Align(alignment: Alignment.centerRight, child: Btn('Output', onPressed: () => onOutput(b))),
                ),
              ]),
            ),
        ]);
      });
}

class _BuildOutput extends ConsumerWidget {
  const _BuildOutput(this.host, this.app, this.id);
  final Host host;
  final String app;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final out =
        ref.dokku(host, ['builds:output', app, id], (r) => stripAnsi(r.ok ? r.stdout : r.output).trim(), lenient: true);
    final text = out.data ?? '';
    return AppDialog(
      title: 'Build $id',
      subtitle: displayCommand(['builds:output', app, id]),
      width: 820,
      children: [
        if (out.loading) const Skeleton(height: 160),
        if (out.error != null) EmptyBox('Could not read the output of this build: ${out.errorText}', margin: EdgeInsets.zero),
        if (out.data != null) CodeBlock(text.isEmpty ? 'No output was recorded for this build.' : text),
      ],
    );
  }
}
