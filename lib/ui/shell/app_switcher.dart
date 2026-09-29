import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/core.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../screens/dashboard.dart' show healthTone;
import '../widgets/kit.dart';
import 'action_dialogs.dart';

/// `web.1:up worker.1:down`, or why there is nothing to list.
String processSummary(AppSummary app) {
  final procs = app.procs;
  if (procs.isEmpty) return app.health == AppHealth.undeployed ? 'not deployed' : 'no processes';
  return procs.map((p) => '${p.name}:${p.running ? 'up' : 'down'}').join(' ');
}

/// Opens [app] where the user is: the same tab of another app, the overview
/// when coming from a list, or nowhere when the screen is not about one app.
void switchToApp(WidgetRef ref, String app) {
  final router = ref.read(routerProvider.notifier);
  switch (ref.read(routeProvider)) {
    case AppDetailRoute(:final tab):
      router.go(AppDetailRoute(app, tab));
    case DashboardRoute() || AppsRoute():
      router.go(AppDetailRoute(app));
    default:
      // Datastores, monitoring and the server page stay put; the shortcuts in
      // the sidebar follow the choice.
      ref.read(prefsProvider.notifier).update((p) => p.copyWith(lastApp: () => app));
  }
}

/// Shows [builder] just below [anchor], like a menu, until it is dismissed.
Future<R?> showAnchoredPanel<R>(BuildContext anchor, {required double width, required WidgetBuilder builder}) {
  final navigator = Navigator.of(anchor, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final box = anchor.findRenderObject()! as RenderBox;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final panelWidth = math.min(width, overlay.size.width - 16);
  final left = origin.dx.clamp(8.0, math.max(8.0, overlay.size.width - panelWidth - 8)).toDouble();
  final top = origin.dy + box.size.height + 6;

  return showGeneralDialog<R>(
    context: anchor,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, _, _) => Stack(children: [
      Positioned(
        left: left,
        top: top,
        width: panelWidth,
        child: Material(type: MaterialType.transparency, child: builder(context)),
      ),
    ]),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: .97, end: 1.0).animate(curved), alignment: Alignment.topLeft, child: child),
      );
    },
  );
}

enum AppSwitcherStyle {
  /// A bordered button, for the top bar.
  chip,

  /// Plain text with a chevron, for the end of a breadcrumb.
  crumb,
}

/// Names the app in view and opens a menu to move to another one.
class AppSwitcher extends ConsumerWidget {
  const AppSwitcher({super.key, required this.host, this.style = AppSwitcherStyle.chip, this.showRevision = false});
  final Host host;
  final AppSwitcherStyle style;

  /// Whether the deployed revision is shown beside the name.
  final bool showRevision;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(appsProvider(host.id));
    final name = ref.watch(currentAppProvider);
    final app = name == null ? null : apps.value?.find(name);
    final sha = showRevision && app != null ? (ref.report(host, 'git', app.name).data?['git sha'] ?? '') : '';
    final revision = sha.isEmpty || sha == 'HEAD' ? '' : sha.substring(0, math.min(7, sha.length));
    final label = name ?? (apps.isLoading && !apps.hasValue ? '…' : 'No apps');
    final tone = app == null ? Tone.mute : healthTone(app.health);

    void open() => showAnchoredPanel<void>(context, width: 300, builder: (_) => AppMenu(host: host, current: name));

    const chevrons = Icon(LucideIcons.chevronsUpDown, size: 12, color: C.muted);
    final text = Flexible(
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: style == AppSwitcherStyle.chip
              ? T.sans(12.5, weight: FontWeight.w600, color: name == null ? C.muted : C.fg)
              : T.sans(12, weight: FontWeight.w500, color: name == null ? C.muted : C.fg)),
    );

    final Widget face = switch (style) {
      AppSwitcherStyle.chip => _Hover(
          builder: (hover) => Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: hover ? C.elev : C.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.lineStrong),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: tone.color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              text,
              if (revision.isNotEmpty) ...[const SizedBox(width: 8), Text(revision, style: T.mono(10.5, color: C.muted))],
              const SizedBox(width: 8),
              chevrons,
            ]),
          ),
        ),
      AppSwitcherStyle.crumb => Padding(
          padding: EdgeInsets.symmetric(vertical: touchPad(context) / 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [text, const SizedBox(width: 5), chevrons]),
        ),
    };

    return Tooltip(
      message: 'Switch app',
      child: Semantics(
        button: true,
        label: 'Switch app, $label',
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: open, child: face),
        ),
      ),
    );
  }
}

class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(bool hover) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  var _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: widget.builder(_hover),
      );
}

/// The list behind [AppSwitcher]: find an app by name and go to it.
class AppMenu extends ConsumerStatefulWidget {
  const AppMenu({super.key, required this.host, required this.current});
  final Host host;
  final String? current;

  @override
  ConsumerState<AppMenu> createState() => _AppMenuState();
}

class _AppMenuState extends ConsumerState<AppMenu> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _go(String app) {
    Navigator.of(context).pop();
    switchToApp(ref, app);
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final apps = ref.watch(appsProvider(host.id));
    final q = _query.text.trim().toLowerCase();
    final all = apps.value?.apps ?? const <AppSummary>[];
    final rows = [for (final a in all) if (a.name.contains(q)) a];
    final navigator = Navigator.of(context);

    Widget link(String label, VoidCallback onTap) => _Hover(
          builder: (hover) => MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: touchPad(context) / 2),
                child: Text(label, style: T.sans(12, color: hover ? C.fg : C.muted)),
              ),
            ),
          ),
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.w(.12)),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 16))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: AppInput(
            controller: _query,
            mono: false,
            hint: 'Switch app…',
            // A keyboard that opens by itself would cover the list on a phone.
            autofocus: !Bp.isCompact(context),
            textInputAction: TextInputAction.go,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (rows.isNotEmpty) _go(rows.first.name);
            },
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (apps.isLoading && !apps.hasValue) const Padding(padding: EdgeInsets.all(10), child: Skeleton(height: 12)),
              if (apps.hasError && !apps.hasValue) _note('Could not list the apps. Check the connection and open this again.'),
              if (apps.hasValue && rows.isEmpty) _note(all.isEmpty ? 'No apps on ${host.name} yet.' : 'No apps match.'),
              for (final a in rows) _AppRow(a, current: a.name == widget.current, onTap: () => _go(a.name)),
            ]),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: C.w(.02), border: Border(top: BorderSide(color: C.line))),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            link('All apps', () {
              navigator.pop();
              ref.read(routerProvider.notifier).section(const AppsRoute());
            }),
            link('+ Create app', () {
              navigator.pop();
              showCreateApp(navigator.context, host);
            }),
          ]),
        ),
      ]),
    );
  }

  static Widget _note(String text) => Padding(
        padding: const EdgeInsets.all(14),
        child: Text(text, textAlign: TextAlign.center, style: T.sans(12, color: C.dim, height: 1.45)),
      );
}

class _AppRow extends StatelessWidget {
  const _AppRow(this.app, {required this.current, required this.onTap});
  final AppSummary app;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = healthTone(app.health).color;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: current ? C.w(.06) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: C.w(.06),
          splashColor: Colors.transparent,
          highlightColor: C.w(.04),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8 + touchPad(context) / 4),
            child: Row(children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, weight: FontWeight.w500)),
                  const SizedBox(height: 1),
                  Text(processSummary(app), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(10.5, color: C.muted)),
                ]),
              ),
              const SizedBox(width: 10),
              Text(app.health.name, style: T.mono(10.5, color: color)),
            ]),
          ),
        ),
      ),
    );
  }
}
