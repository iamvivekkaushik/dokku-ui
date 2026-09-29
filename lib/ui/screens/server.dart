import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/command.dart';
import '../../core/format.dart';
import '../../core/host_scripts.dart';
import '../../core/install_script.dart' show publicKeyPattern;
import '../../core/parse.dart';
import '../../data/models.dart';
import '../../data/platform.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../shell/connect_dialog.dart';
import '../widgets/kit.dart';
import 'stream_run.dart';

const _needsRoot = 'Needs root. Connect as root or a sudo user.';
const _upgradeDocs = 'https://dokku.com/docs/getting-started/upgrading/';

const _globalCommands = [
  ['domains:report', '--global'],
  ['proxy:report'],
  ['scheduler:report'],
  ['registry:report'],
  ['config:export', '--global', '--format', 'json'],
  ['git:report'],
];

class _Globals {
  const _Globals({
    required this.domains,
    required this.proxy,
    required this.scheduler,
    required this.registry,
    required this.git,
    required this.envCount,
  });
  final Report domains;
  final Report proxy;
  final Report scheduler;
  final Report registry;
  final Report git;
  final int envCount;
}

_Globals _parseGlobals(List<ExecResult> r) {
  if (r.every((x) => !x.ok)) throw DokkuError(r.first);
  var envCount = 0;
  try {
    final env = jsonDecode(r[4].stdout.trim().isEmpty ? '{}' : r[4].stdout.trim());
    if (env is Map) envCount = env.length;
  } on FormatException {
    // not JSON: an older Dokku, count nothing
  }
  return _Globals(
    domains: parseReport(r[0].stdout),
    proxy: parseReport(r[1].stdout),
    scheduler: parseReport(r[2].stdout),
    registry: parseReport(r[3].stdout),
    git: parseReport(r[5].stdout),
    envCount: envCount,
  );
}

final _noKeys = RegExp(r'authorized_keys (is empty|not found)', caseSensitive: false);

List<SshKey> _parseKeys(ExecResult r) {
  // Dokku exits non-zero when no key is registered; anything else is a failure.
  if (!r.ok && !_noKeys.hasMatch(r.output)) throw DokkuError(r);
  return parseSshKeys(r.stdout);
}

Q<_Globals> _globals(WidgetRef ref, Host host) => ref.batch(host, _globalCommands, _parseGlobals);

Q<List<PluginInfo>> _plugins(WidgetRef ref, Host host) =>
    ref.dokku(host, const ['plugin:list'], (r) => parsePlugins(r.stdout));

/// The installed version, or null while it is unknown.
String? _dokkuVersion(AsyncValue<Map<String, String>> system) {
  final v = system.value?['dokku'] ?? '';
  return v.isEmpty ? null : v;
}

Future<void> _openLink(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on Object {
    // no browser to hand the link to
  }
}

class ServerScreen extends StatelessWidget {
  const ServerScreen({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context) => PageBody(children: [
        PageHead(eyebrow: host.name, title: 'Server & SSH settings'),
        if (!host.hasShell)
          AlertBox(
            tone: Tone.info,
            title: 'Connected as the dokku user.',
            text: 'SSH keys, plugin installs, upgrades, host metrics and the terminal need root. '
                'Edit the connection to sign in as root or a sudo user.',
            action: Btn('Edit connection', onPressed: () => showConnectDialog(context, editing: host)),
          ),
        TwoCol(leftFlex: 7, rightFlex: 5, left: [_KeysCard(host)], right: [_SystemCard(host)]),
        TwoCol(leftFlex: 7, rightFlex: 5, left: [_InstallationCard(host)], right: [_GlobalCard(host)]),
        TwoCol(left: [_PluginsCard(host)], right: [_RegistryCard(host)]),
      ]);
}

/// Title and a mono detail line on the left, a control on the right.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.title, required this.detail, required this.trailing, this.first = false});
  final String title;
  final String detail;
  final Widget trailing;
  final bool first;

  @override
  Widget build(BuildContext context) => PanelRow(
        first: first,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: T.body),
              const SizedBox(height: 3),
              Text(detail, style: T.mono(10.5, color: C.muted, height: 1.45)),
            ]),
          ),
          const SizedBox(width: 12),
          trailing,
        ]),
      );
}

class _KeysCard extends ConsumerStatefulWidget {
  const _KeysCard(this.host);
  final Host host;

  @override
  ConsumerState<_KeysCard> createState() => _KeysCardState();
}

class _KeysCardState extends ConsumerState<_KeysCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final root = host.hasShell;
    final keys = ref.dokku(host, const ['ssh-keys:list', '--format', 'json'], _parseKeys, lenient: true);
    final list = keys.data ?? const <SshKey>[];

    return Panel.column(children: [
      PanelHead(
        'Authorized SSH keys',
        trailing: Btn('Add key',
            icon: LucideIcons.plus,
            tooltip: root ? null : _needsRoot,
            onPressed: root ? () => showAppDialog<void>(context, (_) => _AddKeyDialog(host)) : null),
      ),
      if (keys.loading) const LoadingRows(rows: 1),
      if (keys.error != null) EmptyBox('Could not list the SSH keys: ${keys.errorText}'),
      if (keys.hasData && list.isEmpty) const EmptyBox('No deploy keys registered. Add one so developers can git push.'),
      for (final (i, k) in list.indexed)
        PanelRow(
          first: i == 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(k.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, weight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text([k.fingerprint, ?k.keyType, ?k.comment].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
              ]),
            ),
            const SizedBox(width: 12),
            Btn(
              'Revoke',
              variant: BtnVariant.dangerGhost,
              size: BtnSize.xs,
              tooltip: root ? null : _needsRoot,
              loading: isBusy('rm-${k.name}'),
              onPressed: root
                  ? () => busy(
                        'rm-${k.name}',
                        () => runDokku(
                          context,
                          ref,
                          host,
                          ['ssh-keys:remove', k.name],
                          ask: Confirm(
                            title: 'Revoke ${k.name}?',
                            body: 'Anyone using this key loses git push and Dokku SSH access immediately. '
                                'If this app signs in to ${host.name} with this key, you will be locked out too.',
                            label: 'Revoke key',
                            danger: true,
                          ),
                        ),
                      )
                  : null,
            ),
          ]),
        ),
      const CmdFooter(r'$ dokku ssh-keys:list  ·  ssh-keys:add <name> < key.pub  ·  ssh-keys:remove <name>'),
    ]);
  }
}

class _SystemCard extends ConsumerWidget {
  const _SystemCard(this.host);
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final system = ref.watch(systemProvider(host.id));
    final plugins = _plugins(ref, host).data;
    final globals = _globals(ref, host).data;
    final s = system.value ?? const <String, String>{};
    String or(String? v, String fallback) => v == null || v.isEmpty ? fallback : v;

    final uptime = double.tryParse((s['uptime'] ?? '').split(' ').first);
    final hostKey = host.hostKey ?? '';
    final rows = [
      if (system.hasValue) ...[
        ('Dokku', or(s['dokku'], '—')),
        if ((s['docker'] ?? '').isNotEmpty) ('Docker', s['docker']!),
        if ((s['os'] ?? '').isNotEmpty) ('OS', '${s['os']}${(s['arch'] ?? '').isEmpty ? '' : ' · ${s['arch']}'}'),
        if ((s['kernel'] ?? '').isNotEmpty) ('Kernel', s['kernel']!),
        if (uptime != null) ('Uptime', formatDuration(uptime)),
      ],
      ('Proxy', or(globals?.proxy['proxy global type'], 'nginx')),
      ('Scheduler', or(globals?.scheduler['scheduler global selected'], 'docker-local')),
      (
        'Plugins',
        plugins == null
            ? '—'
            : '${plugins.where((p) => !p.core).length} installed · ${plugins.where((p) => p.core).length} core',
      ),
      ('Connection', '${host.username}@${host.host}:${host.port}'),
    ];

    return Panel.column(children: [
      const PanelHead('System'),
      if (system.isLoading && !system.hasValue)
        const LoadingRows(rows: 4)
      else ...[
        if (system.hasError && !system.hasValue) EmptyBox('Could not read the system details: ${system.error}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Column(children: [
            for (final (k, v) in rows) KV(k, v),
            if (hostKey.length <= 22)
              KV('Host key', hostKey.isEmpty ? 'not pinned' : hostKey, last: true)
            else
              KV(
                'Host key',
                '',
                last: true,
                // The whole fingerprint is too long for the row.
                child: Tooltip(message: hostKey, child: SelectableText('${hostKey.substring(0, 22)}…', style: T.code)),
              ),
          ]),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Btn('Edit connection', onPressed: () => showConnectDialog(context, editing: host)),
      ),
    ]);
  }
}

class _InstallationCard extends ConsumerWidget {
  const _InstallationCard(this.host);
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = host.hasShell;
    final system = ref.watch(systemProvider(host.id));
    final latest = ref.watch(latestDokkuProvider).value;
    final current = _dokkuVersion(system);
    final upgradable = isNewerVersion(latest, current);
    final installer = (system.value?['installer'] ?? '').split('\n').first.trim();

    void review() {
      final run = streamRunProvider('upgrade:${host.id}');
      // A finished upgrade has been read; start the next one from the review.
      if (ref.read(run).status == RunStatus.done) ref.read(run.notifier).reset();
      showAppDialog<void>(context, (_) => _UpgradeDialog(host, current: current, latest: latest));
    }

    return Panel.column(children: [
      PanelHead(
        'Installation',
        trailing: upgradable
            ? Pill('upgrade available · $latest', tone: Tone.warn, mono: true, dot: false)
            : (current == null ? null : const Pill('up to date', tone: Tone.ok, mono: true, dot: false)),
      ),
      _ActionRow(
        first: true,
        title: 'Upgrade Dokku on ${host.name}',
        detail: '${current ?? '?'}${upgradable ? ' → ${latest!.replaceFirst(RegExp(r'^v'), '')}' : ''}'
            ' · apt-get install dokku · plugin:install-dependencies --core',
        trailing: Btn('Review upgrade', tooltip: root ? null : _needsRoot, onPressed: root ? review : null),
      ),
      _ActionRow(
        title: 'Install Dokku on a new host',
        detail: 'bootstrap.sh · DOKKU_TAG · debconf options · ssh-keys:add · domains:set-global',
        trailing: Btn('Open installer', onPressed: () => ref.read(routerProvider.notifier).go(const InstallRoute())),
      ),
      if (root)
        _ActionRow(
          title: 'Web installer service',
          detail: 'dokku-installer.service · public SSH-key form until disabled',
          trailing: switch (installer) {
            'enabled' => const Dot('enabled', tone: Tone.warn),
            'disabled' => const Dot('disabled', tone: Tone.ok),
            _ => const Dot('not present', tone: Tone.ok),
          },
        ),
    ]);
  }
}

final _domainList = RegExp(r'^[\w.* -]+$');

class _GlobalCard extends ConsumerStatefulWidget {
  const _GlobalCard(this.host);
  final Host host;

  @override
  ConsumerState<_GlobalCard> createState() => _GlobalCardState();
}

class _GlobalCardState extends ConsumerState<_GlobalCard> with Busy {
  final _domain = SyncedController();

  @override
  void dispose() {
    _domain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final globals = _globals(ref, host);
    final g = globals.data;
    final current = words(g?.domains['domains global vhosts']).join(' ');
    if (g != null) _domain.sync(current);
    final domains = words(_domain.text);
    final changed = _domainList.hasMatch(_domain.text.trim()) && domains.join(' ') != current;
    String or(String? v, String fallback) => v == null || v.isEmpty ? fallback : v;

    Future<void> save() async {
      final r = await busy('save', () => runDokku(context, ref, host, ['domains:set-global', ...domains]));
      if (r?.ok == true && mounted) _domain.controller.text = domains.join(' ');
    }

    return Panel.column(children: [
      const PanelHead('Global configuration'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Field(
          'Global domains',
          hint: 'Apps without custom domains are served at <app>.<global domain>.',
          child: Row(children: [
            Expanded(
              child: AppInput(
                controller: _domain.controller,
                hint: 'apps.example.com',
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (changed) save();
                },
              ),
            ),
            const SizedBox(width: 6),
            Btn('Save', loading: isBusy('save'), onPressed: changed ? save : null),
          ]),
        ),
      ),
      if (globals.loading) const LoadingRows(),
      if (globals.error != null) EmptyBox('Could not read the global settings: ${globals.errorText}'),
      if (g != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: KVList([
            ('Vhost deployments', isYes(g.domains['domains global enabled']) ? 'enabled' : 'disabled'),
            ('Default deploy branch', or(g.git['git global deploy branch'], 'master')),
            ('Default registry', or(g.registry['registry global server'], 'Docker Hub')),
            ('Global env vars', '${g.envCount}'),
          ]),
        ),
      CmdFooter(
          '\$ ${domains.isEmpty ? 'dokku domains:set-global <domain>' : displayCommand(['domains:set-global', ...domains])}'),
    ]);
  }
}

final _pluginUrlPattern = RegExp(r'^https://\S+$');
final _pluginNameInUrl = RegExp(r'([\w-]+?)(?:\.git)?$');

String _pluginName(String url) =>
    (_pluginNameInUrl.firstMatch(url.trim())?[1] ?? '').replaceFirst(RegExp(r'^dokku-'), '');

class _PluginsCard extends ConsumerStatefulWidget {
  const _PluginsCard(this.host);
  final Host host;

  @override
  ConsumerState<_PluginsCard> createState() => _PluginsCardState();
}

class _PluginsCardState extends ConsumerState<_PluginsCard> with Busy {
  final _url = TextEditingController();
  var _showCore = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final root = host.hasShell;
    final plugins = _plugins(ref, host);
    final all = plugins.data ?? const <PluginInfo>[];
    final third = [for (final p in all) if (!p.core) p];
    final core = [for (final p in all) if (p.core) p];
    final shown = _showCore ? [...third, ...core] : third;
    final url = _url.text.trim();
    final name = _pluginName(url).isEmpty ? 'plugin' : _pluginName(url);

    Widget act(String label, String key, List<String> args,
            {Confirm? ask, Duration? timeout, BtnVariant variant = BtnVariant.secondary}) =>
        Btn(
          label,
          variant: variant,
          tooltip: root ? null : _needsRoot,
          loading: isBusy(key),
          onPressed: root
              ? () => busy(key,
                  () => runDokku(context, ref, host, args, ask: ask, timeout: timeout ?? const Duration(minutes: 30)))
              : null,
        );

    Future<void> install() async {
      final r = await busy(
        'install',
        () => runDokku(
          context,
          ref,
          host,
          ['plugin:install', url],
          title: 'Install $name',
          timeout: const Duration(minutes: 15),
          ask: Confirm(
            title: 'Install $name?',
            body: 'Plugins run as root on the server. Only install from sources you trust.\n\n${redactUrl(url)}',
            label: 'Install plugin',
          ),
        ),
      );
      if (r?.ok == true && mounted) setState(_url.clear);
    }

    return Panel.column(children: [
      PanelHead(
        'Plugins',
        trailing: Btn(
          'Update all',
          tooltip: root ? null : _needsRoot,
          loading: isBusy('update-all'),
          onPressed: root
              ? () => busy(
                    'update-all',
                    () => runDokku(
                      context,
                      ref,
                      host,
                      ['plugin:update'],
                      title: 'Update all plugins',
                      timeout: const Duration(minutes: 30),
                      ask: const Confirm(
                        title: 'Update all plugins?',
                        body: 'Pulls the latest revision of every third-party plugin and re-runs their install hooks.',
                        label: 'Update all',
                      ),
                    ),
                  )
              : null,
        ),
      ),
      if (plugins.loading) const LoadingRows(rows: 1),
      if (plugins.error != null) EmptyBox('Could not list the plugins: ${plugins.errorText}'),
      if (plugins.hasData && third.isEmpty)
        const EmptyBox("No third-party plugins. Datastores, Let's Encrypt and others are installed from a git URL below."),
      for (final (i, p) in shown.indexed)
        PanelRow(
          first: i == 0 && third.isNotEmpty,
          child: _PluginRow(
            p,
            actions: p.core
                ? const []
                : [
                    act('Update', 'update-${p.name}', ['plugin:update', p.name], timeout: const Duration(minutes: 15)),
                    act(p.enabled ? 'Disable' : 'Enable', 'toggle-${p.name}',
                        [p.enabled ? 'plugin:disable' : 'plugin:enable', p.name]),
                    act(
                      'Uninstall',
                      'remove-${p.name}',
                      ['plugin:uninstall', p.name],
                      variant: BtnVariant.dangerGhost,
                      ask: Confirm(
                        title: 'Uninstall ${p.name}?',
                        body: 'Commands provided by this plugin stop working. Existing service data is left on disk.',
                        label: 'Uninstall',
                        danger: true,
                        typeToConfirm: p.name,
                      ),
                    ),
                  ],
          ),
        ),
      if (core.isNotEmpty)
        PanelRow(
          onTap: () => setState(() => _showCore = !_showCore),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8 + touchPad(context) / 2),
          child: Text('${_showCore ? 'Hide' : 'Show'} ${core.length} core plugin${core.length == 1 ? '' : 's'}',
              style: T.sans(11.5, color: C.muted)),
        ),
      PanelRow(
        tint: C.w(.02),
        child: LayoutBuilder(builder: (context, box) {
          final input = AppInput(
            controller: _url,
            enabled: root,
            hint: 'https://github.com/dokku/dokku-letsencrypt.git',
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
          );
          final button = Btn('Install plugin',
              tooltip: root ? null : _needsRoot,
              loading: isBusy('install'),
              onPressed: root && _pluginUrlPattern.hasMatch(url) ? install : null);
          if (box.maxWidth < 420) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              input,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: button),
            ]);
          }
          return Row(children: [Expanded(child: input), const SizedBox(width: 8), button]);
        }),
      ),
      CmdFooter('\$ ${url.isEmpty ? 'dokku plugin:install <git-url>' : displayCommand(['plugin:install', url])}'
          '  ·  plugin:update [<plugin>]  ·  needs root'),
    ]);
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow(this.plugin, {required this.actions});
  final PluginInfo plugin;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = plugin;
    final name = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12)),
      const SizedBox(height: 2),
      Text(p.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
    ]);
    final version = Text('${p.version}${p.enabled ? '' : ' · disabled'}',
        style: T.mono(10.5, color: p.enabled ? C.muted : Tone.warn.color));
    final trailing = p.core
        ? Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('core', style: T.tiny))
        : Wrap(spacing: 4, runSpacing: 4, children: actions);

    return LayoutBuilder(builder: (context, box) {
      // Three buttons do not fit beside the name on a phone.
      if (box.maxWidth < 460 && !p.core) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [Expanded(child: name), const SizedBox(width: 12), version]),
          const SizedBox(height: 8),
          trailing,
        ]);
      }
      return Row(children: [
        Expanded(child: name),
        const SizedBox(width: 12),
        version,
        const SizedBox(width: 12),
        trailing,
      ]);
    });
  }
}

class _RegistryCard extends ConsumerStatefulWidget {
  const _RegistryCard(this.host);
  final Host host;

  @override
  ConsumerState<_RegistryCard> createState() => _RegistryCardState();
}

class _RegistryCardState extends ConsumerState<_RegistryCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final root = host.hasShell;
    final system = ref.watch(systemProvider(host.id));
    final globals = _globals(ref, host);
    final registry = globals.data?.registry;
    // Only a shell user can read Docker's own record of who is logged in.
    final listed = registry?['registry computed auth servers'] ?? registry?['registry global auth servers'];
    final servers = root ? parseLines(system.value?['registries'] ?? '') : words(listed);
    final loading = root ? system.isLoading && !system.hasValue : globals.loading;
    final error = root ? (system.hasValue ? null : system.error) : globals.error;

    return Panel.column(children: [
      PanelHead(
        'Registry credentials',
        trailing: Btn('Log in',
            icon: LucideIcons.plus, onPressed: () => showAppDialog<void>(context, (_) => _RegistryLoginDialog(host))),
      ),
      if (loading) const LoadingRows(rows: 1),
      if (error != null) EmptyBox('Could not list the registries: $error'),
      if (!loading && error == null && servers.isEmpty)
        EmptyBox(root || listed != null
            ? 'Not logged in to any registry. Public images work without credentials.'
            : 'Logged-in registries cannot be listed as the dokku user on this Dokku version. Logging in still works.'),
      for (final (i, server) in servers.indexed)
        PanelRow(
          first: i == 0,
          child: Row(children: [
            Expanded(child: Text(server, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12))),
            const SizedBox(width: 12),
            const Dot('authenticated', tone: Tone.ok),
            const SizedBox(width: 12),
            Btn(
              'Log out',
              variant: BtnVariant.dangerGhost,
              loading: isBusy('logout-$server'),
              onPressed: () => busy(
                'logout-$server',
                () => runDokku(
                  context,
                  ref,
                  host,
                  ['registry:logout', server],
                  ask: Confirm(
                    title: 'Log out of $server?',
                    body: 'Apps that pull private images from this registry cannot deploy until you log in again.',
                    label: 'Log out',
                    danger: true,
                  ),
                ),
              ),
            ),
          ]),
        ),
      const CmdFooter(
          r'$ dokku registry:login --password-stdin <server> <user>  ·  the password travels over SSH and is never stored here'),
    ]);
  }
}

final _keyNameChars = RegExp(r'[^\w.@-]');
final _keyNamePattern = RegExp(r'^[\w.@-]{1,64}$');

class _AddKeyDialog extends ConsumerStatefulWidget {
  const _AddKeyDialog(this.host);
  final Host host;

  @override
  ConsumerState<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends ConsumerState<_AddKeyDialog> with Busy {
  final _name = TextEditingController();
  final _key = TextEditingController();
  String? _fileError;

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final file = await pickTextFile(maxBytes: 16 * 1024);
      if (file == null || !mounted) return;
      final text = file.text.trim();
      final parts = text.split(' ');
      setState(() {
        _fileError = null;
        _key.text = text;
        if (_name.text.isEmpty && publicKeyPattern.hasMatch(text)) {
          final guess = (parts.length > 2 ? parts[2] : file.name.replaceFirst(RegExp(r'\.pub$'), ''))
              .replaceAll(_keyNameChars, '-');
          _name.text = guess.length > 64 ? guess.substring(0, 64) : guess;
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => _fileError = '$e'.replaceFirst('FormatException: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _name.text;
    final key = _key.text.trim();
    final keyOk = publicKeyPattern.hasMatch(key);
    final valid = _keyNamePattern.hasMatch(name) && keyOk;
    final String hint;
    if (_fileError != null) {
      hint = _fileError!;
    } else if (key.contains('PRIVATE KEY')) {
      hint = 'This is a private key. Never paste a private key here. Use the matching .pub file instead.';
    } else if (key.isNotEmpty && !keyOk) {
      hint = 'This does not look like an OpenSSH public key. Never paste a private key here.';
    } else {
      hint = 'One line, starting with ssh-ed25519, ssh-rsa or ecdsa-sha2. Never paste a private key here.';
    }

    Future<void> submit() async {
      if (!valid) return;
      final r = await busy(
        'add',
        () => runDokku(context, ref, widget.host, ['ssh-keys:add', name], stdin: '$key\n', title: 'Add key $name'),
      );
      if (r?.ok == true && context.mounted) Navigator.of(context).pop();
    }

    return AppDialog(
      title: 'Add SSH key',
      subtitle: 'Grants git push and dokku command access to the holder of the private key.',
      width: 520,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Add key',
            size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('add'), onPressed: valid ? submit : null),
      ],
      children: [
        Field(
          'Key name',
          child: AppInput(
            controller: _name,
            large: true,
            autofocus: true,
            hint: 'alice-laptop',
            inputFormatters: [
              FilteringTextInputFormatter.deny(_keyNameChars, replacementString: '-'),
              LengthLimitingTextInputFormatter(64),
            ],
            onChanged: (_) => setState(() {}),
          ),
        ),
        Field(
          'Public key',
          trailing: Btn('Choose .pub file', size: BtnSize.xs, onPressed: _pick),
          hint: hint,
          hintTone: _fileError != null || (key.isNotEmpty && !keyOk) ? Tone.bad : null,
          child: AppInput(
            controller: _key,
            maxLines: 4,
            minLines: 3,
            hint: 'ssh-ed25519 AAAA… user@host',
            onChanged: (_) => setState(() => _fileError = null),
          ),
        ),
        CodeBlock('\$ dokku ssh-keys:add ${name.isEmpty ? '<name>' : shq(name)} < key.pub'),
      ],
    );
  }
}

final _registryServer = RegExp(r'^[\w.:/-]+$');
final _noSpaces = RegExp(r'^\S+$');

class _RegistryLoginDialog extends ConsumerStatefulWidget {
  const _RegistryLoginDialog(this.host);
  final Host host;

  @override
  ConsumerState<_RegistryLoginDialog> createState() => _RegistryLoginDialogState();
}

class _RegistryLoginDialogState extends ConsumerState<_RegistryLoginDialog> with Busy {
  final _server = TextEditingController(text: 'ghcr.io');
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = _server.text.trim(), user = _user.text.trim();
    final valid = _registryServer.hasMatch(server) && _noSpaces.hasMatch(user) && _password.text.isNotEmpty;
    // The password is never an argument: it goes to the command's input only.
    final args = ['registry:login', '--password-stdin', server, user];

    Future<void> submit() async {
      if (!valid) return;
      final r = await busy(
        'login',
        () => runDokku(context, ref, widget.host, args, stdin: _password.text, title: 'registry:login $server'),
      );
      if (r?.ok == true && context.mounted) Navigator.of(context).pop();
    }

    return AppDialog(
      title: 'Log in to a registry',
      subtitle: 'Docker Hub, GHCR, ECR or any private registry.',
      width: 460,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Log in',
            size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('login'), onPressed: valid ? submit : null),
      ],
      children: [
        Field(
          'Server',
          child: AppInput(
              controller: _server,
              large: true,
              hint: 'docker.io',
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {})),
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Field('Username', child: AppInput(controller: _user, large: true, onChanged: (_) => setState(() {}))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Field(
              'Password or token',
              child: AppInput(
                  controller: _password,
                  large: true,
                  obscure: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => submit()),
            ),
          ),
        ]),
        Text(
          'The password is sent to the command over the SSH connection. It does not appear in the process list, '
          'the activity log or this app\'s storage. Docker stores the resulting token on the server.',
          style: T.sans(11, color: C.dim, height: 1.5),
        ),
        CodeBlock('\$ dokku registry:login --password-stdin '
            '${server.isEmpty ? '<server>' : shq(server)} ${user.isEmpty ? '<user>' : shq(user)}'),
      ],
    );
  }
}

class _UpgradeDialog extends ConsumerWidget {
  const _UpgradeDialog(this.host, {required this.current, required this.latest});
  final Host host;
  final String? current;
  final String? latest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = streamRunProvider('upgrade:${host.id}');
    final run = ref.watch(provider);
    final commands = [
      for (final l in upgradeScript.split('\n'))
        if (l.startsWith('sudo ')) '\$ $l',
    ];

    return PopScope(
      // Closing would hide an upgrade that keeps running on the server.
      canPop: !run.running,
      child: AppDialog(
        title: 'Upgrade Dokku',
        subtitle:
            '${current ?? '?'} → ${latest?.replaceFirst(RegExp(r'^v'), '') ?? 'latest packaged version'} on ${host.name}',
        width: 720,
        dismissible: !run.running,
        leading: Btn('Migration guides',
            variant: BtnVariant.ghost, icon: LucideIcons.externalLink, onPressed: () => _openLink(_upgradeDocs)),
        actions: [
          if (run.running)
            Btn('Cancel upgrade', size: BtnSize.md, onPressed: ref.read(provider.notifier).kill)
          else
            Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          if (run.status != RunStatus.done)
            Btn(
              run.status == RunStatus.failed ? 'Retry upgrade' : 'Run upgrade',
              size: BtnSize.md,
              variant: BtnVariant.primary,
              loading: run.running,
              // The script calls sudo, which a root login on a minimal image does not have.
              onPressed: () => ref.read(provider.notifier).start(host, '$sudoShim$upgradeScript'),
            ),
        ],
        children: [
          if (run.status == RunStatus.idle) ...[
            const AlertBox(
              title: 'Read the release notes first.',
              text: 'Minor versions can include breaking changes and migrations. Apps keep running during the '
                  'package upgrade, but plan a maintenance window and have a backup.',
            ),
            CodeBlock(commands.join('\n')),
            Text(
              'Works for apt-based installs (bootstrap.sh and the Debian package). '
              'Source installs upgrade with git pull && sudo make install from the terminal.',
              style: T.sans(11.5, color: C.muted, height: 1.5),
            ),
          ] else
            Container(
              height: 360,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: C.term, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: StreamOutput(
                    lines: run.lines,
                    idle: TextSpan(text: run.running ? 'Starting…' : 'The upgrade printed nothing.'),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.line))),
                  child: Text(
                    switch (run.status) {
                      RunStatus.running => 'upgrading…',
                      RunStatus.done => 'upgrade complete',
                      _ => 'upgrade failed, see the output above',
                    },
                    style: T.meta,
                  ),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
