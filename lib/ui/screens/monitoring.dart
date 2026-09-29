import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/core.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../widgets/kit.dart';
import 'app/logs.dart';

final _loggerOff = RegExp('logger disabled', caseSensitive: false);
final _failedHeader = RegExp(r'^=====>\s+(\S+) failed deploy logs');
final _failedNoise = RegExp(r'^----->|No failed containers found');
final _failedCause = RegExp('error|fail|exit', caseSensitive: false);

class _FailedDeploy {
  _FailedDeploy(this.app);
  final String app;
  final lines = <String>[];

  /// The line most likely to say what went wrong.
  String get cause => lines.firstWhere(_failedCause.hasMatch, orElse: () => lines.last);
}

/// `logs:failed --all`, per app. Null when this Dokku does not have it.
List<_FailedDeploy>? _parseFailed(ExecResult r) {
  if (notSupported(r.output)) return null;
  final out = <_FailedDeploy>[];
  _FailedDeploy? current;
  for (final raw in stripAnsi(r.stdout + r.stderr).split('\n')) {
    final header = _failedHeader.firstMatch(raw);
    if (header != null) {
      out.add(current = _FailedDeploy(header[1]!));
    } else if (raw.trim().isNotEmpty && !_failedNoise.hasMatch(raw)) {
      current?.lines.add(raw.replaceFirst(RegExp(r'^\s+!\s+'), ''));
    }
  }
  return [for (final f in out) if (f.lines.isNotEmpty) f];
}

Color _eventColor(String kind) {
  bool has(String pattern) => RegExp(pattern, caseSensitive: false).hasMatch(kind);
  if (has('post-deploy|success|renew')) return Tone.ok.color;
  if (has('fail|error')) return Tone.bad.color;
  if (has('pre-deploy|build|receive')) return Tone.info.color;
  return C.soft;
}

class MonitoringScreen extends ConsumerStatefulWidget {
  const MonitoringScreen({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends ConsumerState<MonitoringScreen> with Busy {
  late final _tail = LogTail(ref.read(sshServiceProvider));
  final _filter = TextEditingController();
  var _all = false;

  @override
  void dispose() {
    _tail.dispose();
    _filter.dispose();
    super.dispose();
  }

  static LogLine? _parseEvent(String line) {
    final e = parseEvent(line);
    return e == null ? null : eventLogLine(e);
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final router = ref.read(routerProvider.notifier);
    final apps = ref.watch(appsProvider(host.id));
    final names = apps.value?.names ?? const <String>[];
    final loggerOn =
        ref.dokku(host, ['events:list'], (r) => !_loggerOff.hasMatch(r.stdout + r.stderr), lenient: true);
    // With the logger off there is nothing to follow.
    _tail.follow(host, loggerOn.data == true ? ['events', '-t'] : null, _parseEvent);
    final failed = ref.dokku(host, ['logs:failed', '--all'], (r) => (apps: _parseFailed(r)), lenient: true);
    final health = names.isEmpty
        ? null
        : ref.batch(host, [['checks:report'], ['ps:report']],
            (r) => (checks: parseReports(r[0].stdout), ps: parseReports(r[1].stdout)));

    return PageBody(children: [
      PageHead(eyebrow: host.name, title: 'Logs & monitoring', actions: [
        for (final n in names.take(8))
          Btn('$n logs', mono: true, onPressed: () => router.go(AppDetailRoute(n, AppTab.logs))),
      ]),
      TwoCol(
        left: [ListenableBuilder(listenable: _tail, builder: (context, _) => _events(host, loggerOn))],
        right: [
          Panel.column(children: [
            PanelHead('Failed deploys', trailing: Text('logs:failed --all', style: T.meta)),
            if (failed.loading) const LoadingRows(rows: 1),
            if (failed.error != null) EmptyBox('Could not read the failed deploys: ${failed.errorText}'),
            if (failed.data != null && failed.data!.apps == null)
              const EmptyBox('This Dokku version cannot list failed deploys for every app. Open an app\'s Logs tab and pick "failed".'),
            if (failed.data?.apps?.isEmpty ?? false) const EmptyBox('No crashed deploy containers.'),
            for (final (i, f) in (failed.data?.apps ?? const <_FailedDeploy>[]).indexed)
              PanelRow(
                first: i == 0,
                onTap: () => router.go(AppDetailRoute(f.app, AppTab.logs)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(f.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, weight: FontWeight.w500)),
                      const SizedBox(height: 3),
                      Text(f.cause.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(10.5, color: C.bad)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Text(lineCount(f.lines.length), style: T.meta),
                ]),
              ),
          ]),
          Panel.column(children: [
            PanelHead('Health checks', trailing: Text('checks:report · ps:report', style: T.meta)),
            if ((apps.isLoading && !apps.hasValue) || (health?.loading ?? false)) const LoadingRows(rows: 1),
            if (apps.hasError && !apps.hasValue) EmptyBox('Could not list apps: ${apps.error}'),
            if (apps.hasValue && names.isEmpty) const EmptyBox('No apps on this host yet. Create one to see its health here.'),
            if (health?.error != null) EmptyBox('Could not read the health of the apps: ${health!.errorText}'),
            if (health?.data case final data?)
              LayoutBuilder(builder: (context, box) {
                final wide = box.maxWidth >= 460;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final (i, n) in names.indexed)
                    _HealthRow(
                      n,
                      ps: data.ps[n],
                      checks: data.checks[n],
                      first: i == 0,
                      showCount: wide,
                      onTap: () => router.go(AppDetailRoute(n, AppTab.processes)),
                    ),
                ]);
              }),
          ]),
        ],
      ),
    ]);
  }

  Widget _events(Host host, Q<bool> loggerOn) {
    final off = loggerOn.data == false;
    final q = _filter.text.trim().toLowerCase();
    final lines = _tail.lines;
    final relevant = _all ? lines : [for (final l in lines) if (isKeyEvent(l.proc)) l];
    final matching = q.isEmpty ? relevant : [for (final l in relevant) if ('${l.proc} ${l.msg}'.toLowerCase().contains(q)) l];
    // Newest first.
    final shown = (matching.length > 300 ? matching.sublist(matching.length - 300) : matching).reversed.toList();
    final connecting = loggerOn.loading || (loggerOn.data == true && _tail.state == TailState.idle);

    return Panel.column(children: [
      PanelHead(
        'Platform events',
        trailing: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 140, child: AppInput(controller: _filter, hint: 'Filter', onChanged: (_) => setState(() {}))),
          Seg<bool>(
            small: true,
            value: _all,
            options: const [false, true],
            labels: (all) => all ? 'All triggers' : 'Changes only',
            onChanged: (all) => setState(() => _all = all),
          ),
          if (off)
            Btn('Enable logger',
                loading: isBusy('events-on'),
                onPressed: () => busy('events-on', () => runDokku(context, ref, host, ['events:on'])))
          else
            switch (_tail.state) {
              TailState.live => const Pill('events -t', tone: Tone.ok, mono: true, pulse: true),
              TailState.idle => const Pill('connecting', tone: Tone.mute, mono: true),
              TailState.ended => const Pill('ended', tone: Tone.mute, mono: true),
              TailState.error => const Pill('reconnecting', tone: Tone.warn, mono: true),
            },
        ]),
      ),
      if (loggerOn.error != null)
        EmptyBox('Could not check the events logger: ${loggerOn.errorText}')
      else if (off)
        const EmptyBox(
            'The events logger is off. Turn it on to record deploys, config changes and plugin actions to /var/log/dokku/events.log.')
      else if (shown.isEmpty && _tail.state == TailState.error)
        EmptyBox('${_tail.error}${_tail.error.endsWith('.') ? '' : '.'} Trying again in a few seconds.')
      else if (shown.isEmpty && connecting)
        const LoadingRows()
      else if (shown.isEmpty)
        EmptyBox(q.isNotEmpty
            ? 'No events match.'
            : _all
                ? 'No events yet.'
                : 'No deploys or config changes in the last ${lines.length} logged triggers.'),
      if (shown.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: shown.length,
            itemBuilder: (_, i) {
              final e = shown[i];
              return PanelRow(
                first: i == 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 70, child: Text(e.ts, maxLines: 1, style: T.mono(11.5, color: C.dim, height: 1.5))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: e.proc, style: TextStyle(color: _eventColor(e.proc))),
                        TextSpan(text: ' ${e.msg}'),
                      ]),
                      style: T.mono(11.5, color: C.soft, height: 1.5),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      const CmdFooter('\$ dokku events -t  ·  events:list  ·  events:on / events:off'),
    ]);
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow(this.app,
      {required this.ps, required this.checks, required this.first, required this.showCount, required this.onTap});
  final String app;
  final Report? ps;
  final Report? checks;
  final bool first;
  final bool showCount;
  final VoidCallback onTap;

  static bool _listed(String? v) => v != null && v.isNotEmpty && v != 'none';

  @override
  Widget build(BuildContext context) {
    final deployed = isYes(ps?['deployed']);
    final procs = ps == null ? const <ProcStatus>[] : procStatuses(ps!);
    final hasWeb = procs.any((p) => p.type == 'web') || (deployed && procs.isEmpty);
    final up = procs.where((p) => p.running).length;
    final (tone, label) = !deployed
        ? (Tone.mute, 'not deployed')
        : up == 0
            ? (Tone.bad, 'down')
            : up < procs.length
                ? (Tone.warn, 'degraded')
                : (Tone.ok, _listed(checks?['checks disabled list']) ? 'up · checks off' : 'passing');
    final count = '${hasWeb ? '$up/${procs.length} up' : 'no web'}${_listed(checks?['checks skipped list']) ? ' · skipped' : ''}';

    return PanelRow(
      first: first,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(child: Text(app, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.body)),
        if (showCount) ...[const SizedBox(width: 12), Text(count, style: T.meta)],
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 70),
          child: Align(alignment: Alignment.centerRight, widthFactor: 1, child: Dot(label, tone: tone)),
        ),
      ]),
    );
  }
}
