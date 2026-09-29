import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/core.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../shell/action_dialogs.dart';
import '../shell/app_switcher.dart' show processSummary;
import '../shell/destroy_dialog.dart';
import '../widgets/kit.dart';
import 'dashboard.dart' show healthTone;

class AppsScreen extends ConsumerStatefulWidget {
  const AppsScreen({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends ConsumerState<AppsScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final apps = ref.watch(appsProvider(host.id));
    final grid = ref.watch(prefsProvider.select((p) => p.appsGrid)) || Bp.isCompact(context);
    final q = _filter.text.trim().toLowerCase();
    final list = [
      for (final a in apps.value?.apps ?? const <AppSummary>[])
        if (a.name.contains(q) || a.domains.any((d) => d.contains(q))) a,
    ];
    final compact = Bp.isCompact(context);

    return PageBody(children: [
      PageHead(eyebrow: host.name, title: 'Apps', actions: [
        SizedBox(
          width: compact ? 170 : 220,
          child: AppInput(controller: _filter, large: true, mono: false, hint: 'Filter apps', onChanged: (_) => setState(() {})),
        ),
        if (!compact)
          Seg<bool>(
            value: grid,
            options: const [true, false],
            labels: (g) => g ? 'Grid' : 'List',
            onChanged: (g) => ref.read(prefsProvider.notifier).update((p) => p.copyWith(appsGrid: g)),
          ),
        Btn('Create app', icon: LucideIcons.plus, variant: BtnVariant.primary, size: BtnSize.md, onPressed: () => showCreateApp(context, host)),
      ]),
      if (apps.hasError && !apps.hasValue) EmptyBox('Could not list apps: ${apps.error}', margin: EdgeInsets.zero),
      if (apps.isLoading && !apps.hasValue)
        AutoGrid(minWidth: 300, children: [
          for (var i = 0; i < 3; i++)
            const Panel(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                height: 170,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Skeleton(width: 140, height: 16),
                  SizedBox(height: 14),
                  Skeleton(height: 26),
                  SizedBox(height: 14),
                  Skeleton(width: 190, height: 12),
                ]),
              ),
            ),
        ]),
      if (apps.hasValue && list.isEmpty)
        EmptyBox(
          '',
          margin: EdgeInsets.zero,
          child: Column(children: [
            Text.rich(
              // An empty host and a filter that matches nothing need different next steps.
              TextSpan(children: [
                if (q.isEmpty) ...[
                  TextSpan(text: 'No apps on ${host.name} yet. Create one, then '),
                  TextSpan(text: 'git push dokku main', style: T.mono(11.5, color: C.muted)),
                  const TextSpan(text: '.'),
                ] else ...[
                  TextSpan(text: 'No apps match “$q”. '),
                  TextSpan(text: 'dokku apps:create <name>', style: T.mono(11.5, color: C.muted)),
                  const TextSpan(text: ' to add one.'),
                ],
              ]),
              textAlign: TextAlign.center,
              style: T.small,
            ),
            const SizedBox(height: 10),
            Btn('Create app', icon: LucideIcons.plus, onPressed: () => showCreateApp(context, host)),
          ]),
        ),
      if (list.isNotEmpty && grid) AutoGrid(minWidth: 300, children: [for (final a in list) _AppCard(host, a, key: ValueKey(a.name))]),
      if (list.isNotEmpty && !grid) _AppTable(host, list),
    ]);
  }
}

class _AppCard extends ConsumerStatefulWidget {
  const _AppCard(this.host, this.app, {super.key});
  final Host host;
  final AppSummary app;

  @override
  ConsumerState<_AppCard> createState() => _AppCardState();
}

class _AppCardState extends ConsumerState<_AppCard> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host, a = widget.app;
    final router = ref.read(routerProvider.notifier);
    final procs = a.procs;
    final remote = host.gitRemote(a.name);
    final undeployed = a.health == AppHealth.undeployed;

    Widget action(String label, String key, List<String> args, {Confirm? ask, bool enabled = true}) => Expanded(
          child: Btn(label,
              loading: isBusy(key),
              onPressed: enabled ? () => busy(key, () => runDokku(context, ref, host, args, ask: ask)) : null),
        );

    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => router.go(AppDetailRoute(a.name)),
                child: Text(a.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(14, weight: FontWeight.w600, spacing: -.14)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Pill(a.health.name, tone: healthTone(a.health)),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.only(left: 8, right: 2),
          decoration: BoxDecoration(color: C.w(.04), border: Border.all(color: C.lineSoft), borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            Expanded(child: Text(remote, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.muted))),
            CopyBtn(remote),
          ]),
        ),
        const SizedBox(height: 12),
        if (procs.isEmpty)
          Text(undeployed ? 'not deployed' : 'no processes', style: T.mono(10.5, color: C.dim))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in procs)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(5)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 5, height: 5, decoration: BoxDecoration(color: p.running ? C.ok : C.mute, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text('${p.name}: ${p.state}', style: T.mono(10.5, color: C.soft)),
                ]),
              ),
          ]),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (a.domains.isEmpty) Text('No domains bound', style: T.sans(12, color: C.dim)),
            for (final d in a.domains.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  const Icon(LucideIcons.globe, size: 11, color: C.muted),
                  const SizedBox(width: 6),
                  Expanded(child: Text(d, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12, color: C.muted))),
                ]),
              ),
            if (a.domains.length > 3) Text('+${a.domains.length - 3} more', style: T.sans(12, color: C.dim)),
          ]),
        ),
        const SizedBox(height: 12),
        Container(height: 1, color: C.lineSoft),
        const SizedBox(height: 12),
        Row(children: [
          action('Restart', 'restart', ['ps:restart', a.name], enabled: !undeployed),
          const SizedBox(width: 6),
          action('Rebuild', 'rebuild', ['ps:rebuild', a.name], enabled: !undeployed),
          const SizedBox(width: 6),
          if (a.health == AppHealth.stopped)
            action('Start', 'start', ['ps:start', a.name])
          else
            action('Stop', 'stop', ['ps:stop', a.name],
                enabled: !undeployed, ask: Confirm(title: 'Stop ${a.name}?', body: stopConfirmBody, label: 'Stop app', danger: true)),
          const SizedBox(width: 6),
          Expanded(child: Btn('Logs', onPressed: () => router.go(AppDetailRoute(a.name, AppTab.logs)))),
          const SizedBox(width: 6),
          _DestroyBtn(host, a.name),
        ]),
      ]),
    );
  }
}

class _AppTable extends ConsumerWidget {
  const _AppTable(this.host, this.apps);
  final Host host;
  final List<AppSummary> apps;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Panel.column(children: [
        THead([
          th('app', flex: 12),
          th('git remote', flex: 16),
          th('processes', flex: 14),
          th('domains', flex: 12),
          th('status', width: 100, align: TextAlign.right),
          const SizedBox(width: 40),
        ]),
        for (final a in apps)
          PanelRow(
            onTap: () => ref.read(routerProvider.notifier).go(AppDetailRoute(a.name)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Expanded(flex: 12, child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(13, weight: FontWeight.w600))),
              Expanded(
                  flex: 16,
                  child: Text(host.gitRemote(a.name), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.muted))),
              Expanded(
                flex: 14,
                child: Text(
                  a.procs.isEmpty ? '—' : processSummary(a),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono(11, color: C.soft),
                ),
              ),
              Expanded(
                flex: 12,
                child: Text(a.domains.isEmpty ? '—' : a.domains.join(', '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12, color: C.muted)),
              ),
              SizedBox(width: 100, child: Align(alignment: Alignment.centerRight, child: Dot(a.health.name, tone: healthTone(a.health)))),
              SizedBox(width: 40, child: Align(alignment: Alignment.centerRight, child: _DestroyBtn(host, a.name))),
            ]),
          ),
      ]);
}

/// Opens the destroy dialog for one app of the list.
class _DestroyBtn extends ConsumerStatefulWidget {
  const _DestroyBtn(this.host, this.app);
  final Host host;
  final String app;

  @override
  ConsumerState<_DestroyBtn> createState() => _DestroyBtnState();
}

class _DestroyBtnState extends ConsumerState<_DestroyBtn> with Busy {
  @override
  Widget build(BuildContext context) => Btn(
        '',
        icon: LucideIcons.trash2,
        variant: BtnVariant.dangerGhost,
        square: true,
        tooltip: 'Destroy app',
        loading: isBusy('destroy'),
        onPressed: () => busy('destroy', () => destroyApp(context, ref, widget.host, widget.app)),
      );
}
