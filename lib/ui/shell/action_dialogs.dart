import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/command.dart';
import '../../data/models.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../widgets/kit.dart';
import 'terminal.dart';

final appNamePattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final _repoPattern = RegExp(r'^(https?://|git@|ssh://)\S+$');
final _lowercase = [FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]'))];

/// Creates an app, starting from the settings of [cloneFrom] when given.
Future<void> showCreateApp(BuildContext context, Host host, {String? cloneFrom}) =>
    showAppDialog<void>(context, (_) => _CreateAppDialog(host, cloneFrom));

class _CreateAppDialog extends ConsumerStatefulWidget {
  const _CreateAppDialog(this.host, this.cloneFrom);
  final Host host;
  final String? cloneFrom;

  @override
  ConsumerState<_CreateAppDialog> createState() => _CreateAppDialogState();
}

class _CreateAppDialogState extends ConsumerState<_CreateAppDialog> with Busy {
  final _name = TextEditingController();
  late String _cloneFrom = widget.cloneFrom ?? '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.watch(appsProvider(widget.host.id)).value?.names ?? const <String>[];
    final name = _name.text;
    final exists = apps.contains(name);
    final valid = appNamePattern.hasMatch(name) && !exists;
    final args = _cloneFrom.isEmpty ? ['apps:create', name] : ['apps:clone', _cloneFrom, name];

    Future<void> submit() async {
      if (!valid) return;
      final r = await busy('create', () => runDokku(context, ref, widget.host, args, title: 'Create $name'));
      if (r?.ok != true || !context.mounted) return;
      Navigator.of(context).pop();
      ref.read(routerProvider.notifier).go(AppDetailRoute(name, AppTab.deploys));
    }

    return AppDialog(
      title: widget.cloneFrom == null ? 'Create app' : 'Clone ${widget.cloneFrom}',
      width: 440,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn(_cloneFrom.isEmpty ? 'Create app' : 'Clone app',
            size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('create'), onPressed: valid ? submit : null),
      ],
      children: [
        Field(
          'App name',
          hint: exists
              ? 'An app with this name already exists.'
              : 'Lowercase letters, digits and dashes. Becomes the git remote and default subdomain.',
          hintTone: exists ? Tone.bad : null,
          child: AppInput(
              controller: _name,
              large: true,
              autofocus: true,
              hint: 'api-gateway',
              inputFormatters: _lowercase,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => submit()),
        ),
        if (apps.isNotEmpty)
          Field(
            'Copy settings from (optional)',
            hint: 'Copies config, domains, ports and other settings with apps:clone.',
            child: AppSelect<String>(
              value: _cloneFrom,
              options: ['', ...apps, if (_cloneFrom.isNotEmpty && !apps.contains(_cloneFrom)) _cloneFrom],
              labels: (a) => a.isEmpty ? 'Start empty' : a,
              onChanged: (v) => setState(() => _cloneFrom = v),
            ),
          ),
        CodeBlock('\$ ${displayCommand(name.isEmpty ? [args.first, ...args.skip(1).where((a) => a.isNotEmpty), '<name>'] : args)}'),
      ],
    );
  }
}

enum _DeployMode { push, sync, image }

Future<void> showDeploy(BuildContext context, Host host, {String? app}) =>
    showAppDialog<void>(context, (_) => _DeployDialog(host, app));

class _DeployDialog extends ConsumerStatefulWidget {
  const _DeployDialog(this.host, this.initialApp);
  final Host host;
  final String? initialApp;

  @override
  ConsumerState<_DeployDialog> createState() => _DeployDialogState();
}

class _DeployDialogState extends ConsumerState<_DeployDialog> {
  late String? _app = widget.initialApp;
  var _mode = _DeployMode.push;
  var _build = true;
  final _repo = TextEditingController();
  final _ref = TextEditingController();
  final _image = TextEditingController();
  final _branch = TextEditingController(text: 'main');

  @override
  void dispose() {
    for (final c in [_repo, _ref, _image, _branch]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final apps = ref.watch(appsProvider(host.id)).value?.names ?? const <String>[];
    final app = _app != null && apps.contains(_app) ? _app! : (apps.firstOrNull ?? '');
    final git = app.isEmpty ? null : ref.report(host, 'git', app).data;
    final deployBranch = [git?['git deploy branch'], git?['git computed deploy branch'], git?['git global deploy branch']]
        .firstWhere((b) => b != null && b.isNotEmpty, orElse: () => 'master')!;
    final shownApp = app.isEmpty ? '<app>' : app;
    final branch = _branch.text.trim().isEmpty ? 'main' : _branch.text.trim();
    final syncArgs = ['git:sync', if (_build) '--build', app, _repo.text.trim(), if (_ref.text.trim().isNotEmpty) _ref.text.trim()];
    final imageArgs = ['git:from-image', app, _image.text.trim()];

    Future<void> deploy(List<String> args) async {
      Navigator.of(context).pop();
      final router = ref.read(routerProvider.notifier);
      final r = await runDokku(context, ref, host, args, title: 'Deploy $app');
      if (r?.ok == true) router.go(AppDetailRoute(app));
    }

    return AppDialog(
      title: 'Deploy app',
      subtitle: 'Push with git, sync from a repository, or deploy a ready-made image.',
      width: 540,
      actions: [
        Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        if (_mode == _DeployMode.sync)
          Btn('Sync & deploy',
              size: BtnSize.md,
              variant: BtnVariant.primary,
              onPressed: app.isNotEmpty && _repoPattern.hasMatch(_repo.text.trim()) ? () => deploy(syncArgs) : null),
        if (_mode == _DeployMode.image)
          Btn('Deploy image',
              size: BtnSize.md,
              variant: BtnVariant.primary,
              onPressed: app.isNotEmpty && RegExp(r'^\S+$').hasMatch(_image.text.trim()) ? () => deploy(imageArgs) : null),
      ],
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Field('App',
                child: AppSelect<String>(
                    value: app, options: apps, hint: 'No apps yet', onChanged: (v) => setState(() => _app = v))),
          ),
          const SizedBox(width: 10),
          Btn('New app', icon: LucideIcons.plus, onPressed: () {
            Navigator.of(context).pop();
            showCreateApp(context, host);
          }),
        ]),
        Seg<_DeployMode>(
          value: _mode,
          options: _DeployMode.values,
          labels: (m) => switch (m) { _DeployMode.push => 'git push', _DeployMode.sync => 'Sync repository', _DeployMode.image => 'Docker image' },
          onChanged: (m) => setState(() => _mode = m),
        ),
        if (_mode == _DeployMode.push) ...[
          Text('Add the Dokku remote to your local repository and push. Your SSH key must be registered on the Server page.',
              style: T.small),
          Field('Branch to push', child: AppInput(controller: _branch, onChanged: (_) => setState(() {}))),
          for (final c in ['git remote add dokku ${host.gitRemote(shownApp)}', 'git push dokku $branch:$deployBranch'])
            Container(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              decoration: BoxDecoration(color: C.term, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Expanded(child: SelectableText('\$ $c', style: T.mono(11.5, color: C.soft))),
                CopyBtn(c),
              ]),
            ),
          Text('This app deploys pushes to $deployBranch. Change that in the app\'s Deploys tab.', style: T.tiny),
        ],
        if (_mode == _DeployMode.sync) ...[
          Field('Repository URL',
              child: AppInput(controller: _repo, hint: 'https://github.com/acme/api-gateway.git', onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.url)),
          Field('Branch, tag or commit (optional)', child: AppInput(controller: _ref, hint: 'main', onChanged: (_) => setState(() {}))),
          AppCheckbox(value: _build, onChanged: (v) => setState(() => _build = v), label: 'Build after sync (--build)'),
          CodeBlock('\$ ${displayCommand([...syncArgs.where((a) => a.isNotEmpty)])}'),
        ],
        if (_mode == _DeployMode.image) ...[
          Field('Image',
              hint: 'Any image the server can pull, from Docker Hub or a registry you logged in to.',
              child: AppInput(controller: _image, hint: 'ghcr.io/acme/api:1.4.2', onChanged: (_) => setState(() {}))),
          CodeBlock('\$ dokku git:from-image $shownApp ${_image.text.trim().isEmpty ? '<image>' : _image.text.trim()}'),
        ],
      ],
    );
  }
}

Future<void> showProvision(BuildContext context, Host host, {String? type}) =>
    showAppDialog<void>(context, (_) => _ProvisionDialog(host, type));

class _ProvisionDialog extends ConsumerStatefulWidget {
  const _ProvisionDialog(this.host, this.initialType);
  final Host host;
  final String? initialType;

  @override
  ConsumerState<_ProvisionDialog> createState() => _ProvisionDialogState();
}

class _ProvisionDialogState extends ConsumerState<_ProvisionDialog> with Busy {
  late String _type = widget.initialType ?? 'postgres';
  late final _name = TextEditingController(text: '$_type-${_suffix()}');
  late final _version = TextEditingController(text: datastoreOf(_type)?.version ?? '');
  final _port = TextEditingController();
  final _links = <String>{};

  static String _suffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(4, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  void dispose() {
    for (final c in [_name, _version, _port]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final state = ref.watch(datastoresProvider(host.id)).value;
    final available = state?.available ?? const <DatastoreDef>[];
    if (available.isNotEmpty && !available.any((d) => d.type == _type)) {
      _type = available.first.type;
      _version.text = available.first.version;
    }
    final def = datastoreOf(_type);
    final apps = ref.watch(appsProvider(host.id)).value?.names ?? const <String>[];
    final name = _name.text.trim(), version = _version.text.trim(), port = _port.text.trim();
    final commands = [
      ['$_type:create', name, if (version.isNotEmpty) ...['--image-version', version]],
      if (port.isNotEmpty) ['$_type:expose', name, port],
      for (final a in _links) ['$_type:link', name, a],
    ];
    final valid = RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(name) &&
        (port.isEmpty || RegExp(r'^\d{2,5}$').hasMatch(port)) &&
        (state?.installed(_type) ?? false);

    Future<void> submit() async {
      final r = await busy('create', () => DokkuRunner(ref, host).all(commands, timeout: const Duration(minutes: 15)));
      // After a failure the form stays open, so a name that is taken can be changed.
      if (r?.ok == true && context.mounted) Navigator.of(context).pop();
    }

    return AppDialog(
      title: 'Provision ${def?.name ?? _type} service',
      width: 480,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Create service', size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('create'), onPressed: valid ? submit : null),
      ],
      children: [
        if (available.length > 1)
          Seg<String>(
            value: _type,
            options: [for (final d in available) d.type],
            labels: (t) => datastoreOf(t)?.name ?? t,
            onChanged: (t) => setState(() {
              _type = t;
              _version.text = datastoreOf(t)?.version ?? '';
            }),
          ),
        Field('Service name', child: AppInput(controller: _name, large: true, onChanged: (_) => setState(() {}))),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Field('Image version',
                hint: 'Leave blank for the plugin default.',
                child: AppInput(controller: _version, large: true, onChanged: (_) => setState(() {}))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Field('Expose on host port',
                hint: 'Opens it to outside traffic.',
                child: AppInput(
                    controller: _port,
                    large: true,
                    hint: 'none',
                    inputFormatters: digitsOnly,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}))),
          ),
        ]),
        Field(
          'Link to apps after create (sets ${def?.envVar ?? 'the connection URL'})',
          child: apps.isEmpty
              ? Text('No apps to link.', style: T.tiny)
              : Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final a in apps)
                    _Chip(a, selected: _links.contains(a), onTap: () => setState(() => _links.contains(a) ? _links.remove(a) : _links.add(a))),
                ]),
        ),
        CodeBlock(commands.map((c) => '\$ ${displayCommand(c)}').join('\n')),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4 + touchPad(context) / 2),
              decoration: BoxDecoration(
                color: selected ? C.ok.withValues(alpha: .14) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? C.ok.withValues(alpha: .35) : C.lineStrong),
              ),
              child: Text(label, style: T.mono(11, color: selected ? C.ok : C.soft)),
            ),
          ),
        ),
      );
}

class _Hit {
  const _Hit(this.label, this.group, this.icon, this.run, {this.hint});
  final String label;
  final String group;
  final IconData icon;
  final VoidCallback run;
  final String? hint;
}

/// Jump to any app, section, domain or service.
Future<void> showSearch_(BuildContext context, Host host) =>
    showAppDialog<void>(context, (_) => _SearchDialog(host));

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog(this.host);
  final Host host;

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  final _query = TextEditingController();
  var _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final router = ref.read(routerProvider.notifier);
    final apps = ref.watch(appsProvider(host.id)).value?.apps ?? const <AppSummary>[];
    final services = ref.watch(datastoresProvider(host.id)).value?.services ?? const <Service>[];
    final navigator = Navigator.of(context);

    VoidCallback go(AppRoute r) => () {
          navigator.pop();
          r is AppDetailRoute ? router.go(r) : router.section(r);
        };
    VoidCallback then(void Function() action) => () {
          navigator.pop();
          action();
        };

    final all = <_Hit>[
      _Hit('Dashboard', 'Pages', LucideIcons.layoutDashboard, go(const DashboardRoute())),
      _Hit('Apps', 'Pages', LucideIcons.box, go(const AppsRoute())),
      _Hit('Datastores', 'Pages', LucideIcons.database, go(const DatastoresRoute())),
      _Hit('Logs & monitoring', 'Pages', LucideIcons.activity, go(const MonitoringRoute())),
      _Hit('Server & SSH', 'Pages', LucideIcons.server, go(const ServerRoute())),
      _Hit('Create app', 'Actions', LucideIcons.plus, then(() => showCreateApp(context, host))),
      _Hit('Deploy app', 'Actions', LucideIcons.arrowUp, then(() => showDeploy(context, host))),
      _Hit('Provision datastore', 'Actions', LucideIcons.database, then(() => showProvision(context, host))),
      if (host.hasShell)
        _Hit('Open SSH terminal', 'Actions', LucideIcons.terminal, then(() => openTerminal(context, host, const TerminalSpec.shell()))),
      for (final a in apps) ...[
        _Hit(a.name, 'Apps', LucideIcons.box, go(AppDetailRoute(a.name)), hint: a.health.name),
        for (final d in a.domains) _Hit(d, 'Domains', LucideIcons.globe, go(AppDetailRoute(a.name, AppTab.routing)), hint: a.name),
      ],
      for (final s in services) _Hit(s.name, 'Services', LucideIcons.database, go(const DatastoresRoute()), hint: s.type),
    ];
    final sections = <_Hit>[
      for (final a in apps)
        for (final t in AppTab.values.skip(1)) _Hit('${a.name} › ${t.label}', 'App sections', LucideIcons.box, go(AppDetailRoute(a.name, t))),
    ];

    final q = _query.text.trim().toLowerCase();
    final hits = (q.isEmpty ? all : [...all, ...sections].where((h) => '${h.label} ${h.hint ?? ''} ${h.group}'.toLowerCase().contains(q)))
        .take(60)
        .toList();
    final selected = hits.isEmpty ? 0 : _selected.clamp(0, hits.length - 1);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.fromLTRB(16, Bp.isCompact(context) ? 16 : 96, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.lineStrong),
            boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 20))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
              child: Row(children: [
                const Icon(LucideIcons.search, size: 14, color: C.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Focus(
                    onKeyEvent: (_, e) {
                      if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
                      if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                        setState(() => _selected = (selected + 1).clamp(0, max(0, hits.length - 1)));
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                        setState(() => _selected = (selected - 1).clamp(0, max(0, hits.length - 1)));
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      autocorrect: false,
                      style: T.sans(13.5),
                      cursorWidth: 1.2,
                      onChanged: (_) => setState(() => _selected = 0),
                      onSubmitted: (_) {
                        if (hits.isNotEmpty) hits[selected].run();
                      },
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 16),
                        hintText: 'Search apps, services, domains, actions…',
                        hintStyle: T.sans(13.5, color: C.dim),
                      ),
                    ),
                  ),
                ),
                const Kbd('esc'),
              ]),
            ),
            Flexible(
              child: hits.isEmpty
                  ? Padding(padding: const EdgeInsets.all(24), child: Text('No matches.', style: T.small))
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(6),
                      itemCount: hits.length,
                      itemBuilder: (_, i) {
                        final h = hits[i];
                        return Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            onTap: h.run,
                            onHover: (over) {
                              if (over) setState(() => _selected = i);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8 + touchPad(context) / 2),
                              decoration: BoxDecoration(
                                  color: i == selected ? C.w(.08) : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                              child: Row(children: [
                                Icon(h.icon, size: 13, color: C.muted),
                                const SizedBox(width: 10),
                                Expanded(child: Text(h.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body)),
                                if (h.hint != null) ...[Text(h.hint!, style: T.meta), const SizedBox(width: 8)],
                                Text(h.group.toUpperCase(), style: T.mono(10, color: C.dim, spacing: .4)),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
