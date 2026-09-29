import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/command.dart';
import '../../data/models.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../actions.dart';
import '../shell/action_dialogs.dart';
import '../widgets/kit.dart';

const _needsRoot = 'Installing plugins needs root. Connect as root or as a user with sudo.';
final _dsnPassword = RegExp(r':([^:@/]+)@');

class DatastoresScreen extends ConsumerStatefulWidget {
  const DatastoresScreen({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<DatastoresScreen> createState() => _DatastoresScreenState();
}

class _DatastoresScreenState extends ConsumerState<DatastoresScreen> with Busy {
  final _infoOpen = <String>{};
  var _lastCommand = r'$ dokku <service>:links <name>';

  Future<ExecResult?> _run(String key, List<String> args, {Confirm? ask, String? title, Duration? timeout}) {
    setState(() => _lastCommand = '\$ ${displayCommand(args)}');
    return busy(
      key,
      () => runDokku(context, ref, widget.host, args, ask: ask, title: title, timeout: timeout ?? const Duration(minutes: 30)),
    );
  }

  void _toggleLink(Service s, String app) {
    final linked = s.links.contains(app);
    _run(
      'link-${s.key}-$app',
      ['${s.type}:${linked ? 'unlink' : 'link'}', s.name, app],
      ask: linked
          ? Confirm(
              title: 'Unlink ${s.name} from $app?',
              body: 'Removes ${datastoreOf(s.type)?.envVar ?? 'the connection URL'} from $app and restarts it.',
              label: 'Unlink',
              danger: true,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final ds = ref.watch(datastoresProvider(host.id));
    final apps = ref.watch(appsProvider(host.id)).value?.names ?? const <String>[];
    final state = ds.value;
    final services = state?.services ?? const <Service>[];
    final loading = ds.isLoading && !ds.hasValue;
    final anyInstalled = state?.anyInstalled ?? false;
    final compact = Bp.isCompact(context);

    return PageBody(children: [
      PageHead(eyebrow: 'Plugins', title: 'Datastores', actions: [
        Btn('Provision service',
            icon: LucideIcons.plus,
            variant: BtnVariant.primary,
            size: BtnSize.md,
            tooltip: anyInstalled ? null : 'Install a datastore plugin first.',
            onPressed: anyInstalled ? () => showProvision(context, host) : null),
      ]),
      AutoGrid(minWidth: compact ? 150 : 200, gap: 12, children: [
        for (final d in datastores)
          _PluginCard(
            d,
            version: state?.installed(d.type) ?? false ? state!.plugin(d.type)!.version : null,
            services: services.where((s) => s.type == d.type).length,
            loading: loading,
            installing: isBusy('install-${d.type}'),
            canInstall: host.hasShell,
            onProvision: () => showProvision(context, host, type: d.type),
            onInstall: () => _run('install-${d.type}', ['plugin:install', d.repo, '--name', d.type],
                title: 'Install ${d.name} plugin', timeout: const Duration(minutes: 15)),
          ),
      ]),
      if (!host.hasShell)
        Text('Connected as the dokku user: installing plugins needs root. Everything else here works.', style: T.tiny),
      TwoCol(
        left: [
          Panel.column(children: [
            PanelHead('Services', trailing: Text('<service>:list · info · expose · backup · destroy', style: T.meta)),
            if (loading) const LoadingRows(),
            if (ds.hasError && !ds.hasValue) EmptyBox('Could not list the datastores: ${ds.error}'),
            if (state != null && services.isEmpty)
              EmptyBox('No services yet. ${anyInstalled ? 'Provision one above.' : 'Install a datastore plugin first.'}'),
            for (final (i, s) in services.indexed) _service(s, first: i == 0),
            CmdFooter(_lastCommand),
          ]),
        ],
        right: [
          Panel.column(children: [
            const PanelHead('App linkage', note: 'Tap a cell to link or unlink.'),
            if (loading)
              const LoadingRows()
            else if (services.isEmpty || apps.isEmpty)
              EmptyBox(services.isEmpty ? 'Provision a service to link it to apps.' : 'Create an app to link services to.')
            else
              _LinkMatrix(services: services, apps: apps, busy: (s, a) => isBusy('link-${s.key}-$a'), onToggle: _toggleLink),
            CmdFooter(_lastCommand),
          ]),
        ],
      ),
    ]);
  }

  Widget _service(Service s, {required bool first}) {
    final host = widget.host;
    final tone = s.running
        ? Tone.ok
        : RegExp('restart|paused|created', caseSensitive: false).hasMatch(s.status)
            ? Tone.warn
            : Tone.mute;
    final ip = s.info['internal ip'] ?? '';
    final open = _infoOpen.contains(s.key);

    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12.5)),
      const SizedBox(height: 2),
      Text('${s.image} · dokku-${s.type}-${s.name}${ip.isEmpty ? '' : ' · $ip'}',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
    ]);
    final status = ConstrainedBox(constraints: const BoxConstraints(maxWidth: 130), child: Dot(s.status, tone: tone));
    final actions = [
      Btn('Info', selected: open, onPressed: () => setState(() => open ? _infoOpen.remove(s.key) : _infoOpen.add(s.key))),
      if (s.running)
        Btn('Stop',
            loading: isBusy('stop-${s.key}'),
            onPressed: () => _run('stop-${s.key}', ['${s.type}:stop', s.name],
                ask: Confirm(
                  title: 'Stop ${s.name}?',
                  body: 'Linked apps lose their connection until the service is started again.',
                  label: 'Stop service',
                  danger: true,
                )))
      else
        Btn('Start', loading: isBusy('start-${s.key}'), onPressed: () => _run('start-${s.key}', ['${s.type}:start', s.name])),
      Btn('Destroy',
          variant: BtnVariant.dangerGhost,
          loading: isBusy('destroy-${s.key}'),
          onPressed: () => _run('destroy-${s.key}', ['${s.type}:destroy', s.name, '--force'],
              ask: Confirm(
                title: 'Destroy ${s.name}?',
                body: s.links.isEmpty
                    ? 'The container and its data directory are deleted permanently.'
                    : 'Still linked to ${s.links.join(', ')}. Unlink first, or destroying will fail.',
                label: 'Destroy service',
                danger: true,
                typeToConfirm: s.name,
              ))),
    ];

    return PanelRow(
      first: first,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LayoutBuilder(builder: (context, box) {
          // Name, status and three buttons do not fit side by side on a phone.
          if (box.maxWidth < 520) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [Expanded(child: title), const SizedBox(width: 12), status]),
              const SizedBox(height: 10),
              Wrap(spacing: 4, runSpacing: 4, children: actions),
            ]);
          }
          return Row(children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            status,
            const SizedBox(width: 12),
            for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 4), a],
          ]);
        }),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, box) {
          final expose = _Tile(
            title: 'Expose externally',
            detail: s.isExposed ? s.exposed : 'internal network only',
            detailColor: s.isExposed ? Tone.warn.color : C.muted,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (isBusy('expose-${s.key}')) const Padding(padding: EdgeInsets.only(right: 8), child: Spinner(size: 11)),
              AppSwitch(
                value: s.isExposed,
                label: 'Expose ${s.name} externally',
                onChanged: isBusy('expose-${s.key}')
                    ? null
                    : (on) => on
                        ? showAppDialog<void>(context, (_) => _ExposeDialog(host, s))
                        : _run('expose-${s.key}', ['${s.type}:unexpose', s.name]),
              ),
            ]),
          );
          final backups = _Tile(
            title: 'Backups',
            detail: (s.info['backup schedule'] ?? '').isEmpty ? 'S3-compatible · not scheduled' : s.info['backup schedule']!,
            trailing: Btn('Back up…',
                size: BtnSize.xs, onPressed: () => showAppDialog<void>(context, (_) => _BackupDialog(host, s))),
          );
          if (box.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [expose, const SizedBox(height: 8), backups],
            );
          }
          return Row(children: [Expanded(child: expose), const SizedBox(width: 8), Expanded(child: backups)]);
        }),
        if (open) ...[
          const SizedBox(height: 10),
          CodeBlock(
            [
              for (final e in s.info.entries)
                '${e.key.padRight(22)} ${e.key == 'dsn' ? e.value.replaceFirst(_dsnPassword, ':••••••••@') : e.value}',
            ].join('\n'),
            wrap: false,
          ),
        ],
      ]),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard(
    this.def, {
    required this.version,
    required this.services,
    required this.loading,
    required this.installing,
    required this.canInstall,
    required this.onProvision,
    required this.onInstall,
  });
  final DatastoreDef def;

  /// The installed plugin's version, or null when it is not installed.
  final String? version;
  final int services;
  final bool loading;
  final bool installing;
  final bool canInstall;
  final VoidCallback onProvision;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final installed = version != null;
    return Opacity(
      opacity: installed || loading ? 1 : .6,
      child: Panel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: def.hue.withValues(alpha: .12), borderRadius: BorderRadius.circular(7)),
              child: Text(def.glyph, style: T.mono(11, color: def.hue, weight: FontWeight.w500)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                loading ? '…' : (installed ? 'INSTALLED' : 'NOT INSTALLED'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: T.mono(10, color: installed ? Tone.ok.color : C.dim, spacing: .4),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(def.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(13.5, weight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            installed ? 'v$version · $services service${services == 1 ? '' : 's'}' : 'dokku plugin:install',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.meta,
          ),
          const SizedBox(height: 10),
          if (installed)
            Btn('Provision', variant: BtnVariant.outline, onPressed: onProvision)
          else
            Btn('Install plugin',
                variant: BtnVariant.outline,
                loading: installing,
                tooltip: canInstall ? null : _needsRoot,
                onPressed: canInstall && !loading ? onInstall : null),
        ]),
      ),
    );
  }
}

/// A setting of one service: what it is on the left, its control on the right.
class _Tile extends StatelessWidget {
  const _Tile({required this.title, required this.detail, required this.trailing, this.detailColor = C.muted});
  final String title;
  final String detail;
  final Color detailColor;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: C.w(.02), border: Border.all(color: C.lineSoft), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(11.5)),
              const SizedBox(height: 1),
              Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(10.5, color: detailColor)),
            ]),
          ),
          const SizedBox(width: 8),
          trailing,
        ]),
      );
}

/// Services down the side, apps across the top. Scrolls sideways by itself
/// when there are more apps than fit.
class _LinkMatrix extends StatefulWidget {
  const _LinkMatrix({required this.services, required this.apps, required this.busy, required this.onToggle});
  final List<Service> services;
  final List<String> apps;
  final bool Function(Service, String app) busy;
  final void Function(Service, String app) onToggle;

  @override
  State<_LinkMatrix> createState() => _LinkMatrixState();
}

class _LinkMatrixState extends State<_LinkMatrix> {
  static const _nameWidth = 120.0;
  static const _cellWidth = 80.0;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final needed = 32 + _nameWidth + _cellWidth * widget.apps.length;
        final scrolls = needed > box.maxWidth;
        return Scrollbar(
          controller: _scroll,
          thumbVisibility: scrolls,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            // Leaves room for the scrollbar under the last row.
            padding: EdgeInsets.only(bottom: scrolls ? 10 : 0),
            child: SizedBox(
              width: math.max(box.maxWidth, needed),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  color: C.w(.03),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    const SizedBox(width: _nameWidth),
                    for (final a in widget.apps)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Tooltip(
                            message: a,
                            child: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: T.th),
                          ),
                        ),
                      ),
                  ]),
                ),
                for (final s in widget.services)
                  PanelRow(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(children: [
                      SizedBox(
                        width: _nameWidth,
                        child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code),
                      ),
                      for (final a in widget.apps)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _LinkCell(
                              linked: s.links.contains(a),
                              busy: widget.busy(s, a),
                              command: '${s.type}:${s.links.contains(a) ? 'unlink' : 'link'} ${s.name} $a',
                              onTap: () => widget.onToggle(s, a),
                            ),
                          ),
                        ),
                    ]),
                  ),
              ]),
            ),
          ),
        );
      });
}

class _LinkCell extends StatelessWidget {
  const _LinkCell({required this.linked, required this.busy, required this.command, required this.onTap});
  final bool linked;
  final bool busy;
  final String command;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ok = Tone.ok.color;
    return Tooltip(
      message: command,
      child: Semantics(
        button: true,
        selected: linked,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: busy ? null : onTap,
            borderRadius: BorderRadius.circular(7),
            hoverColor: C.w(.04),
            child: Container(
              height: 30 + touchPad(context),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: linked ? ok.withValues(alpha: .14) : C.w(.02),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: linked ? ok.withValues(alpha: .35) : C.line),
              ),
              child: busy
                  ? Spinner(size: 10, color: ok)
                  : linked
                      ? Container(width: 8, height: 8, decoration: BoxDecoration(color: ok, shape: BoxShape.circle))
                      : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _ExposeDialog extends ConsumerStatefulWidget {
  const _ExposeDialog(this.host, this.service);
  final Host host;
  final Service service;

  @override
  ConsumerState<_ExposeDialog> createState() => _ExposeDialogState();
}

class _ExposeDialogState extends ConsumerState<_ExposeDialog> with Busy {
  late final _port = TextEditingController(text: '${(datastoreOf(widget.service.type)?.port ?? 5000) + 10000}');

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    final port = _port.text.trim();
    final valid = RegExp(r'^\d{2,5}$').hasMatch(port);
    final args = ['${s.type}:expose', s.name, port];

    Future<void> submit() async {
      if (!valid) return;
      final r = await busy('expose', () => runDokku(context, ref, widget.host, args));
      if (r?.ok == true && context.mounted) Navigator.of(context).pop();
    }

    return AppDialog(
      title: 'Expose ${s.name}',
      width: 420,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Expose', size: BtnSize.md, variant: BtnVariant.primary, loading: isBusy('expose'), onPressed: valid ? submit : null),
      ],
      children: [
        Field(
          'Host port',
          hint: 'Container port ${datastoreOf(s.type)?.port ?? '?'} becomes reachable on every interface of the host.',
          child: AppInput(
            controller: _port,
            large: true,
            autofocus: true,
            inputFormatters: digitsOnly,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => submit(),
          ),
        ),
        const AlertBox(text: 'This opens the datastore to the internet. Protect the port with a firewall.'),
        CodeBlock('\$ ${displayCommand([args[0], args[1]])} ${port.isEmpty ? '<port>' : port}'),
      ],
    );
  }
}

enum _BackupMode {
  now('Back up now'),
  auth('S3 credentials'),
  schedule('Schedule');

  const _BackupMode(this.label);
  final String label;
}

class _BackupDialog extends ConsumerStatefulWidget {
  const _BackupDialog(this.host, this.service);
  final Host host;
  final Service service;

  @override
  ConsumerState<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends ConsumerState<_BackupDialog> with Busy {
  late final _bucket = TextEditingController(text: widget.service.info['backup bucket'] ?? '');
  final _keyId = TextEditingController();
  final _secret = TextEditingController();
  final _region = TextEditingController();
  final _endpoint = TextEditingController();
  final _cron = TextEditingController(text: '0 2 * * *');
  var _mode = _BackupMode.now;
  var _iam = false;

  @override
  void dispose() {
    for (final c in [_bucket, _keyId, _secret, _region, _endpoint, _cron]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, s = widget.service;
    final bucket = _bucket.text.trim(), cron = _cron.text.trim();
    final keyId = _keyId.text.trim(), secret = _secret.text.trim();
    final region = _region.text.trim(), endpoint = _endpoint.text.trim();
    // The plugin takes the region, signature version and endpoint by position.
    final target = [
      if (region.isNotEmpty || endpoint.isNotEmpty) ...[region.isEmpty ? 'us-east-1' : region, 'v4', if (endpoint.isNotEmpty) endpoint],
    ];
    final iam = [if (_iam) '--use-iam'];
    final shownBucket = bucket.isEmpty ? '<bucket>' : shq(bucket);

    Widget input(TextEditingController c, {String? hint, bool obscure = false}) =>
        AppInput(controller: c, large: true, hint: hint, obscure: obscure, onChanged: (_) => setState(() {}));

    Future<void> run(String key, List<String> args, {String? title, Duration timeout = const Duration(minutes: 30)}) =>
        busy(key, () => runDokku(context, ref, host, args, title: title, timeout: timeout));

    return AppDialog(
      title: 'Back up ${s.name}',
      width: 520,
      actions: [
        Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        ...switch (_mode) {
          _BackupMode.now => [
              Btn('Run backup',
                  size: BtnSize.md,
                  variant: BtnVariant.primary,
                  loading: isBusy('backup'),
                  onPressed: bucket.isEmpty
                      ? null
                      : () => run('backup', ['${s.type}:backup', s.name, bucket, ...iam], timeout: const Duration(hours: 1))),
            ],
          _BackupMode.auth => [
              Btn('Save credentials',
                  size: BtnSize.md,
                  variant: BtnVariant.primary,
                  loading: isBusy('auth'),
                  onPressed: keyId.isEmpty || secret.isEmpty
                      ? null
                      : () => run('auth', ['${s.type}:backup-auth', s.name, keyId, secret, ...target],
                          title: 'Set backup credentials')),
            ],
          _BackupMode.schedule => [
              Btn('Remove schedule',
                  size: BtnSize.md,
                  loading: isBusy('unschedule'),
                  onPressed: () => run('unschedule', ['${s.type}:backup-unschedule', s.name])),
              Btn('Schedule',
                  size: BtnSize.md,
                  variant: BtnVariant.primary,
                  loading: isBusy('schedule'),
                  onPressed: bucket.isEmpty || cron.split(RegExp(r'\s+')).length != 5
                      ? null
                      : () => run('schedule', ['${s.type}:backup-schedule', s.name, cron, bucket, ...iam])),
            ],
        },
      ],
      children: [
        Seg<_BackupMode>(
          value: _mode,
          options: _BackupMode.values,
          labels: (m) => m.label,
          expand: !Bp.isCompact(context),
          onChanged: (m) => setState(() => _mode = m),
        ),
        if (_mode != _BackupMode.auth) Field('Bucket', child: input(_bucket, hint: 'acme-db-backups')),
        if (_mode == _BackupMode.auth) ...[
          AutoGrid(minWidth: 200, gap: 10, equalHeight: false, children: [
            Field('Access key ID', child: input(_keyId)),
            Field('Secret access key', child: input(_secret, obscure: true)),
            Field('Region', child: input(_region, hint: 'us-east-1')),
            Field('Endpoint (S3-compatible)', child: input(_endpoint, hint: 'https://s3.example.com')),
          ]),
          Text(
            'The credentials are passed to ${s.type}:backup-auth and stored by the plugin on the server. This app does not keep them.',
            style: T.tiny,
          ),
        ],
        if (_mode == _BackupMode.schedule)
          Field('Cron schedule',
              hint: 'Server local time. Set the credentials first, or use the IAM role.', child: input(_cron)),
        if (_mode != _BackupMode.auth)
          AppCheckbox(value: _iam, onChanged: (v) => setState(() => _iam = v), label: 'Use the instance IAM role (--use-iam)'),
        CodeBlock(switch (_mode) {
          _BackupMode.now => '\$ ${displayCommand(['${s.type}:backup', s.name])} ${[shownBucket, ...iam].join(' ')}',
          _BackupMode.auth =>
            '\$ ${displayCommand(['${s.type}:backup-auth', s.name])} ${['<key-id>', '<secret>', ...target.map(shq)].join(' ')}',
          _BackupMode.schedule =>
            '\$ ${displayCommand(['${s.type}:backup-schedule', s.name, cron])} ${[shownBucket, ...iam].join(' ')}',
        }),
      ],
    );
  }
}
