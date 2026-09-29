import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/host_scripts.dart';
import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../widgets/kit.dart';

Tone healthTone(AppHealth h) => switch (h) {
      AppHealth.running => Tone.ok,
      AppHealth.degraded => Tone.warn,
      AppHealth.stopped || AppHealth.undeployed => Tone.mute,
    };

class _Stat {
  const _Stat(this.label, this.value, this.unit, this.sub, this.percent, {this.delta, this.deltaTone, this.color = C.fg});
  final String label;
  final String value;
  final String unit;
  final String sub;
  final double percent;
  final String? delta;
  final Tone? deltaTone;
  final Color color;
}

class _Row {
  const _Row(this.name, this.app, this.cpu, this.mem, this.state, this.openApp);
  final String name;
  final String app;
  final String cpu;
  final String mem;
  final String state;

  /// The app to open when tapped, if this container belongs to one.
  final String? openApp;
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, required this.host});
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(appsProvider(host.id));
    final system = ref.watch(systemProvider(host.id)).value;
    final services = ref.watch(datastoresProvider(host.id)).value;
    final metrics = host.hasShell ? ref.watch(metricsProvider(host.id)) : null;
    final git = ref.dokku(host, ['git:report'], (r) => parseReports(r.stdout));
    final router = ref.read(routerProvider.notifier);

    final list = apps.value?.apps ?? const <AppSummary>[];
    final procs = [for (final a in list) for (final p in a.procs) (app: a.name, proc: p)];
    final running = procs.where((p) => p.proc.running).length;
    final m = metrics?.value;

    List<_Stat>? stats;
    if (m != null) {
      stats = _hostStats(m, list.length, services?.services.length ?? 0, running);
    } else if (!host.hasShell && apps.hasValue) {
      final deployed = list.where((a) => a.health != AppHealth.undeployed).length;
      final domains = list.fold<int>(0, (n, a) => n + a.domains.length);
      final down = list.where((a) => a.health == AppHealth.degraded || a.health == AppHealth.stopped).length;
      stats = [
        _Stat('Apps', '${list.length}', 'provisioned', '$down stopped or degraded', list.isEmpty ? 0 : deployed / list.length * 100,
            delta: '$deployed deployed'),
        _Stat('Processes', '$running', '/ ${procs.length} running', 'from ps:report', procs.isEmpty ? 0 : running / procs.length * 100,
            delta: procs.length - running > 0 ? '${procs.length - running} down' : 'all up',
            deltaTone: procs.length - running > 0 ? Tone.warn : Tone.ok,
            color: C.ok),
        _Stat('Services', '${services?.services.length ?? '—'}', 'datastores', '${services?.available.length ?? 0} plugins installed',
            ((services?.services.length ?? 0) * 10).clamp(0, 100).toDouble(),
            color: C.info),
        _Stat('Domains', '$domains', 'bound', 'global: ${apps.value!.globalVhosts.isEmpty ? 'none' : apps.value!.globalVhosts.join(' ')}',
            (domains * 8).clamp(0, 100).toDouble()),
      ];
    }

    final rows = m != null && m.dockerAvailable
        ? ([
            for (final c in m.containers)
              () {
                final parts = c.name.split('.');
                final service = c.name.startsWith('dokku.');
                final isApp = !service && list.any((a) => a.name == parts.first);
                return _Row(
                  c.name,
                  service ? '${parts.elementAtOrNull(1)}:${parts.skip(2).join('.')}' : (isApp ? parts.first : '—'),
                  c.cpuPct == null ? '—' : '${c.cpuPct!.toStringAsFixed(1)}%',
                  c.memBytes == null ? '—' : formatBytes(c.memBytes, digits: 0),
                  c.state,
                  isApp ? parts.first : null,
                );
              }(),
          ]..sort((a, b) {
            final up = (b.state == 'running' ? 1 : 0) - (a.state == 'running' ? 1 : 0);
            return up != 0 ? up : a.name.compareTo(b.name);
          }))
        : [for (final p in procs) _Row('${p.app}.${p.proc.name}', p.app, '—', '—', p.proc.state, p.app)];

    final deploys = [
      for (final e in (git.data ?? const <String, Report>{}).entries)
        (
          app: e.key,
          sha: e.value['git sha'] ?? '',
          at: num.tryParse(e.value['git last updated at'] ?? '') ?? 0,
          image: e.value['git source image'] ?? '',
          health: apps.value?.find(e.key)?.health ?? AppHealth.stopped,
        ),
    ].where((d) => d.at > 0 || (d.sha.isNotEmpty && d.sha != 'HEAD') || d.image.isNotEmpty).toList()
      ..sort((a, b) => b.at.compareTo(a.at));

    final uptime = m?.uptimeSec ?? double.tryParse((system?['uptime'] ?? '').split(' ').first);

    return PageBody(children: [
      PageHead(
        eyebrow: 'Server overview',
        title: host.name,
        actions: [
          Wrap(spacing: 16, runSpacing: 4, children: [
            _meta('dokku', system?['dokku'] ?? '…'),
            if ((system?['docker'] ?? '').isNotEmpty) _meta('docker', system!['docker']!),
            if ((system?['os'] ?? '').isNotEmpty && !Bp.isCompact(context)) _meta('', system!['os']!),
            if (uptime != null) _meta('uptime', formatDuration(uptime)),
          ]),
        ],
      ),
      AutoGrid(
        minWidth: Bp.isCompact(context) ? 150 : 220,
        gap: Bp.isCompact(context) ? 10 : 16,
        fit: true,
        children: stats == null
            ? [for (var i = 0; i < 4; i++) const _StatSkeleton()]
            : [for (final s in stats) _StatCard(s)],
      ),
      if (metrics?.hasError ?? false)
        Text('Host metrics are unavailable: ${metrics!.error}', style: T.sans(12, color: C.warn)),
      TwoCol(
        breakpoint: 880,
        left: [
          Panel.column(children: [
            PanelHead('Running containers',
                trailing: host.hasShell
                    ? const Pill('live · 10s', tone: Tone.ok, mono: true, pulse: true)
                    : const Pill('ps:report', tone: Tone.mute, mono: true, dot: false)),
            if (apps.isLoading && !apps.hasValue) const LoadingRows(),
            if (apps.hasError && !apps.hasValue) EmptyBox('Could not list apps: ${apps.error}'),
            if (apps.hasValue && rows.isEmpty) const EmptyBox('No containers yet. Deploy an app to see its processes here.'),
            if (rows.isNotEmpty) _ContainerTable(rows, onOpen: (app) => router.go(AppDetailRoute(app))),
          ]),
        ],
        right: [
          Panel.column(children: [
            PanelHead('Recent deployments',
                trailing: LinkText('View all', onTap: () => router.section(const AppsRoute()))),
            if (git.loading) const LoadingRows(),
            if (!git.loading && deploys.isEmpty) const EmptyBox('No deploys recorded yet.'),
            for (final (i, d) in deploys.take(8).indexed)
              PanelRow(
                first: i == 0,
                onTap: () => router.go(AppDetailRoute(d.app, AppTab.deploys)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(LucideIcons.gitCommitHorizontal, size: 14, color: healthTone(d.health).color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: d.app),
                          if (d.image.isNotEmpty) TextSpan(text: ' · image ${d.image}', style: const TextStyle(color: C.muted)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.body,
                      ),
                      const SizedBox(height: 3),
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: d.sha.isNotEmpty && d.sha != 'HEAD' ? d.sha.substring(0, d.sha.length.clamp(0, 7)) : 'image',
                              style: const TextStyle(color: C.soft)),
                          TextSpan(text: '  ${d.at > 0 ? ago(d.at) : '—'}'),
                        ]),
                        style: T.meta,
                      ),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Pill(d.health == AppHealth.running ? 'deployed' : d.health.name, tone: healthTone(d.health), mono: true, dot: false),
                ]),
              ),
          ]),
        ],
      ),
    ]);
  }

  static Widget _meta(String k, String v) => Text.rich(
        TextSpan(children: [
          if (k.isNotEmpty) TextSpan(text: '$k '),
          TextSpan(text: v, style: const TextStyle(color: C.fg)),
        ]),
        style: T.mono(11.5, color: C.muted),
      );

  static List<_Stat> _hostStats(HostMetrics m, int apps, int services, int running) {
    final memUsed = m.memTotal - m.memAvailable;
    final memPct = m.memTotal > 0 ? memUsed / m.memTotal * 100 : 0.0;
    final diskPct = m.diskTotal > 0 ? m.diskUsed / m.diskTotal * 100 : 0.0;
    final up = m.containers.where((c) => c.running).length;
    final cpu = m.cpuPct ?? 0;
    List<String> split(double bytes) => formatBytes(bytes).split(' ');
    return [
      _Stat('CPU', m.cpuPct == null ? '—' : '${cpu.round()}', '% · ${m.cores ?? '?'} vCPU',
          'load ${m.load.map((l) => l.toStringAsFixed(2)).join(' ')}', cpu,
          delta: m.load.isEmpty ? null : 'load ${m.load.first.toStringAsFixed(2)}', color: cpu > 85 ? C.bad : C.fg),
      _Stat('Memory', split(memUsed)[0], '${split(memUsed)[1]} / ${formatBytes(m.memTotal)}',
          'swap ${formatBytes(m.swapTotal - m.swapFree)} / ${formatBytes(m.swapTotal)}', memPct,
          delta: '${memPct.round()}%',
          deltaTone: memPct > 85 ? Tone.bad : (memPct > 70 ? Tone.warn : Tone.ok),
          color: memPct > 85 ? C.bad : (memPct > 70 ? C.warn : C.fg)),
      _Stat('Disk', split(m.diskUsed)[0], '${split(m.diskUsed)[1]} / ${formatBytes(m.diskTotal)}',
          '${m.diskDevice} · ${diskPct.round()}%', diskPct,
          delta: '${formatBytes(m.diskAvail)} free',
          deltaTone: diskPct > 90 ? Tone.bad : null,
          color: diskPct > 90 ? C.bad : (diskPct > 80 ? C.warn : C.fg)),
      _Stat('Containers', '${m.dockerAvailable ? up : running}', 'running', '$apps apps · $services services',
          m.containers.isEmpty ? 0 : up / m.containers.length * 100,
          delta: m.dockerAvailable ? '${m.containers.length - up} stopped' : 'docker n/a', color: C.ok),
    ];
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.s);
  final _Stat s;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text(s.label, style: T.title),
            const SizedBox(width: 8),
            Expanded(
              child: Text(s.delta ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: T.mono(10.5, color: s.deltaTone?.color ?? C.muted)),
            ),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(s.value, style: T.stat),
            const SizedBox(width: 6),
            Flexible(child: Text(s.unit, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(11.5, color: C.muted))),
          ]),
          const SizedBox(height: 12),
          TickMeter(percent: s.percent, color: s.color),
          const SizedBox(height: 12),
          Text(s.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
        ]),
      );
}

class _StatSkeleton extends StatelessWidget {
  const _StatSkeleton();

  @override
  Widget build(BuildContext context) => const Panel(
        padding: EdgeInsets.all(16),
        child: SizedBox(
          height: 86,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Skeleton(width: 70, height: 10),
            Skeleton(width: 96, height: 26, radius: 6),
            Skeleton(height: 6),
          ]),
        ),
      );
}

class _ContainerTable extends StatelessWidget {
  const _ContainerTable(this.rows, {required this.onOpen});
  final List<_Row> rows;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // Drop the numeric columns rather than squeezing names on a phone.
        final wide = box.maxWidth >= 460;
        return Column(children: [
          THead([
            th('container', flex: 14),
            if (wide) th('app', flex: 10),
            if (wide) th('cpu', width: 62, align: TextAlign.right),
            if (wide) th('memory', width: 84, align: TextAlign.right),
            th('state', width: 84, align: TextAlign.right),
          ]),
          for (final r in rows)
            PanelRow(
              onTap: r.openApp == null ? null : () => onOpen(r.openApp!),
              child: Row(children: [
                Expanded(
                  flex: 14,
                  child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.code),
                ),
                if (wide)
                  Expanded(
                    flex: 10,
                    child: Text(r.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, color: C.soft)),
                  ),
                if (wide) SizedBox(width: 62, child: Text(r.cpu, textAlign: TextAlign.right, style: T.code)),
                if (wide) SizedBox(width: 84, child: Text(r.mem, textAlign: TextAlign.right, style: T.code)),
                SizedBox(
                  width: 84,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Dot(r.state, tone: r.state == 'running' ? Tone.ok : Tone.mute),
                  ),
                ),
              ]),
            ),
        ]);
      });
}
