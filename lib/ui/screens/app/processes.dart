import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/command.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../actions.dart';
import '../../shell/terminal.dart';
import '../../widgets/kit.dart';

const _psRefresh = Duration(seconds: 15);
const _deployFirst = 'Deploy the app first.';

/// Cards narrower than this stack their controls. A phone and one half of a
/// split desktop page are both narrow, so this looks at the card, not the screen.
const _narrowCard = 460.0;

const _policies = ['on-failure:10', 'always', 'unless-stopped', 'no'];
const _schedulers = ['docker-local', 'k3s', 'null'];
const _schedulerNotes = {
  'docker-local': 'Containers run on this host through the Docker daemon. This is the default.',
  'k3s': 'Deploys to the k3s cluster managed by scheduler-k3s. Needs a registry with push-on-release.',
  'null': 'Builds images but never starts containers.',
};

final _typeChars = [FilteringTextInputFormatter.allow(RegExp(r'[\w-]'))];

enum _Check {
  enabled('checks:enable'),
  skipped('checks:skip'),
  disabled('checks:disable');

  const _Check(this.command);
  final String command;
}

/// Waits until a lookup has been read again after a change, so a card does not
/// flash the old values between the command finishing and the refresh.
Future<void> _reread(WidgetRef ref, Host host, List<String> args, {Duration? refresh}) async {
  try {
    await ref.read(dokkuProvider(DokkuQuery(host.id, args, refresh: refresh)).future).timeout(const Duration(seconds: 15));
  } on Object {
    // The card reports a failed lookup itself.
  }
}

class ProcessesTab extends StatefulWidget {
  const ProcessesTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  State<ProcessesTab> createState() => _ProcessesTabState();
}

class _ProcessesTabState extends State<ProcessesTab> {
  // Keyed so that what was typed survives the columns stacking when the window narrows.
  final _keys = [for (var i = 0; i < 6; i++) GlobalKey()];

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    return TwoCol(
      left: [
        _ScaleCard(host, app, key: _keys[0]),
        _OneOffCard(host, app, key: _keys[1]),
        _CronCard(host, app, key: _keys[2]),
      ],
      right: [
        _ResourcesCard(host, app, key: _keys[3]),
        _ChecksCard(host, app, key: _keys[4]),
        _PolicyCard(host, app, key: _keys[5]),
      ],
    );
  }
}

Widget _name(String text) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12.5));

Widget _detail(String text) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta);

class _ScaleCard extends ConsumerStatefulWidget {
  const _ScaleCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_ScaleCard> createState() => _ScaleCardState();
}

class _ScaleCardState extends ConsumerState<_ScaleCard> with Busy {
  final _newType = TextEditingController();

  /// Counts changed here and not applied yet, by process type.
  final _edits = <String, int>{};

  @override
  void dispose() {
    _newType.dispose();
    super.dispose();
  }

  void _addType(Map<String, int> scale) {
    final type = _newType.text;
    if (type.isEmpty || scale.containsKey(type)) return;
    setState(() => _edits[type] = 1);
    _newType.clear();
  }

  Future<void> _apply(List<String> args) => busy('scale', () async {
        final applied = Map.of(_edits);
        final r = await runDokku(context, ref, widget.host, args, timeout: const Duration(minutes: 15));
        if (r?.ok != true) return;
        await _reread(ref, widget.host, ['ps:scale', widget.app]);
        // Counts changed while the command ran stay staged.
        if (mounted) setState(() => _edits.removeWhere((type, n) => applied[type] == n));
      });

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ps = ref.report(host, 'ps', app, refresh: _psRefresh);
    final scaleQ = ref.dokku(host, ['ps:scale', app], (r) => parseScale(r.stdout));
    final server = scaleQ.data ?? const <String, int>{};
    final scale = {...server, ..._edits};
    final dirty = scaleQ.hasData && scale.entries.any((e) => server[e.key] != e.value);
    final args = ['ps:scale', app, for (final e in scale.entries) '${e.key}=${e.value}'];
    final procs = procStatuses(ps.data ?? const {});
    final undeployed = ps.data != null && !isYes(ps.data!['deployed']);
    final canAdd = _newType.text.isNotEmpty && !scale.containsKey(_newType.text);

    Widget action(String label, String key, List<String> args, {Confirm? ask}) => Btn(label,
        loading: isBusy(key),
        tooltip: undeployed ? _deployFirst : null,
        onPressed: undeployed ? null : () => busy(key, () => runDokku(context, ref, host, args, ask: ask)));

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < _narrowCard;
      return Panel.column(children: [
        PanelHead(
          'Process types',
          trailing: Wrap(spacing: 6, runSpacing: 6, children: [
            action('Start', 'start', ['ps:start', app]),
            action('Stop', 'stop', ['ps:stop', app],
                ask: Confirm(title: 'Stop $app?', body: stopConfirmBody, label: 'Stop app', danger: true)),
            action('Restart', 'restart', ['ps:restart', app]),
            action('Rebuild', 'rebuild', ['ps:rebuild', app]),
          ]),
        ),
        if (scaleQ.loading) const LoadingRows(),
        if (scaleQ.error != null) EmptyBox('Could not read the process types. ${scaleQ.errorText}'),
        if (scaleQ.hasData && scale.isEmpty)
          const EmptyBox('No process types yet. They come from the Procfile, or the Dockerfile CMD, on the first deploy.'),
        for (final (i, e) in scale.entries.indexed)
          () {
            final running = procs.where((p) => p.type == e.key && p.running).length;
            final status = '$running running${server[e.key] != e.value ? ' → ${e.value}' : ''}';
            return PanelRow(
              first: i == 0,
              child: Row(children: [
                Expanded(
                  child: narrow
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _name(e.key),
                          const SizedBox(height: 2),
                          _detail(status),
                        ])
                      : Row(children: [
                          SizedBox(width: 120, child: _name(e.key)),
                          const SizedBox(width: 12),
                          Expanded(child: _detail(status)),
                        ]),
                ),
                const SizedBox(width: 12),
                NumberStepper(value: e.value, onChanged: (n) => setState(() => _edits[e.key] = n)),
              ]),
            );
          }(),
        if (scaleQ.hasData)
          PanelRow(
            tint: C.w(.02),
            child: Row(children: [
              Expanded(
                child: AppInput(
                  controller: _newType,
                  hint: 'Process type, e.g. worker',
                  inputFormatters: _typeChars,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _addType(scale),
                ),
              ),
              const SizedBox(width: 8),
              Btn('Add type', onPressed: canAdd ? () => _addType(scale) : null),
            ]),
          ),
        CmdFooter(
          '\$ ${displayCommand(args)}',
          bright: true,
          action: Btn('Apply scale',
              variant: BtnVariant.primary,
              size: BtnSize.md,
              loading: isBusy('scale'),
              onPressed: dirty ? () => _apply(args) : null),
        ),
      ]);
    });
  }
}

class _OneOffCard extends ConsumerStatefulWidget {
  const _OneOffCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_OneOffCard> createState() => _OneOffCardState();
}

class _OneOffCardState extends ConsumerState<_OneOffCard> with Busy {
  final _command = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  /// The command as separate arguments, or null while a quote is still open.
  List<String>? _words() {
    try {
      return splitArgs(_command.text.trim());
    } on ArgError {
      return null;
    }
  }

  Future<void> _run({required bool detached}) async {
    final host = widget.host, app = widget.app;
    final words = _words();
    if (words == null) {
      setState(() => _problem = 'A quote in this command is not closed. Close it and run the command again.');
      return;
    }
    if (words.isEmpty) return;
    if (detached) {
      await busy('detach', () => runDokku(context, ref, host, ['run:detached', app, ...words]));
    } else {
      await openTerminal(context, host, TerminalSpec.dokku(['run', app, ...words]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ps = ref.report(host, 'ps', app, refresh: _psRefresh);
    final running = procStatuses(ps.data ?? const {}).where((p) => p.running).toList();
    final typed = _command.text.trim();
    final words = _words();
    final shownRun = typed.isEmpty
        ? 'dokku run $app <command>'
        : (words == null ? 'dokku run $app $typed' : displayCommand(['run', app, ...words]));
    final shownEnter = running.isEmpty
        ? 'dokku enter $app <type>.<number>'
        : displayCommand(['enter', app, '${running.first.type}.${running.first.index}']);

    final input = AppInput(
      controller: _command,
      hint: 'npm run migrate',
      onChanged: (_) => setState(() => _problem = null),
      onSubmitted: (_) => _run(detached: false),
    );
    final run = Btn('Run', onPressed: typed.isEmpty ? null : () => _run(detached: false));
    final detach = Btn('Run detached',
        tooltip: 'Runs in the background and returns at once.',
        loading: isBusy('detach'),
        onPressed: typed.isEmpty ? null : () => _run(detached: true));

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < _narrowCard;
      return Panel.column(children: [
        const PanelHead('One-off command', note: 'ephemeral container · dokku run'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (narrow) ...[
              input,
              const SizedBox(height: 8),
              Row(children: [Expanded(child: run), const SizedBox(width: 8), Expanded(child: detach)]),
            ] else
              Row(children: [Expanded(child: input), const SizedBox(width: 8), run, const SizedBox(width: 8), detach]),
            if (_problem != null) ...[
              const SizedBox(height: 6),
              Text(_problem!, style: T.sans(11.5, color: Tone.bad.color, height: 1.45)),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Enter a running container:', style: T.sans(12, color: C.muted)),
              for (final p in running)
                Btn(p.name,
                    mono: true,
                    onPressed: () => openTerminal(context, host, TerminalSpec.dokku(['enter', app, '${p.type}.${p.index}']))),
              if (ps.loading) const Spinner(size: 11, color: C.muted),
              if (!ps.loading && running.isEmpty) Text('none running', style: T.sans(12, color: C.dim)),
            ]),
          ]),
        ),
        CmdFooter('\$ $shownRun\n\$ $shownEnter'),
      ]);
    });
  }
}

typedef _Cron = ({List<CronTask> tasks, bool supported});

class _CronCard extends ConsumerStatefulWidget {
  const _CronCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_CronCard> createState() => _CronCardState();
}

class _CronCardState extends ConsumerState<_CronCard> with Busy {
  static _Cron _parse(ExecResult r) {
    if (r.ok) return (tasks: parseCron(r.stdout), supported: true);
    if (notSupported(r.output)) return (tasks: const [], supported: false);
    throw DokkuError(r);
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final cron = ref.dokku(host, ['cron:list', app, '--format', 'json'], _parse, lenient: true);
    final tasks = cron.data?.tasks ?? const <CronTask>[];

    return Panel.column(children: [
      const PanelHead('Scheduled tasks', note: 'from app.json · cron:list'),
      if (cron.loading) const LoadingRows(),
      if (cron.error != null) EmptyBox('Could not list the scheduled tasks. ${cron.errorText}'),
      if (cron.data?.supported == false)
        const EmptyBox('This Dokku version cannot list scheduled tasks. Upgrade Dokku from the Server page.'),
      if (cron.data?.supported == true && tasks.isEmpty)
        const EmptyBox('No scheduled tasks. Add a cron block to app.json and deploy again.'),
      for (final (i, c) in tasks.indexed)
        PanelRow(
          first: i == 0,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code),
                const SizedBox(height: 2),
                _detail('${c.schedule} · ${cronHuman(c.schedule)} · id ${c.id.length > 10 ? '${c.id.substring(0, 10)}…' : c.id}'),
              ]),
            ),
            const SizedBox(width: 12),
            Btn('Run now',
                loading: isBusy('cron-${c.id}'),
                onPressed: () => busy(
                    'cron-${c.id}',
                    () => runDokku(context, ref, host, ['cron:run', app, c.id],
                        title: 'cron:run ${c.command}', timeout: const Duration(hours: 1)))),
          ]),
        ),
      CmdFooter('\$ dokku cron:run $app <cron-id>'),
    ]);
  }
}

class _ResourcesCard extends ConsumerStatefulWidget {
  const _ResourcesCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_ResourcesCard> createState() => _ResourcesCardState();
}

class _ResourcesCardState extends ConsumerState<_ResourcesCard> with Busy {
  final _cpuLimit = SyncedController();
  final _memoryLimit = SyncedController();
  final _cpuReserve = SyncedController();
  final _memoryReserve = SyncedController();

  List<SyncedController> get _fields => [_cpuLimit, _memoryLimit, _cpuReserve, _memoryReserve];

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  /// The commands that make [cpu] and [memory] the app's defaults for [kind],
  /// which is `limit` or `reserve`. Empty when nothing would change.
  List<List<String>> _plan(String kind, Map<String, String> defaults, SyncedController cpu, SyncedController memory) {
    final app = widget.app;
    final wanted = {'cpu': cpu.text.trim(), 'memory': memory.text.trim()};
    final saved = {
      for (final e in defaults.entries)
        if (e.key.startsWith('$kind-') && e.value.isNotEmpty) e.key.substring(kind.length + 1): e.value,
    };
    if (wanted.entries.every((e) => e.value == (saved[e.key] ?? ''))) return const [];

    // Dokku ignores an empty value, so taking one away means clearing the
    // defaults and setting the others again, including those not shown here.
    final removes = wanted.entries.any((e) => e.value.isEmpty && saved.containsKey(e.key));
    final set = {
      for (final e in wanted.entries)
        if (e.value.isNotEmpty) e.key: e.value,
      if (removes)
        for (final e in saved.entries)
          if (!wanted.containsKey(e.key)) e.key: e.value,
    };
    return [
      if (removes) ['resource:$kind-clear', '--process-type', '_default_', app],
      if (set.isNotEmpty) ['resource:$kind', for (final e in set.entries) ...['--${e.key}', e.value], app],
    ];
  }

  Future<void> _apply(List<List<String>> commands) => busy('apply', () => DokkuRunner(ref, widget.host).all(commands));

  Future<void> _clear() => busy('clear', () async {
        final app = widget.app;
        final run = DokkuRunner(ref, widget.host);
        const ask = Confirm(
          title: 'Clear resource limits?',
          body: 'Removes all CPU and memory limits and reservations for this app, including those set for '
              'one process type. Takes effect on the next deploy or restart.',
          label: 'Clear limits',
        );
        if (!await confirm(context, ask)) return;
        final r = await run.all([
          ['resource:limit-clear', app],
          ['resource:reserve-clear', app],
        ]);
        if (r?.ok != true || !mounted) return;
        for (final f in _fields) {
          f.controller.clear();
        }
      });

  @override
  Widget build(BuildContext context) {
    final report = ref.report(widget.host, 'resource', widget.app);
    final resources = parseResource(report.data ?? const {});
    final defaults = resources['_default_'] ?? const <String, String>{};
    _cpuLimit.sync(defaults['limit-cpu'] ?? '');
    _memoryLimit.sync(defaults['limit-memory'] ?? '');
    _cpuReserve.sync(defaults['reserve-cpu'] ?? '');
    _memoryReserve.sync(defaults['reserve-memory'] ?? '');
    final perType = [
      for (final e in resources.entries)
        if (e.key != '_default_') '${e.key}: ${e.value.entries.map((v) => '${v.key} ${v.value}').join(' · ')}',
    ];
    final plan = [
      ..._plan('limit', defaults, _cpuLimit, _memoryLimit),
      ..._plan('reserve', defaults, _cpuReserve, _memoryReserve),
    ];
    final command = plan.isEmpty
        ? '\$ dokku resource:limit --cpu <cpus> --memory <size> ${widget.app}\n'
            '\$ dokku resource:reserve --cpu <cpus> --memory <size> ${widget.app}'
        : [for (final args in plan) '\$ ${displayCommand(args)}'].join('\n');

    Widget pair(String label, SyncedController limit, SyncedController reserve, String hint) => Row(children: [
          Expanded(
            child: Field('$label limit',
                child: AppInput(controller: limit.controller, hint: hint, onChanged: (_) => setState(() {}))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Field('$label reserve',
                child: AppInput(controller: reserve.controller, hint: '—', onChanged: (_) => setState(() {}))),
          ),
        ]);

    final buttons = Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end, children: [
      Btn('Clear limits', loading: isBusy('clear'), onPressed: report.hasData ? _clear : null),
      Btn('Apply limits',
          loading: isBusy('apply'), onPressed: report.hasData && plan.isNotEmpty ? () => _apply(plan) : null),
    ]);

    return LayoutBuilder(builder: (context, box) {
      // Two buttons leave little room for the commands beside them.
      final narrow = box.maxWidth < 720;
      return Panel.column(children: [
        const PanelHead('Resources', note: 'default for all process types'),
        if (report.loading) const LoadingRows(),
        if (report.error != null) EmptyBox('Could not read the resource limits. ${report.errorText}'),
        if (report.hasData)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              pair('CPU', _cpuLimit, _cpuReserve, '1.0'),
              const SizedBox(height: 14),
              pair('Memory', _memoryLimit, _memoryReserve, '512m'),
              if (perType.isNotEmpty) ...[
                const SizedBox(height: 14),
                Field('Set for one process type', child: CodeBlock(perType.join('\n'), color: C.muted)),
              ],
              const SizedBox(height: 14),
              Text(
                'Limits cap usage and reservations guarantee a minimum. Memory takes values such as 512m or 2g, '
                'and CPU is a share of the virtual CPUs. Empty a field to remove that limit. '
                'Applied on the next deploy or restart.',
                style: T.hint,
              ),
              if (narrow) ...[const SizedBox(height: 14), buttons],
            ]),
          ),
        CmdFooter(command, action: narrow ? null : buttons),
      ]);
    });
  }
}

class _ChecksCard extends ConsumerStatefulWidget {
  const _ChecksCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_ChecksCard> createState() => _ChecksCardState();
}

class _ChecksCardState extends ConsumerState<_ChecksCard> with Busy {
  static List<String> _list(String? v) =>
      v == null || v == 'none' ? const [] : v.split(RegExp(r'[,\s]+')).where((t) => t.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ps = ref.report(host, 'ps', app, refresh: _psRefresh);
    final scaleQ = ref.dokku(host, ['ps:scale', app], (r) => parseScale(r.stdout));
    final checks = ref.report(host, 'checks', app);
    final undeployed = ps.data != null && !isYes(ps.data!['deployed']);
    final types = [...?scaleQ.data?.keys];
    final disabled = _list(checks.data?['checks disabled list']);
    final skipped = _list(checks.data?['checks skipped list']);
    final wait = checks.data?['checks computed wait to retire'] ?? '';
    final error = checks.error ?? scaleQ.error;
    final ready = checks.hasData && scaleQ.hasData;

    _Check stateOf(String type) {
      if (disabled.contains(type) || disabled.contains('_all_')) return _Check.disabled;
      if (skipped.contains(type) || skipped.contains('_all_')) return _Check.skipped;
      return _Check.enabled;
    }

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < _narrowCard;
      return Panel.column(children: [
        PanelHead(
          'Zero-downtime checks',
          trailing: Btn('Run checks',
              loading: isBusy('run'),
              tooltip: undeployed ? _deployFirst : null,
              onPressed: undeployed
                  ? null
                  : () => busy('run', () => runDokku(context, ref, host, ['checks:run', app], timeout: const Duration(minutes: 10)))),
        ),
        if (error != null)
          EmptyBox('Could not read the checks. $error')
        else if (!ready)
          const LoadingRows()
        else if (types.isEmpty)
          const EmptyBox('No process types yet. Checks appear here after the first deploy.'),
        if (error == null && ready)
          for (final (i, type) in types.indexed)
            () {
              final state = stateOf(type), key = 'check-$type';
              final label = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _name(type),
                const SizedBox(height: 2),
                _detail('wait to retire ${wait.isEmpty ? '60' : wait}s'),
              ]);
              final control = Row(mainAxisSize: MainAxisSize.min, children: [
                if (isBusy(key)) const Padding(padding: EdgeInsets.only(right: 8), child: Spinner(size: 11)),
                Seg<_Check>(
                  value: state,
                  options: _Check.values,
                  labels: (c) => c.name,
                  small: true,
                  mono: true,
                  onChanged: isBusy(key)
                      ? null
                      : (next) {
                          if (next == state) return;
                          busy(key, () => runDokku(context, ref, host, [next.command, app, type]));
                        },
                ),
              ]);
              return PanelRow(
                first: i == 0,
                child: narrow
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [label, const SizedBox(height: 8), control])
                    : Row(children: [Expanded(child: label), const SizedBox(width: 12), control]),
              );
            }(),
        CmdFooter('\$ dokku checks:run $app\n\$ dokku checks:enable|skip|disable $app <type>'),
      ]);
    });
  }
}

class _PolicyCard extends ConsumerStatefulWidget {
  const _PolicyCard(this.host, this.app, {super.key});
  final Host host;
  final String app;

  @override
  ConsumerState<_PolicyCard> createState() => _PolicyCardState();
}

class _PolicyCardState extends ConsumerState<_PolicyCard> with Busy {
  /// The policy picked here and not saved yet.
  String? _picked;

  Future<void> _save(String policy) => busy('policy', () async {
        final host = widget.host, app = widget.app;
        final r = await runDokku(context, ref, host, ['ps:set', app, 'restart-policy', policy]);
        if (r?.ok != true) return;
        await _reread(ref, host, ['ps:report', app], refresh: _psRefresh);
        if (mounted && _picked == policy) setState(() => _picked = null);
      });

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ps = ref.report(host, 'ps', app, refresh: _psRefresh);
    final scheduler = ref.report(host, 'scheduler', app);
    final procs = procStatuses(ps.data ?? const {});

    String first(List<String?> values, String fallback) =>
        values.firstWhere((v) => v != null && v.isNotEmpty, orElse: () => fallback)!;
    final saved = first([ps.data?['ps restart policy'], ps.data?['ps computed restart policy']], '');
    final policy = _picked ?? saved;
    final selected = scheduler.data?['scheduler selected'] ?? '';
    final effective = first([selected, scheduler.data?['scheduler computed selected']], 'docker-local');
    final error = ps.error ?? scheduler.error;

    return Panel.column(children: [
      const PanelHead('Restart policy and scheduler'),
      if (error != null)
        EmptyBox('Could not read the restart policy and scheduler. $error')
      else if (!ps.hasData || !scheduler.hasData)
        const LoadingRows()
      else
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Field(
              'Restart policy',
              child: Row(children: [
                Expanded(
                  child: AppSelect<String>(
                    value: policy,
                    options: [..._policies, if (policy.isNotEmpty && !_policies.contains(policy)) policy],
                    hint: 'Choose a policy',
                    onChanged: (v) => setState(() => _picked = v),
                  ),
                ),
                const SizedBox(width: 8),
                Btn('Save policy',
                    loading: isBusy('policy'), onPressed: policy.isEmpty || policy == saved ? null : () => _save(policy)),
              ]),
            ),
            const SizedBox(height: 14),
            Field(
              'Scheduler',
              hint: _schedulerNotes[effective] ?? 'A scheduler provided by a plugin on this server.',
              trailing: isBusy('scheduler') ? const Spinner(size: 11) : null,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Seg<String>(
                  value: effective,
                  options: _schedulers,
                  mono: true,
                  onChanged: isBusy('scheduler')
                      ? null
                      : (next) {
                          if (next == selected) return;
                          // One stray tap here would change how the next deploy runs.
                          busy(
                            'scheduler',
                            () => runDokku(context, ref, host, ['scheduler:set', app, 'selected', next],
                                ask: Confirm(
                                  title: 'Use the $next scheduler for $app?',
                                  body: '${_schedulerNotes[next]} Takes effect on the next deploy or rebuild.',
                                  label: 'Switch scheduler',
                                )),
                          );
                        },
                ),
              ),
            ),
            if (procs.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 12, runSpacing: 6, children: [
                for (final p in procs) Dot(p.name, tone: p.running ? Tone.ok : Tone.mute),
              ]),
            ],
          ]),
        ),
      CmdFooter('\$ dokku ps:set $app restart-policy ${policy.isEmpty ? '<policy>' : policy}\n'
          '\$ ${displayCommand(['scheduler:set', app, 'selected', effective])}'),
    ]);
  }
}
