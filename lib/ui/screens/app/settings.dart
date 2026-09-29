import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../../state/router.dart';
import '../../actions.dart';
import '../../shell/action_dialogs.dart' show appNamePattern, showCreateApp;
import '../../shell/destroy_dialog.dart';
import '../../widgets/kit.dart';
import 'shared.dart';

final _appNameChars = [
  TextInputFormatter.withFunction((_, next) => next.copyWith(text: next.text.toLowerCase())),
  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]')),
];
final _noSpaces = [FilteringTextInputFormatter.deny(RegExp(r'\s'))];

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context) => TwoCol(
        left: [_GeneralCard(host, app), _RegistryCard(host, app)],
        right: [
          _LockCard(host, app),
          _CloneCard(host, app),
          _DangerCard(host, app),
          Text('Host: ${host.name}', style: T.tiny),
        ],
      );
}

class _GeneralCard extends ConsumerStatefulWidget {
  const _GeneralCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_GeneralCard> createState() => _GeneralCardState();
}

class _GeneralCardState extends ConsumerState<_GeneralCard> with Busy {
  late final _rename = TextEditingController(text: widget.app);

  @override
  void dispose() {
    _rename.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = widget.app, name = _rename.text.trim();
    // The tab is replaced as soon as the old name disappears, so look this up first.
    final router = ref.read(routerProvider.notifier);
    final r = await busy(
      'rename',
      () => runDokku(context, ref, widget.host, ['apps:rename', app, name],
          ask: Confirm(
            title: 'Rename $app to $name?',
            body: 'Dokku redeploys the app under the new name and changes its git remote. '
                'Domains and config are kept. Update the remote in your local repository afterwards.',
            label: 'Rename app',
          ),
          timeout: const Duration(minutes: 30)),
    );
    if (r?.ok == true) router.go(AppDetailRoute(name, AppTab.settings));
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'apps', app);
    final git = ref.report(host, 'git', app).data;
    final names = ref.watch(appsProvider(host.id)).value?.names ?? const <String>[];
    final info = report.data ?? const <String, String>{};
    final name = _rename.text.trim();
    final taken = name != app && names.contains(name);
    final valid = name != app && !taken && appNamePattern.hasMatch(name);
    final source = (info['app deploy source'] ?? '').isEmpty ? 'git push' : info['app deploy source']!;
    final branch = [git?['git deploy branch'], git?['git global deploy branch']]
        .firstWhere((b) => b != null && b.isNotEmpty, orElse: () => 'master')!;

    return Panel.column(children: [
      const PanelHead('General'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Field(
          'App name',
          hint: taken
              ? 'An app with this name already exists.'
              : 'Renaming redeploys the app and changes its git remote. Domains and config are kept.',
          hintTone: taken ? Tone.bad : null,
          child: Row(children: [
            Expanded(
              child: AppInput(
                controller: _rename,
                inputFormatters: _appNameChars,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (valid) _submit();
                },
              ),
            ),
            const SizedBox(width: 6),
            Btn('Rename', loading: isBusy('rename'), onPressed: valid ? _submit : null),
          ]),
        ),
      ),
      cardPlaceholder(report, 'app details') ??
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: KVList([
              ('Created', dateOnly(info['app created at'])),
              ('Deploy source', '$source · $branch'),
              ('Locked', '${isYes(info['app locked'])}'),
              ('Directory', (info['app dir'] ?? '').isEmpty ? '/home/dokku/$app' : info['app dir']!),
            ]),
          ),
      CmdFooter('${footerCommand(['apps:rename', app, name.isEmpty || name == app ? '<new-name>' : name])}  ·  apps:report $app'),
    ]);
  }
}

class _RegistryCard extends ConsumerStatefulWidget {
  const _RegistryCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_RegistryCard> createState() => _RegistryCardState();
}

class _RegistryCardState extends ConsumerState<_RegistryCard> with Busy {
  final _server = SyncedController();
  final _repo = SyncedController();

  @override
  void dispose() {
    _server.dispose();
    _repo.dispose();
    super.dispose();
  }

  /// What saving would run. A blank field clears the property, which is
  /// `registry:set` without a value.
  List<List<String>> _changes(Report current) {
    final server = _server.text.trim(), repo = _repo.text.trim();
    List<String> set(String property, String value) => ['registry:set', widget.app, property, if (value.isNotEmpty) value];
    return [
      if (server != (current['registry server'] ?? '')) set('server', server),
      if (repo != (current['registry image repo'] ?? '')) set('image-repo', repo),
    ];
  }

  Future<void> _save(Report current) => busy('save', () => DokkuRunner(ref, widget.host).all(_changes(current)));

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'registry', app);
    final reg = report.data ?? const <String, String>{};
    if (report.data != null) {
      _server.sync(reg['registry server'] ?? '');
      _repo.sync(reg['registry image repo'] ?? '');
    }
    final server = _server.text.trim(), repo = _repo.text.trim();
    final changes = _changes(reg);
    final shown = changes.isNotEmpty
        ? changes
        : [
            ['registry:set', app, 'server', server.isEmpty ? '<server>' : server],
            ['registry:set', app, 'image-repo', repo.isEmpty ? '<repo>' : repo],
          ];
    String or(String? v, String fallback) => v == null || v.isEmpty ? fallback : v;

    return Panel.column(children: [
      const PanelHead('Container registry', note: 'push built images upstream'),
      cardPlaceholder(report, 'registry settings') ??
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              SwitchRow(
                title: 'Push on release',
                desc: 'Needed for k3s and other multi-host schedulers',
                value: isYes(reg['registry computed push on release']),
                busy: isBusy('push'),
                onChanged: (v) => busy('push', () => runDokku(context, ref, host, ['registry:set', app, 'push-on-release', '$v'])),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(builder: (context, box) {
                final fields = [
                  Field(
                    'Server',
                    child: AppInput(
                      controller: _server.controller,
                      hint: or(reg['registry global server'], 'ghcr.io'),
                      inputFormatters: _noSpaces,
                      keyboardType: TextInputType.url,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Field(
                    'Image repo',
                    child: AppInput(
                      controller: _repo.controller,
                      hint: or(reg['registry computed image repo'], 'dokku/$app'),
                      inputFormatters: _noSpaces,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ];
                if (box.maxWidth < 420) {
                  return Column(mainAxisSize: MainAxisSize.min, children: [fields[0], const SizedBox(height: 10), fields[1]]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: fields[0]),
                  const SizedBox(width: 10),
                  Expanded(child: fields[1]),
                ]);
              }),
              const SizedBox(height: 12),
              Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Log in to the registry once on the Server page, under Registry credentials. Computed image: '),
                  TextSpan(
                    text: '${reg['registry computed server'] ?? ''}${or(reg['registry computed image repo'], '—')}',
                    style: T.mono(10.5, color: C.muted),
                  ),
                ]),
                style: T.tiny,
              ),
            ]),
          ),
      CmdFooter(
        [
          for (final (i, args) in shown.indexed)
            i == 0 ? footerCommand(args) : footerCommand(args).substring('\$ dokku '.length),
        ].join('  ·  '),
        action: Btn('Save', loading: isBusy('save'), onPressed: changes.isEmpty ? null : () => _save(reg)),
      ),
    ]);
  }
}

class _LockCard extends ConsumerStatefulWidget {
  const _LockCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_LockCard> createState() => _LockCardState();
}

class _LockCardState extends ConsumerState<_LockCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final report = ref.report(host, 'apps', app);
    final locked = isYes(report.data?['app locked']);

    return Panel.column(children: [
      PanelHead(
        'Deploy lock',
        trailing: HeadSwitch(
          label: 'Deploy lock',
          value: locked,
          busy: isBusy('lock'),
          onChanged: report.data == null
              ? null
              : (v) => busy('lock', () => runDokku(context, ref, host, [v ? 'apps:lock' : 'apps:unlock', app])),
        ),
      ),
      cardPlaceholder(report, 'the deploy lock') ??
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Text(
              '${locked ? 'Deploys are blocked. Pushes are rejected until you unlock.' : 'Deploys are allowed. Lock to reject pushes for a while.'}'
              ' Useful during maintenance or while handling an incident.',
              style: T.small,
            ),
          ),
      CmdFooter('${footerCommand([locked ? 'apps:unlock' : 'apps:lock', app])}  ·  apps:locked $app'),
    ]);
  }
}

class _CloneCard extends StatelessWidget {
  const _CloneCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context) => Panel.column(children: [
        const PanelHead('Clone'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Expanded(
              child: Text('Create a new app with the config, domains, ports and settings of this one.', style: T.small),
            ),
            const SizedBox(width: 12),
            Btn('Clone app', onPressed: () => showCreateApp(context, host, cloneFrom: app)),
          ]),
        ),
      ]);
}

class _DangerCard extends ConsumerStatefulWidget {
  const _DangerCard(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_DangerCard> createState() => _DangerCardState();
}

class _DangerCardState extends ConsumerState<_DangerCard> with Busy {
  Future<void> _destroy() async {
    final app = widget.app;
    // The tab is gone once the app is, so look this up first.
    final router = ref.read(routerProvider.notifier);
    final r = await busy('destroy', () => destroyApp(context, ref, widget.host, app));
    if (r?.ok == true) router.section(const AppsRoute());
  }

  @override
  Widget build(BuildContext context) => Panel.column(danger: true, children: [
        const PanelHead('Danger zone', danger: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text.rich(
              const TextSpan(children: [
                TextSpan(
                    text: 'Destroying removes containers, images, config, domains and the variables set by linked services. '
                        'Storage directories on the host are '),
                TextSpan(text: 'not', style: TextStyle(color: C.fg)),
                TextSpan(text: ' deleted.'),
              ]),
              style: T.small,
            ),
            const SizedBox(height: 10),
            Btn('Destroy app', variant: BtnVariant.danger, loading: isBusy('destroy'), onPressed: _destroy),
          ]),
        ),
        CmdFooter(footerCommand(destroyAppArgs(widget.app))),
      ]);
}
