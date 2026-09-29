import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/format.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../state/queries.dart';
import '../../widgets/kit.dart';

final _webUrl = RegExp(r'^https?://');

class OverviewTab extends ConsumerWidget {
  const OverviewTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.report(host, 'ps', app, refresh: const Duration(seconds: 15));
    final git = ref.report(host, 'git', app);
    final appReport = ref.report(host, 'apps', app);
    final builder = ref.report(host, 'builder', app);
    final urls = ref.dokku(host, ['urls', app], (r) => parseLines(r.stdout).where(_webUrl.hasMatch).toList(), lenient: true);
    final activity = ref.watch(activityProvider(host.id));
    // Samples are only collected while the host metrics are being watched.
    final metrics = host.hasShell ? ref.watch(metricsProvider(host.id)) : null;
    final samples = ref.watch(samplesProvider.select((s) => s['${host.id}/$app'])) ?? const <Sample>[];

    final current = samples.lastOrNull;
    final cores = metrics?.value?.cores;
    final procs = ps.data == null ? const <ProcStatus>[] : procStatuses(ps.data!);
    final changes = [
      for (final e in activity.value ?? const <ActivityEntry>[])
        if (e.command.split(' ').contains(app)) e,
    ].take(6).toList();

    final String? noSamples;
    if (!host.hasShell) {
      noSamples = 'Connect as a shell user to see container metrics.';
    } else if (metrics!.hasError || metrics.value?.dockerAvailable == false) {
      noSamples = 'Container metrics are not available on this host.';
    } else if (samples.isEmpty) {
      noSamples = procs.any((p) => p.running) ? 'Collecting the first sample.' : 'No running containers.';
    } else {
      noSamples = null;
    }

    final cpu = [for (final s in samples) s.cpu];
    final mem = [for (final s in samples) s.mem];
    final limit = current?.limit ?? 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      AutoGrid(minWidth: 260, fit: true, children: [
          _MeterCard(
            title: 'CPU',
            note: 'last ${samples.isEmpty ? '5 min' : '${samples.length * 10}s'}',
            value: current == null ? '—' : current.cpu.toStringAsFixed(1),
            unit: cores == null ? '%' : '% of $cores vCPU',
            values: cpu,
            max: cpu.fold(10, math.max),
            empty: noSamples,
          ),
          _MeterCard(
            title: 'Memory',
            note: limit > 0 ? 'limit ${formatBytes(limit, digits: 0)}' : '',
            value: current == null ? '—' : (current.mem / (1024 * 1024)).toStringAsFixed(0),
            unit: 'MiB',
            values: mem,
            max: mem.fold(limit, math.max),
            opacity: .45,
            empty: noSamples,
          ),
          _ReleaseCard(git: git, ps: ps.data, builder: builder.data, app: appReport.data),
      ]),
      const SizedBox(height: 16),
      TwoCol(
        left: [
          Panel.column(children: [
            PanelHead('Containers', trailing: Text('${ps.data?['processes'] ?? '—'} processes', style: T.meta)),
            if (ps.loading) const LoadingRows(),
            if (ps.error != null) EmptyBox('Could not read the processes of $app: ${ps.errorText}'),
            if (ps.data != null && procs.isEmpty)
              EmptyBox(isYes(ps.data!['deployed'])
                  ? 'No containers are running. Start the app to bring them back.'
                  : 'Not deployed yet. Use Deploy app to push code or an image.'),
            for (final (i, p) in procs.indexed)
              PanelRow(
                first: i == 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(children: [
                  Dot('', tone: p.running ? Tone.ok : Tone.mute),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12))),
                  const SizedBox(width: 10),
                  Text(p.cid.isEmpty ? '—' : p.cid.substring(0, math.min(12, p.cid.length)), style: T.meta),
                  const SizedBox(width: 10),
                  Text(p.state, style: T.sans(11.5, color: (p.running ? Tone.ok : Tone.mute).color)),
                ]),
              ),
            if (urls.data?.isNotEmpty ?? false)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: C.line))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final (i, u) in urls.data!.indexed) ...[
                    if (i > 0) const SizedBox(height: 4),
                    Row(children: [
                      Flexible(child: LinkText(u, onTap: () => _open(u), style: T.code)),
                      const SizedBox(width: 6),
                      const Icon(LucideIcons.externalLink, size: 11, color: C.muted),
                    ]),
                  ],
                ]),
              ),
          ]),
        ],
        right: [
          Panel.column(children: [
            const PanelHead('Recent changes', note: 'from this console'),
            if (activity.isLoading && !activity.hasValue) const LoadingRows(),
            if (activity.hasError && !activity.hasValue) EmptyBox('Could not read the history of changes: ${activity.error}'),
            if (activity.hasValue && changes.isEmpty) EmptyBox('No changes to $app made from this console yet.'),
            for (final (i, e) in changes.indexed)
              PanelRow(
                first: i == 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(children: [
                  Dot('', tone: e.ok ? Tone.ok : Tone.bad),
                  const SizedBox(width: 12),
                  Expanded(child: Text(e.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code)),
                  const SizedBox(width: 12),
                  Text(formatMs(e.durationMs), style: T.meta),
                  const SizedBox(width: 12),
                  Text(ago(e.at), style: T.meta),
                ]),
              ),
          ]),
        ],
      ),
    ]);
  }

  static Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on Exception {
      // No browser to hand the address to; the link stays on screen.
    }
  }
}

/// A figure with its recent history as bars.
class _MeterCard extends StatelessWidget {
  const _MeterCard({
    required this.title,
    required this.note,
    required this.value,
    required this.unit,
    required this.values,
    required this.max,
    this.opacity = .85,
    this.empty,
  });
  final String title;
  final String note;
  final String value;
  final String unit;
  final List<double> values;
  final double max;
  final double opacity;
  final String? empty;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(16),
        // Beside a taller card the chart stays at the bottom edge.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(title, style: T.title),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(note, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
                ),
              ]),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(value, style: T.stat),
                const SizedBox(width: 6),
                Flexible(
                    child: Text(unit, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(11.5, color: C.muted))),
              ]),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Sparkbars(values: values, max: max, opacity: opacity, empty: empty),
            ),
          ],
        ),
      );
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.git, required this.ps, required this.builder, required this.app});
  final Q<Report> git;
  final Report? ps;
  final Report? builder;
  final Report? app;

  @override
  Widget build(BuildContext context) {
    final g = git.data;
    final sha = g?['git sha'] ?? '';
    final image = g?['git source image'] ?? '';
    final updated = g?['git last updated at'] ?? '';
    final source = app?['app deploy source'] ?? '';

    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Release', style: T.title),
        const SizedBox(height: 10),
        if (git.loading) const Skeleton(height: 96),
        if (git.error != null) EmptyBox('Could not read the release: ${git.errorText}', margin: EdgeInsets.zero),
        if (g != null)
          KVList([
            (
              'Commit',
              '${sha.isNotEmpty && sha != 'HEAD' ? sha.substring(0, math.min(12, sha.length)) : '—'}'
                  ' · ${firstFilled([g['git deploy branch'], g['git global deploy branch']], 'master')}',
            ),
            if (image.isNotEmpty) ('Image', image),
            ('Builder', firstFilled([builder?['builder computed selected'], builder?['builder selected']], 'auto')),
            ('Deployed', updated.isNotEmpty ? ago(updated) : (isYes(ps?['deployed']) ? 'yes' : 'never')),
            ('Restart policy', firstFilled([ps?['ps computed restart policy'], ps?['ps restart policy']], '—')),
            if (source.isNotEmpty) ('Source', source),
          ]),
      ]),
    );
  }
}
