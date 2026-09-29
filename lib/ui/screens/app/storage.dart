import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../actions.dart';
import '../../widgets/kit.dart';
import 'shared.dart';

const _phases = ['build', 'deploy', 'run'];
const _owners = ['herokuish', 'heroku', 'paketo', 'root', 'false'];
const _storageRoot = '/var/lib/dokku/data/storage';

const _networkProps = [
  ('initial-network', 'Initial network', 'Network the container is created on'),
  ('attach-post-create', 'Attach after create', 'Joined right after the container is created'),
  ('attach-post-deploy', 'Attach after deploy', 'Joined once the container is running'),
];

final _path = RegExp(r'^/\S+$');
final _name = RegExp(r'^[\w.-]+$');
final _nameChars = [FilteringTextInputFormatter.allow(RegExp(r'[\w.-]'))];

class StorageTab extends StatelessWidget {
  const StorageTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _VolumesCard(host, app),
          const SizedBox(height: 16),
          TwoCol(left: [_DockerOptionsCard(host, app)], right: [_NetworksCard(host, app)]),
        ],
      );
}

class _VolumesCard extends ConsumerStatefulWidget {
  const _VolumesCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_VolumesCard> createState() => _VolumesCardState();
}

class _VolumesCardState extends ConsumerState<_VolumesCard> with Busy {
  /// Dokku stores a mount as one string and only removes an exact match.
  static String _spec(Mount m) => '${m.host}:${m.container}${m.options.isEmpty ? '' : ':${m.options}'}';

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final mounts = ref.dokku(host, ['storage:list', app, '--format', 'json'], (r) => parseStorage(r.stdout));
    final list = mounts.data ?? const <Mount>[];

    Widget unmount(Mount m) => Btn(
          'Unmount',
          variant: BtnVariant.dangerGhost,
          size: BtnSize.xs,
          loading: isBusy(_spec(m)),
          onPressed: () => busy(
            _spec(m),
            () => runDokku(context, ref, host, ['storage:unmount', app, _spec(m)],
                ask: Confirm(
                  title: 'Unmount volume?',
                  body: 'Detaches ${m.container} on the next deploy or restart. Files on the host are kept.',
                  label: 'Unmount',
                  danger: true,
                )),
          ),
        );
    Widget hostPath(Mount m, {int lines = 1}) => Row(children: [
          const Icon(LucideIcons.hardDrive, size: 13, color: C.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(m.host, maxLines: lines, overflow: TextOverflow.ellipsis, style: T.code)),
        ]);
    Widget containerPath(Mount m, {int lines = 1}) => Row(children: [
          const Icon(LucideIcons.arrowRight, size: 12, color: C.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(m.container, maxLines: lines, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: C.soft)),
          ),
        ]);

    return Panel.column(children: [
      PanelHead('Persistent storage',
          trailing: Btn('Mount volume',
              icon: LucideIcons.plus, onPressed: () => showAppDialog<void>(context, (_) => _MountDialog(host, app)))),
      ?cardPlaceholder(mounts, 'mounted volumes'),
      if (mounts.data != null && list.isEmpty)
        const EmptyBox('No volumes are mounted. Files written inside the container are lost on every deploy.'),
      if (list.isNotEmpty)
        LayoutBuilder(builder: (context, box) {
          // Two long paths do not fit side by side on a phone, so they stack.
          final wide = box.maxWidth >= 560;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            THead(wide
                ? [th('host path'), th('container path'), th('options', width: 120), const SizedBox(width: 90)]
                : [th('volume')]),
            for (final m in list)
              PanelRow(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: wide
                    ? Row(children: [
                        Expanded(child: Padding(padding: const EdgeInsets.only(right: 16), child: hostPath(m))),
                        Expanded(child: Padding(padding: const EdgeInsets.only(right: 16), child: containerPath(m))),
                        SizedBox(
                          width: 120,
                          child: Text(m.options.isEmpty ? '—' : m.options,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.muted)),
                        ),
                        SizedBox(width: 90, child: Align(alignment: Alignment.centerRight, child: unmount(m))),
                      ])
                    : Row(children: [
                        Expanded(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            hostPath(m, lines: 2),
                            const SizedBox(height: 4),
                            containerPath(m, lines: 2),
                            if (m.options.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text('options ${m.options}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.muted)),
                              ),
                            ],
                          ]),
                        ),
                        const SizedBox(width: 12),
                        unmount(m),
                      ]),
              ),
          ]);
        }),
      CmdFooter(
        '${footerCommand(['storage:mount', app, '$_storageRoot/$app:/app/storage'])}  ·  storage:unmount  ·  storage:list'
        '  ·  restart the app to apply',
      ),
    ]);
  }
}

class _MountDialog extends ConsumerStatefulWidget {
  const _MountDialog(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_MountDialog> createState() => _MountDialogState();
}

class _MountDialogState extends ConsumerState<_MountDialog> with Busy {
  final _storage = TextEditingController();
  final _hostPath = TextEditingController();
  final _container = TextEditingController(text: '/app/storage');
  var _owner = _owners.first;

  @override
  void dispose() {
    for (final c in [_storage, _hostPath, _container]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final name = _storage.text, existing = _hostPath.text.trim(), container = _container.text.trim();
    // A path the user typed wins over the managed directory.
    final managed = existing.isEmpty && name.isNotEmpty;
    final hostPath = existing.isNotEmpty ? existing : (managed ? '$_storageRoot/$name' : '');
    final valid = _path.hasMatch(hostPath) && _path.hasMatch(container);
    final ensure = ['storage:ensure-directory', if (_owner != _owners.first) ...['--chown', _owner], name];
    final mount = [
      'storage:mount',
      app,
      '${hostPath.isEmpty ? '<host-path>' : hostPath}:${container.isEmpty ? '<container-path>' : container}',
    ];

    Future<void> submit() => busy('mount', () async {
          final run = DokkuRunner(ref, host);
          if (managed) {
            // Creates the directory with the right owner for the build stack.
            final r = await run(ensure, title: 'Create storage directory');
            if (!r.ok) return;
          }
          final r = await run(mount);
          if (r.ok && context.mounted) Navigator.of(context).pop();
        });

    return AppDialog(
      title: 'Mount a volume',
      width: 480,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Mount volume',
            size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('mount'), onPressed: valid ? submit : null),
      ],
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Field(
              'Storage name (managed)',
              child: AppInput(
                controller: _storage,
                large: true,
                hint: app,
                inputFormatters: _nameChars,
                onChanged: (_) => setState(_hostPath.clear),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Field(
              'Owner',
              child: AppSelect<String>(value: _owner, options: _owners, onChanged: (v) => setState(() => _owner = v)),
            ),
          ),
        ]),
        Field(
          'Or an existing host path',
          child: AppInput(controller: _hostPath, large: true, hint: '/srv/data/uploads', onChanged: (_) => setState(() {})),
        ),
        Field(
          'Container path',
          child: AppInput(controller: _container, large: true, hint: '/app/storage', onChanged: (_) => setState(() {})),
        ),
        CodeBlock([if (managed) footerCommand(ensure), footerCommand(mount)].join('\n')),
      ],
    );
  }
}

class _DockerOptionsCard extends ConsumerStatefulWidget {
  const _DockerOptionsCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_DockerOptionsCard> createState() => _DockerOptionsCardState();
}

class _DockerOptionsCardState extends ConsumerState<_DockerOptionsCard> with Busy {
  var _phase = 'deploy';
  final _flag = TextEditingController();

  @override
  void dispose() {
    _flag.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final flag = _flag.text.trim(), phase = _phase;
    if (!flag.startsWith('-')) return;
    await busy('add', () async {
      final r = await runDokku(context, ref, widget.host, ['docker-options:add', widget.app, phase, flag]);
      if (r?.ok == true) _flag.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'docker-options', app);
    final flags = splitDockerOptions(report.data?['docker options $_phase']);
    final typed = _flag.text.trim();

    return Panel.column(children: [
      PanelHead('Docker options',
          trailing: Seg<String>(small: true, value: _phase, options: _phases, onChanged: (p) => setState(() => _phase = p))),
      ?cardPlaceholder(report, 'Docker options'),
      if (report.data != null && flags.isEmpty) EmptyBox('No extra flags for the $_phase phase.'),
      for (final (i, flag) in flags.indexed)
        PanelRow(
          first: i == 0,
          padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
          child: Row(children: [
            Expanded(child: Text(flag, style: T.code)),
            const SizedBox(width: 8),
            RemoveBtn(
              tooltip: 'Remove flag',
              busy: isBusy('remove $_phase $flag'),
              onPressed: () {
                final phase = _phase;
                busy('remove $phase $flag', () => runDokku(context, ref, host, ['docker-options:remove', app, phase, flag]));
              },
            ),
          ]),
        ),
      PanelRow(
        tint: C.w(.02),
        child: Row(children: [
          Expanded(
            child: AppInput(
              controller: _flag,
              hint: '--shm-size=256m',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          Btn('Add flag', loading: isBusy('add'), onPressed: typed.startsWith('-') ? _add : null),
        ]),
      ),
      CmdFooter(
        '${footerCommand(['docker-options:add', app, _phase, typed.isEmpty ? '<flag>' : typed])}'
        '  ·  docker-options:remove  ·  docker-options:report',
      ),
    ]);
  }
}

class _NetworksCard extends ConsumerStatefulWidget {
  const _NetworksCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_NetworksCard> createState() => _NetworksCardState();
}

class _NetworksCardState extends ConsumerState<_NetworksCard> with Busy {
  final _network = TextEditingController();

  @override
  void dispose() {
    _network.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _network.text;
    if (name.isEmpty) return;
    await busy('create', () async {
      final r = await runDokku(context, ref, widget.host, ['network:create', name]);
      if (r?.ok == true) _network.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'network', app);
    final networks = ref.dokku(host, ['network:list'], (r) => parseLines(r.stdout).where(_name.hasMatch).toList());
    final net = report.data ?? const <String, String>{};
    final names = networks.data ?? const <String>[];
    // An app cannot be attached to Docker's own "none" and "host" networks.
    final choices = ['', for (final n in names) if (n != 'none' && n != 'host') n];
    final bind = isYes(net['network bind all interfaces']);
    final typed = _network.text;

    return Panel.column(children: [
      PanelHead(
        'Networks',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: AppInput(
                controller: _network,
                hint: 'new-network',
                inputFormatters: _nameChars,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _create(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Btn('Create network', loading: isBusy('create'), onPressed: typed.isEmpty ? null : _create),
        ]),
      ),
      ?cardPlaceholder(report, 'network settings'),
      if (report.data != null) ...[
        for (final (i, (prop, title, note)) in _networkProps.indexed)
          () {
            final key = prop.replaceAll('-', ' ');
            final current = net['network $key'] ?? '';
            final inherited = net['network computed $key'] ?? '';
            return _SettingRow(
              first: i == 0,
              title: title,
              note: '$prop · $note${current.isEmpty && inherited.isNotEmpty ? ' · global: $inherited' : ''}',
              fill: true,
              control: AppSelect<String>(
                value: current,
                options: [...choices, if (!choices.contains(current)) current],
                labels: (n) => n.isEmpty ? '(none)' : n,
                enabled: !isBusy(prop),
                onChanged: (v) {
                  if (v == current) return;
                  // Setting a property without a value clears it.
                  busy(prop, () => runDokku(context, ref, host, ['network:set', app, prop, if (v.isNotEmpty) v]));
                },
              ),
            );
          }(),
        _SettingRow(
          title: 'Bind all interfaces',
          note: 'bind-all-interfaces · publish ports on 0.0.0.0 instead of the Docker bridge',
          control: Seg<String>(
            small: true,
            mono: true,
            value: '$bind',
            options: const ['false', 'true'],
            onChanged: isBusy('bind')
                ? null
                : (v) {
                    if (v == '$bind') return;
                    busy('bind', () => runDokku(context, ref, host, ['network:set', app, 'bind-all-interfaces', v]));
                  },
          ),
        ),
      ],
      if (names.isNotEmpty)
        PanelRow(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('available: ${names.join(' · ')}', style: T.meta),
        ),
      CmdFooter(
        '${footerCommand(['network:create', typed.isEmpty ? '<name>' : typed])}'
        '  ·  network:set $app attach-post-create <network>  ·  network:report',
      ),
    ]);
  }
}

/// A labelled control that moves below its label when there is no room beside it.
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.title, required this.note, required this.control, this.fill = false, this.first = false});
  final String title;
  final String note;
  final Widget control;

  /// Whether the control takes the full width it is given, like a dropdown.
  final bool fill;
  final bool first;

  @override
  Widget build(BuildContext context) => PanelRow(
        first: first,
        child: LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 420;
          final label = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: T.body),
            const SizedBox(height: 2),
            Text(note, maxLines: narrow ? 3 : 2, overflow: TextOverflow.ellipsis, style: T.meta),
          ]);
          if (narrow) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              label,
              const SizedBox(height: 8),
              fill ? control : Align(alignment: Alignment.centerLeft, child: control),
            ]);
          }
          return Row(children: [
            Expanded(child: label),
            const SizedBox(width: 12),
            SizedBox(width: 180, child: fill ? control : Align(alignment: Alignment.centerRight, child: control)),
          ]);
        }),
      );
}
