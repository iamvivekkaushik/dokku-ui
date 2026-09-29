import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../widgets/kit.dart';
import 'app/build.dart';
import 'app/deploys.dart';
import 'app/env.dart';
import 'app/logs.dart';
import 'app/overview.dart';
import 'app/processes.dart';
import 'app/routing.dart';
import 'app/settings.dart';
import 'app/storage.dart';
import 'dashboard.dart' show healthTone;

class AppDetailScreen extends ConsumerStatefulWidget {
  const AppDetailScreen({super.key, required this.host, required this.app, required this.tab});
  final Host host;
  final String app;
  final AppTab tab;

  @override
  ConsumerState<AppDetailScreen> createState() => _AppDetailScreenState();
}

class _AppDetailScreenState extends ConsumerState<AppDetailScreen> with Busy {
  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app, tab = widget.tab;
    final router = ref.read(routerProvider.notifier);
    final list = ref.watch(appsProvider(host.id));

    final crumb = Row(children: [
      LinkText('Apps', onTap: () => router.section(const AppsRoute()), style: T.sans(12)),
      Text('  /  ', style: T.sans(12, color: C.muted)),
      Flexible(child: Text(app, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12, weight: FontWeight.w500))),
    ]);

    // While the list is being read again it may not have an app that was just created or renamed.
    if (!list.isLoading && list.hasValue && list.value!.find(app) == null) {
      return PageBody(children: [
        crumb,
        EmptyBox('The app "$app" does not exist on ${host.name}.', margin: EdgeInsets.zero),
      ]);
    }

    final ps = ref.report(host, 'ps', app, refresh: const Duration(seconds: 15));
    final git = ref.report(host, 'git', app);
    final builder = ref.report(host, 'builder', app);
    final health = ps.data == null ? null : appHealth(ps.data);
    final sha = git.data?['git sha'] ?? '';
    final image = git.data?['git source image'] ?? '';
    final builderName = [builder.data?['builder computed selected'], builder.data?['builder selected'], builder.data?['builder detected']]
        .firstWhere((b) => b != null && b.isNotEmpty, orElse: () => 'auto-detect')!;
    final undeployed = health == AppHealth.undeployed;

    Widget action(String label, String key, List<String> args, {Confirm? ask, BtnVariant variant = BtnVariant.outline, bool enabled = true}) =>
        Btn(label,
            size: BtnSize.md,
            variant: variant,
            loading: isBusy(key),
            onPressed: enabled ? () => busy(key, () => runDokku(context, ref, host, args, ask: ask)) : null);

    return PageBody(children: [
      crumb,
      PageHead(
        title: app,
        titleTrailing: health == null ? null : Pill(health.name, tone: healthTone(health)),
        below: Wrap(spacing: 14, runSpacing: 4, children: [
          Text(host.gitRemote(app), style: T.mono(11, color: C.muted)),
          Text(builderName, style: T.mono(11, color: C.muted)),
          if (sha.isNotEmpty && sha != 'HEAD') _meta('rev', sha.substring(0, sha.length.clamp(0, 7))),
          if (image.isNotEmpty) _meta('image', image),
        ]),
        actions: [
          action('Restart', 'restart', ['ps:restart', app], enabled: !undeployed),
          action('Rebuild', 'rebuild', ['ps:rebuild', app], enabled: !undeployed),
          if (health == AppHealth.stopped)
            action('Start', 'start', ['ps:start', app])
          else
            action('Stop', 'stop', ['ps:stop', app],
                variant: BtnVariant.danger,
                enabled: !undeployed,
                ask: Confirm(title: 'Stop $app?', body: stopConfirmBody, label: 'Stop app', danger: true)),
        ],
      ),
      UnderlineTabs(
        tabs: [for (final t in AppTab.values) (t.name, t.label)],
        selected: tab.name,
        onSelect: (id) => router.go(AppDetailRoute(app, AppTab.values.byName(id))),
      ),
      KeyedSubtree(
        key: ValueKey(tab),
        child: switch (tab) {
          AppTab.overview => OverviewTab(host: host, app: app),
          AppTab.deploys => DeploysTab(host: host, app: app),
          AppTab.build => BuildTab(host: host, app: app),
          AppTab.processes => ProcessesTab(host: host, app: app),
          AppTab.env => EnvTab(host: host, app: app),
          AppTab.routing => RoutingTab(host: host, app: app),
          AppTab.storage => StorageTab(host: host, app: app),
          AppTab.logs => LogsTab(host: host, app: app),
          AppTab.settings => SettingsTab(host: host, app: app),
        },
      ),
    ]);
  }

  static Widget _meta(String k, String v) => Text.rich(
        TextSpan(children: [TextSpan(text: '$k '), TextSpan(text: v, style: const TextStyle(color: C.soft))]),
        style: T.mono(11, color: C.muted),
      );
}
