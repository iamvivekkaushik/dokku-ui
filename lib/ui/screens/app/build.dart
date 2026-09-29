import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/command.dart';
import '../../../core/format.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../actions.dart';
import '../../widgets/kit.dart';

/// Builder id (empty for auto-detect) and what it does.
const _builders = [
  ('', 'Auto-detect. Uses the Dockerfile when present, otherwise Heroku buildpacks.'),
  ('herokuish', 'Heroku buildpacks via herokuish. Default when no Dockerfile is present.'),
  ('pack', 'Cloud Native Buildpacks (pack CLI). Modern successor to herokuish.'),
  ('dockerfile', 'Build from the Dockerfile in the repository.'),
  ('nixpacks', 'Language auto-detection with Nix-based reproducible images.'),
  ('railpack', "Railway's Railpack builder. Fast, layered images (Dokku 0.36+)."),
  ('lambda', 'Package for AWS Lambda instead of a long-running container.'),
  ('null', 'Skip building. Deploy a pre-built image via git:from-image.'),
];

final _listSeparator = RegExp(r'[,\s]+');

class BuildTab extends ConsumerWidget {
  const BuildTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final builder = ref.report(host, 'builder', app).data;
    final effective =
        firstFilled([builder?['builder selected'], builder?['builder computed selected'], builder?['builder detected']], '');

    final cards = [
      if (effective.isEmpty || effective == 'herokuish' || effective == 'pack') _BuildpacksCard(host, app),
      if (effective.isEmpty || effective == 'dockerfile') _DockerfileCard(host, app),
      _EnvironmentCard(host, app),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      _BuilderCard(host, app),
      const SizedBox(height: 16),
      if (cards.length == 1) cards.first else TwoCol(left: [cards.first], right: cards.sublist(1)),
    ]);
  }
}

class _BuilderCard extends ConsumerStatefulWidget {
  const _BuilderCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_BuilderCard> createState() => _BuilderCardState();
}

class _BuilderCardState extends ConsumerState<_BuilderCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final builder = ref.report(host, 'builder', app);
    final selected = builder.data?['builder selected'] ?? '';
    final detected =
        firstFilled([builder.data?['builder detected'], builder.data?['builder computed selected']], '—');
    final compact = Bp.isCompact(context);

    return Panel.column(children: [
      PanelHead('Builder',
          trailing: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'auto-detected: '),
              TextSpan(text: detected, style: T.mono(11, color: C.soft)),
            ]),
            style: T.hint,
          )),
      if (builder.loading) const LoadingRows(),
      if (builder.error != null) EmptyBox('Could not read the builder of $app: ${builder.errorText}'),
      if (builder.data != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: AutoGrid(minWidth: compact ? 140 : 180, gap: 10, children: [
            for (final (id, desc) in _builders)
              _BuilderOption(
                name: id.isEmpty ? 'auto' : id,
                desc: desc,
                selected: selected == id,
                // Choosing auto clears the setting, which is what no value means.
                onTap: selected == id || isBusy('builder')
                    ? null
                    : () => busy(
                        'builder',
                        () => runDokku(context, ref, host, ['builder:set', app, 'selected', if (id.isNotEmpty) id],
                            title: 'Set builder to ${id.isEmpty ? 'auto' : id}')),
              ),
          ]),
        ),
      CmdFooter('\$ ${displayCommand(['builder:set', app, 'selected', if (selected.isNotEmpty) selected])}'),
    ]);
  }
}

class _BuilderOption extends StatefulWidget {
  const _BuilderOption({required this.name, required this.desc, required this.selected, required this.onTap});
  final String name;
  final String desc;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_BuilderOption> createState() => _BuilderOptionState();
}

class _BuilderOptionState extends State<_BuilderOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    return Semantics(
      button: true,
      selected: on,
      label: widget.name,
      child: MouseRegion(
        cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: on ? C.w(.04) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _hover && widget.onTap != null ? C.w(.22) : (on ? C.w(.18) : C.line)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Text(widget.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12, weight: FontWeight.w500)),
                ),
                const SizedBox(width: 8),
                RadioDot(on),
              ]),
              const SizedBox(height: 6),
              Text(widget.desc, style: T.hint),
            ]),
          ),
        ),
      ),
    );
  }
}

class _BuildpacksCard extends ConsumerStatefulWidget {
  const _BuildpacksCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_BuildpacksCard> createState() => _BuildpacksCardState();
}

class _BuildpacksCardState extends ConsumerState<_BuildpacksCard> with Busy {
  final _url = TextEditingController();
  final _index = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _index.dispose();
    super.dispose();
  }

  /// Moves the buildpack at [i] up one place by writing both positions.
  /// Positions are 1-based for Dokku, so list index `i - 1` is position `i`.
  Future<void> _moveUp(List<String> list, int i) => busy<ExecResult>('move', () {
        final app = widget.app;
        final above = list[i - 1], moved = list[i];
        return DokkuRunner(ref, widget.host).all([
          ['buildpacks:set', '--index', '$i', app, moved],
          ['buildpacks:set', '--index', '${i + 1}', app, above],
        ], title: 'Reorder buildpacks');
      });

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'buildpacks', app);
    final list = (report.data?['buildpacks list'] ?? '').split(_listSeparator).where((b) => b.isNotEmpty).toList();
    final url = _url.text.trim(), index = _index.text;
    final addArgs = ['buildpacks:add', if (index.isNotEmpty) ...['--index', index], app];

    Future<void> add() async {
      final r = await busy('add', () => runDokku(context, ref, host, [...addArgs, url]));
      if (r?.ok != true || !mounted) return;
      _url.clear();
      _index.clear();
      setState(() {});
    }

    final urlInput = AppInput(
      controller: _url,
      hint: 'heroku/nodejs or a repository URL',
      onChanged: (_) => setState(() {}),
    );
    final indexInput = Tooltip(
      message: 'Optional position in the list, starting at 1',
      child: AppInput(
        controller: _index,
        hint: 'index',
        keyboardType: TextInputType.number,
        inputFormatters: digitsOnly,
        onChanged: (_) => setState(() {}),
      ),
    );
    final addButton = Btn('Add buildpack', loading: isBusy('add'), onPressed: url.isEmpty ? null : add);

    return Panel.column(children: [
      PanelHead('Buildpacks',
          trailing: Btn('Clear buildpacks',
              loading: isBusy('clear'),
              onPressed: list.isEmpty
                  ? null
                  : () => busy(
                      'clear',
                      () => runDokku(context, ref, host, ['buildpacks:clear', app],
                          ask: const Confirm(
                            title: 'Clear all buildpacks?',
                            body: 'Every pinned buildpack is removed. The next build detects them from the repository.',
                            label: 'Clear buildpacks',
                            danger: true,
                          ))))),
      if (report.loading) const LoadingRows(),
      if (report.error != null) EmptyBox('Could not read the buildpacks of $app: ${report.errorText}'),
      if (report.data != null && list.isEmpty)
        const EmptyBox('No buildpacks pinned. The builder detects them from the repository.'),
      for (final (i, b) in list.indexed)
        PanelRow(
          first: i == 0,
          padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
          child: Row(children: [
            SizedBox(width: 28, child: Text('${i + 1}'.padLeft(2, '0'), style: T.mono(11, color: C.muted))),
            Expanded(child: Text(b, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code)),
            const SizedBox(width: 8),
            IconBtn(LucideIcons.arrowUp,
                tooltip: 'Move up', onPressed: i == 0 || isBusy('move') ? null : () => _moveUp(list, i)),
            const SizedBox(width: 4),
            IconBtn(LucideIcons.x,
                tooltip: 'Remove',
                danger: true,
                onPressed: () => busy(
                    'remove $b',
                    () => runDokku(context, ref, host, ['buildpacks:remove', app, b],
                        ask: Confirm(
                          title: 'Remove this buildpack?',
                          body: '$b is no longer used from the next build.',
                          label: 'Remove buildpack',
                          danger: true,
                        )))),
          ]),
        ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: C.w(.02), border: Border(top: BorderSide(color: C.lineSoft))),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 460
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  urlInput,
                  const SizedBox(height: 8),
                  Row(children: [
                    SizedBox(width: 88, child: indexInput),
                    const Spacer(),
                    addButton,
                  ]),
                ])
              : Row(children: [
                  Expanded(child: urlInput),
                  const SizedBox(width: 8),
                  SizedBox(width: 64, child: indexInput),
                  const SizedBox(width: 8),
                  addButton,
                ]),
        ),
      ),
      CmdFooter('\$ ${displayCommand(addArgs)} ${url.isEmpty ? '<url>' : shq(url)}  ·  buildpacks:remove  ·  buildpacks:set'),
    ]);
  }
}

class _DockerfileCard extends ConsumerStatefulWidget {
  const _DockerfileCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_DockerfileCard> createState() => _DockerfileCardState();
}

class _DockerfileCardState extends ConsumerState<_DockerfileCard> with Busy {
  final _path = SyncedController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'builder-dockerfile', app);
    if (report.data != null) _path.sync(report.data!['builder dockerfile dockerfile path'] ?? '');
    final path = _path.text.trim();
    // Without a value the setting is cleared and the default applies again.
    final args = ['builder-dockerfile:set', app, 'dockerfile-path', if (path.isNotEmpty) path];

    return Panel.column(children: [
      const PanelHead('Dockerfile'),
      if (report.loading) const LoadingRows(),
      if (report.error != null) EmptyBox('Could not read the Dockerfile settings of $app: ${report.errorText}'),
      if (report.data != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Field(
            'Dockerfile path',
            hint: 'In use: ${firstFilled([report.data!['builder dockerfile computed dockerfile path']], 'Dockerfile')}',
            child: Row(children: [
              Expanded(child: AppInput(controller: _path.controller, hint: 'Dockerfile', onChanged: (_) => setState(() {}))),
              const SizedBox(width: 6),
              Btn('Save',
                  loading: isBusy('save'),
                  onPressed: _path.dirty ? () => busy('save', () => runDokku(context, ref, host, args)) : null),
            ]),
          ),
        ),
      CmdFooter('\$ ${displayCommand(args)}'),
    ]);
  }
}

class _EnvironmentCard extends ConsumerStatefulWidget {
  const _EnvironmentCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_EnvironmentCard> createState() => _EnvironmentCardState();
}

class _EnvironmentCardState extends ConsumerState<_EnvironmentCard> with Busy {
  final _dir = SyncedController();

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final builder = ref.report(host, 'builder', app);
    final buildpacks = ref.report(host, 'buildpacks', app);
    final b = builder.data;
    if (b != null) _dir.sync(b['builder build dir'] ?? '');
    final dir = _dir.text.trim();
    final args = ['builder:set', app, 'build-dir', if (dir.isNotEmpty) dir];

    return Panel.column(children: [
      const PanelHead('Build environment'),
      if (builder.loading) const LoadingRows(rows: 3),
      if (builder.error != null) EmptyBox('Could not read the build settings of $app: ${builder.errorText}'),
      if (b != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Field(
              'Build directory',
              hint: 'The folder of the repository to build, for monorepos. Leave empty to build from the root.',
              child: Row(children: [
                Expanded(child: AppInput(controller: _dir.controller, hint: '/', onChanged: (_) => setState(() {}))),
                const SizedBox(width: 6),
                Btn('Save',
                    loading: isBusy('save'),
                    onPressed: _dir.dirty ? () => busy('save', () => runDokku(context, ref, host, args)) : null),
              ]),
            ),
            const SizedBox(height: 12),
            KVList([
              ('Selected builder', firstFilled([b['builder selected']], 'auto')),
              ('Computed builder', firstFilled([b['builder computed selected'], b['builder detected']], '—')),
              ('Build stack', firstFilled([buildpacks.data?['buildpacks computed stack']], '—')),
              ('Computed build dir', firstFilled([b['builder computed build dir']], '/')),
            ]),
          ]),
        ),
      CmdFooter('\$ ${displayCommand(args)}  ·  builder:report $app'),
    ]);
  }
}
