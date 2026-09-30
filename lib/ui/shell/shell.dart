import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/core.dart';
import '../../state/jobs.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../screens/app_detail.dart';
import '../screens/apps.dart';
import '../screens/dashboard.dart';
import '../screens/datastores.dart';
import '../screens/install.dart';
import '../screens/monitoring.dart';
import '../screens/server.dart';
import '../screens/store.dart';
import '../widgets/kit.dart';
import 'action_dialogs.dart';
import 'app_switcher.dart';
import 'connect_dialog.dart';
import 'error_dialog.dart';
import 'job_dock.dart';
import 'terminal.dart';

class _Nav {
  const _Nav(this.label, this.icon, this.section, {this.tab});
  final String label;
  final IconData icon;
  final Section section;

  /// Set for the shortcuts that open a tab of the current app.
  final AppTab? tab;
}

const _sidebar = [
  _Nav('Dashboard', LucideIcons.layoutDashboard, Section.dashboard),
  _Nav('Apps', LucideIcons.box, Section.apps),
  _Nav('Store', LucideIcons.store, Section.store),
  _Nav('Datastores', LucideIcons.database, Section.datastores),
  _Nav('Domains & SSL', LucideIcons.globe, Section.apps, tab: AppTab.routing),
  _Nav('Environment', LucideIcons.keyRound, Section.apps, tab: AppTab.env),
  _Nav('Networking & storage', LucideIcons.network, Section.apps, tab: AppTab.storage),
  _Nav('Logs & monitoring', LucideIcons.activity, Section.monitoring),
  _Nav('Server & SSH', LucideIcons.server, Section.server),
];

AppRoute _routeFor(Section s) => switch (s) {
      Section.dashboard => const DashboardRoute(),
      Section.apps => const AppsRoute(),
      Section.store => const StoreRoute(),
      Section.datastores => const DatastoresRoute(),
      Section.monitoring => const MonitoringRoute(),
      Section.server => const ServerRoute(),
    };

/// The phone's bottom bar. The Store has no tab of its own there; it is
/// reached from Apps, whose tab stays lit while in it.
const _bottomSections = [Section.dashboard, Section.apps, Section.datastores, Section.monitoring, Section.server];

int _bottomIndex(Section s) {
  final i = _bottomSections.indexOf(s);
  return i < 0 ? _bottomSections.indexOf(Section.apps) : i;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  var _errorOpen = false;

  void _navigate(_Nav n) {
    final router = ref.read(routerProvider.notifier);
    final tab = n.tab;
    if (tab == null) return router.section(_routeFor(n.section));
    final app = ref.read(currentAppProvider);
    app == null ? router.section(const AppsRoute()) : router.go(AppDetailRoute(app, tab));
  }

  bool _active(_Nav n, AppRoute route) {
    if (route is AppDetailRoute) {
      // Tabs that have their own sidebar entry light that entry up instead of "Apps".
      final shortcut = _sidebar.where((x) => x.tab == route.tab).firstOrNull;
      return shortcut != null ? identical(n, shortcut) : n.tab == null && n.section == Section.apps;
    }
    return n.tab == null && n.section == route.section;
  }

  void _toggleSidebar() => ref.read(prefsProvider.notifier).update((p) => p.copyWith(sidebarOpen: !p.sidebarOpen));

  void _openTerminal(Host host) {
    if (host.hasShell) {
      openTerminal(context, host, const TerminalSpec.shell());
    } else {
      showAppDialog<void>(
        context,
        (_) => AppDialog(
          title: 'Dokku console · ${host.name}',
          width: 900,
          bodyPadding: const EdgeInsets.all(12),
          children: [SizedBox(height: MediaQuery.sizeOf(context).height * .6, child: DokkuConsole(host: host))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(connectionMonitorProvider);
    ref.listen(failedJobProvider, (_, job) async {
      if (job == null || _errorOpen) return;
      _errorOpen = true;
      await showAppDialog<void>(context, (_) => CommandErrorDialog(job));
      _errorOpen = false;
      ref.read(failedJobProvider.notifier).clear();
    });

    final hosts = ref.watch(hostsProvider);
    final host = ref.watch(currentHostProvider);
    final route = ref.watch(routeProvider);
    final stack = ref.watch(routerProvider);
    final compact = Bp.isCompact(context);

    final Widget body;
    if (hosts.isLoading && !hosts.hasValue) {
      body = const SizedBox.shrink();
    } else if (route is InstallRoute) {
      body = InstallScreen(host: host);
    } else if (host == null) {
      body = const _Welcome();
    } else {
      body = KeyedSubtree(
        key: ValueKey('${host.id}/${route is AppDetailRoute ? route.app : route.runtimeType}'),
        child: switch (route) {
          DashboardRoute() => DashboardScreen(host: host),
          AppsRoute() => AppsScreen(host: host),
          StoreRoute() => StoreScreen(host: host),
          AppDetailRoute(:final app, :final tab) => AppDetailScreen(host: host, app: app, tab: tab),
          DatastoresRoute() => DatastoresScreen(host: host),
          MonitoringRoute() => MonitoringScreen(host: host),
          ServerRoute() => ServerScreen(host: host),
          InstallRoute() => InstallScreen(host: host),
        },
      );
    }

    final content = Column(children: [
      _TopBar(
        host: host,
        onSearch: host == null ? null : () => showSearch_(context, host),
        onTerminal: host == null ? null : () => _openTerminal(host),
        onDeploy: host == null ? null : () => showDeploy(context, host, app: route is AppDetailRoute ? route.app : null),
        onActivity: host == null ? null : () => _showActivity(context, host),
      ),
      const _ConnectionAlert(),
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: body),
          Positioned(right: 16, bottom: 16, left: compact ? 16 : null, child: const JobDock()),
        ]),
      ),
    ]);

    final scaffold = Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        bottom: !compact,
        child: compact
            ? content
            : Row(children: [
                _Sidebar(
                  open: ref.watch(prefsProvider.select((p) => p.sidebarOpen)),
                  enabled: host != null,
                  appCount: host == null ? null : ref.watch(appsProvider(host.id)).value?.apps.length,
                  isActive: (n) => _active(n, route),
                  onSelect: _navigate,
                  onToggle: _toggleSidebar,
                ),
                Expanded(child: content),
              ]),
      ),
      bottomNavigationBar: compact && host != null
          ? NavigationBar(
              selectedIndex: _bottomIndex(route.section),
              onDestinationSelected: (i) => ref.read(routerProvider.notifier).section(_routeFor(_bottomSections[i])),
              destinations: const [
                NavigationDestination(icon: Icon(LucideIcons.layoutDashboard), label: 'Dashboard'),
                NavigationDestination(icon: Icon(LucideIcons.box), label: 'Apps'),
                NavigationDestination(icon: Icon(LucideIcons.database), label: 'Datastores'),
                NavigationDestination(icon: Icon(LucideIcons.activity), label: 'Monitor'),
                NavigationDestination(icon: Icon(LucideIcons.server), label: 'Server'),
              ],
            )
          : null,
    );

    return PopScope(
      canPop: stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(routerProvider.notifier).back();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
            if (host != null) showSearch_(context, host);
          },
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () {
            if (host != null) showSearch_(context, host);
          },
        },
        child: Focus(autofocus: true, child: scaffold),
      ),
    );
  }
}

void _showActivity(BuildContext context, Host host) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close activity',
    barrierColor: C.bg.withValues(alpha: .5),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (_, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: SafeArea(child: _ActivityPanel(host)),
    ),
  );
}

class _ActivityPanel extends ConsumerWidget {
  const _ActivityPanel(this.host);
  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(activityProvider(host.id)).value ?? const <ActivityEntry>[];
    return Material(
      color: C.field,
      child: Container(
        width: 360,
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: C.lineStrong))),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
            child: Row(children: [
              Expanded(child: Text('Activity', style: T.title)),
              IconBtn(LucideIcons.x, tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
          Expanded(
            child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Nothing changed from this app yet. Commands you run appear here.',
                        textAlign: TextAlign.center, style: T.small),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.lineSoft))),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Container(
                                width: 6, height: 6, decoration: BoxDecoration(color: e.ok ? C.ok : C.bad, shape: BoxShape.circle)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(e.command, style: T.mono(11.5, height: 1.45)),
                              if (!e.ok && e.stderr != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(e.stderr!.trim().split('\n').last,
                                      maxLines: 2, overflow: TextOverflow.ellipsis, style: T.mono(10.5, color: C.bad, height: 1.4)),
                                ),
                              const SizedBox(height: 3),
                              Text('${ago(e.at)} · ${e.ok ? 'ok' : 'exit ${e.code}'} · ${formatMs(e.durationMs)}', style: T.meta),
                            ]),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.open,
    required this.enabled,
    required this.appCount,
    required this.isActive,
    required this.onSelect,
    required this.onToggle,
  });
  final bool open;
  final bool enabled;
  final int? appCount;
  final bool Function(_Nav) isActive;
  final ValueChanged<_Nav> onSelect;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: open ? 232 : 56,
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [C.field, C.bg]),
          border: Border(right: BorderSide(color: C.line)),
        ),
        // Laid out at full width and clipped, so labels do not reflow mid-animation.
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: open ? 232 : 56,
            maxWidth: open ? 232 : 56,
            child: Column(children: [
              Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  const _Logo(),
                  if (open) ...[
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text('Dokku Console',
                            maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: T.sans(13.5, weight: FontWeight.w600, spacing: -.13))),
                  ],
                ]),
              ),
              Expanded(
                child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10), children: [
                  for (final n in _sidebar)
                    _NavItem(
                      nav: n,
                      open: open,
                      active: isActive(n),
                      enabled: enabled || n.section == Section.server,
                      count: n.tab == null && n.section == Section.apps ? appCount : null,
                      onTap: () => onSelect(n),
                    ),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: C.line))),
                child: _NavItem(
                  nav: const _Nav('Collapse', LucideIcons.panelLeft, Section.dashboard),
                  open: open,
                  active: false,
                  enabled: true,
                  muted: true,
                  onTap: onToggle,
                ),
              ),
            ]),
          ),
        ),
      );
}

class _Logo extends StatelessWidget {
  const _Logo({this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: C.fg, borderRadius: BorderRadius.circular(size * .27)),
        child: Text('dk', style: T.mono(size * .46, color: C.bg, weight: FontWeight.w500)),
      );
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.nav, required this.open, required this.active, required this.enabled, required this.onTap, this.count, this.muted = false});
  final _Nav nav;
  final bool open;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  final int? count;
  final bool muted;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.active;
    final color = !widget.enabled
        ? C.w(.25)
        : on || _hover
            ? C.fg
            : C.w(widget.muted ? .55 : .64);
    final item = Semantics(
      button: true,
      selected: on,
      enabled: widget.enabled,
      label: widget.nav.label,
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              height: 34,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: on ? C.w(.085) : (_hover && widget.enabled ? C.w(.06) : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: on ? C.w(.09) : Colors.transparent),
              ),
              child: Row(children: [
                Icon(widget.nav.icon, size: 15, color: color),
                if (widget.open) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(widget.nav.label,
                          maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: T.sans(12.5, weight: FontWeight.w500, color: color)),
                    ),
                  ),
                  if (widget.count != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: C.w(.06), borderRadius: BorderRadius.circular(20)),
                      child: Text('${widget.count}', style: T.meta),
                    ),
                  if (widget.muted) const Kbd('['),
                ],
              ]),
            ),
            if (on)
              Positioned(
                left: -8,
                top: 8,
                bottom: 10,
                child: Container(width: 2, decoration: BoxDecoration(color: C.fg, borderRadius: BorderRadius.circular(2))),
              ),
          ]),
        ),
      ),
    );
    return widget.open ? item : Tooltip(message: widget.nav.label, child: item);
  }
}

Color _connColor(ConnState s) => switch (s) {
      ConnState.connected => C.ok,
      ConnState.connecting => C.warn,
      ConnState.disconnected => C.bad,
      ConnState.idle => C.mute,
    };

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.host, this.onSearch, this.onTerminal, this.onDeploy, this.onActivity});
  final Host? host;
  final VoidCallback? onSearch;
  final VoidCallback? onTerminal;
  final VoidCallback? onDeploy;
  final VoidCallback? onActivity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = Bp.isCompact(context);
    final labels = Bp.isWideHeader(context);
    final h = host;
    final failures = h == null ? false : (ref.watch(activityProvider(h.id)).value ?? const []).take(5).any((e) => !e.ok);

    return Container(
      height: 52 + touchPad(context) / 2,
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16),
      decoration: BoxDecoration(color: C.bg, border: Border(bottom: BorderSide(color: C.line))),
      child: Row(children: [
        if (compact) ...[
          const _Logo(size: 28),
          const SizedBox(width: 10),
          // Takes the room that is left, so the actions sit at the right edge.
          Expanded(child: Align(alignment: Alignment.centerLeft, child: _HostSwitcher(compact: true, wide: false))),
          const SizedBox(width: 8),
        ] else
          Expanded(child: _Breadcrumb(host: h, wide: labels, onSearch: onSearch)),
        if (!compact) const SizedBox(width: 10),
        if (compact) IconBtn(LucideIcons.search, tooltip: 'Search', size: 15, onPressed: onSearch),
        if (compact)
          IconBtn(LucideIcons.terminal, tooltip: h?.hasShell ?? false ? 'SSH terminal' : 'Dokku console', size: 15, onPressed: onTerminal)
        else
          Btn(labels ? (h?.hasShell ?? true ? 'SSH terminal' : 'Dokku console') : '',
              icon: LucideIcons.terminal, variant: BtnVariant.outline, size: BtnSize.md, onPressed: onTerminal, tooltip: labels ? null : 'Terminal'),
        const SizedBox(width: 8),
        Btn(labels ? 'Deploy app' : '',
            icon: LucideIcons.arrowUp, variant: BtnVariant.primary, size: BtnSize.md, onPressed: onDeploy, tooltip: labels ? null : 'Deploy app'),
        const SizedBox(width: 8),
        Stack(clipBehavior: Clip.none, children: [
          IconBtn(LucideIcons.bell, tooltip: 'Activity', size: 15, onPressed: onActivity),
          if (failures)
            Positioned(
              right: 4,
              top: 4,
              child: IgnorePointer(
                child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: C.bad, shape: BoxShape.circle)),
              ),
            ),
        ]),
      ]),
    );
  }
}

/// Host, then the app in view, then search: the left side of the top bar.
///
/// The host keeps its size, search gives way first and the app name is cut
/// short last, so that nothing is pushed out of the bar in a narrow window.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.host, required this.wide, this.onSearch});
  final Host? host;
  final bool wide;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        const gap = 10.0, slash = 28.0;
        final hostMax = wide ? 320.0 : 170.0;
        final searchMin = wide ? 100.0 : 34.0;
        final appMax = (box.maxWidth - hostMax - slash - gap - searchMin).clamp(96.0, 260.0);
        final h = host;

        return Row(children: [
          ConstrainedBox(constraints: BoxConstraints(maxWidth: hostMax), child: _HostSwitcher(compact: false, wide: wide)),
          if (h != null) ...[
            SizedBox(
              width: slash,
              child: Text('/', textAlign: TextAlign.center, style: T.sans(16, color: const Color(0xFF3A3A40))),
            ),
            ConstrainedBox(constraints: BoxConstraints(maxWidth: appMax), child: AppSwitcher(host: h, showRevision: wide)),
          ],
          const SizedBox(width: gap),
          if (wide)
            Flexible(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: _SearchBox(onTap: onSearch)),
            )
          else
            _SearchButton(onTap: onSearch),
        ]);
      });
}

/// Search as a single button, for when there is no room for the field.
class _SearchButton extends StatelessWidget {
  const _SearchButton({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Search',
        child: Semantics(
          button: true,
          label: 'Search',
          child: MouseRegion(
            cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.line)),
                child: const Icon(LucideIcons.search, size: 13, color: C.muted),
              ),
            ),
          ),
        ),
      );
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Search',
        child: MouseRegion(
          cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.line)),
              child: Row(children: [
                const Icon(LucideIcons.search, size: 13, color: C.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Search apps, services, domains…',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, color: C.dim)),
                ),
                const Kbd('⌘K'),
              ]),
            ),
          ),
        ),
      );
}

class _HostSwitcher extends ConsumerWidget {
  const _HostSwitcher({required this.compact, required this.wide});
  final bool compact;

  /// Whether there is room for the address and the round-trip time.
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider).value ?? const <Host>[];
    final host = ref.watch(currentHostProvider);
    if (host == null) {
      return Btn('Connect a host',
          icon: LucideIcons.plus, variant: BtnVariant.outline, size: BtnSize.md, onPressed: () => showConnectDialog(context));
    }
    final status = ref.watch(currentStatusProvider);
    final color = _connColor(status.state);
    final label = switch (status.state) {
      ConnState.connected => status.rttMs != null ? formatMs(status.rttMs!) : 'connected',
      ConnState.connecting => 'connecting…',
      ConnState.disconnected => 'offline',
      ConnState.idle => 'idle',
    };

    return PopupMenuButton<String>(
      tooltip: 'Switch host',
      offset: const Offset(0, 40),
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 340),
      onSelected: (v) {
        if (v == '+') {
          showConnectDialog(context);
        } else if (v.startsWith('edit:')) {
          showConnectDialog(context, editing: hosts.firstWhere((h) => h.id == v.substring(5)));
        } else {
          ref.read(prefsProvider.notifier).update((p) => p.copyWith(hostId: () => v));
          ref.read(routerProvider.notifier).section(const DashboardRoute());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(enabled: false, height: 28, child: Text('HOSTS', style: T.eyebrow)),
        for (final h in hosts)
          PopupMenuItem<String>(
            value: h.id,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(children: [
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: h.id == host.id ? color : C.mute, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(h.name, style: T.sans(12.5, weight: FontWeight.w500)),
                  Text('${h.address} · ${h.isDokkuUser ? 'dokku user' : 'shell'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: T.meta),
                ]),
              ),
              if (h.id == host.id) const Icon(LucideIcons.check, size: 13, color: C.ok),
              IconBtn(LucideIcons.settings2, tooltip: 'Edit connection', onPressed: () {
                Navigator.of(context).pop();
                showConnectDialog(context, editing: h);
              }),
            ]),
          ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem<String>(
          value: '+',
          child: Row(children: [const Icon(LucideIcons.plus, size: 13), const SizedBox(width: 8), Text('Add host', style: T.body)]),
        ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 10, right: 8),
        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.lineStrong)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          PulseDot(color: color, ring: status.state != ConnState.idle),
          const SizedBox(width: 10),
          Flexible(child: Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, weight: FontWeight.w600))),
          if (wide) ...[
            const SizedBox(width: 10),
            Flexible(child: Text(host.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.muted))),
            const SizedBox(width: 10),
            Container(width: 1, height: 14, color: C.lineStrong),
            const SizedBox(width: 10),
            Text(label, style: T.mono(10.5, color: color)),
          ],
          const SizedBox(width: 6),
          const Icon(LucideIcons.chevronsUpDown, size: 12, color: C.muted),
        ]),
      ),
    );
  }
}

class _ConnectionAlert extends ConsumerWidget {
  const _ConnectionAlert();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(currentHostProvider);
    final status = ref.watch(currentStatusProvider);
    if (host == null || status.state != ConnState.disconnected) return const SizedBox.shrink();
    final changed = status.hostKeyChanged;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: Tone.warn.fill, border: Border(bottom: BorderSide(color: Tone.warn.border))),
      child: Row(children: [
        const Icon(LucideIcons.triangleAlert, size: 15, color: C.warn),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: changed ? 'Host key changed. ' : 'Host unreachable. ',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(
                  text: changed
                      ? 'The server sent a different key than the one saved, so nothing was sent to it. '
                          'Review the new key before connecting again.'
                      : status.error ?? 'Could not reach ${host.host}:${host.port}.',
                  style: TextStyle(color: C.warn.withValues(alpha: .8))),
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: T.sans(12.5, color: C.warn, height: 1.4),
          ),
        ),
        const SizedBox(width: 10),
        TextButton(
          onPressed: () => changed ? showConnectDialog(context, editing: host) : ref.read(sshServiceProvider).ping(host),
          style: TextButton.styleFrom(
            foregroundColor: C.warn,
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7), side: BorderSide(color: C.warn.withValues(alpha: .4))),
            textStyle: T.sans(12, weight: FontWeight.w500),
          ),
          child: Text(changed ? 'Review key' : 'Retry now'),
        ),
      ]),
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const _Logo(size: 48),
              const SizedBox(height: 16),
              Text('Connect your first Dokku host', textAlign: TextAlign.center, style: T.h1),
              const SizedBox(height: 12),
              Text(
                'This app talks to Dokku over SSH, straight from this device. Sign in as the dokku user to manage apps, '
                'or as root or a sudo user to also manage plugins, SSH keys and see host metrics.',
                textAlign: TextAlign.center,
                style: T.sans(13, color: C.muted, height: 1.6),
              ),
              const SizedBox(height: 18),
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                Btn('Connect a host',
                    icon: LucideIcons.plus, variant: BtnVariant.primary, size: BtnSize.md, onPressed: () => showConnectDialog(context)),
                Btn('Install Dokku on a server',
                    variant: BtnVariant.outline, size: BtnSize.md, onPressed: () => ref.read(routerProvider.notifier).go(const InstallRoute())),
              ]),
            ]),
          ),
        ),
      );
}
