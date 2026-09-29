import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core.dart';

enum AppTab {
  overview('Overview'),
  deploys('Deploys'),
  build('Build'),
  processes('Processes'),
  env('Environment'),
  routing('Routing'),
  storage('Storage & network'),
  logs('Logs'),
  settings('Settings');

  const AppTab(this.label);
  final String label;
}

enum Section { dashboard, apps, datastores, monitoring, server }

sealed class AppRoute {
  const AppRoute();

  /// Which top-level section this screen belongs to.
  Section get section;
}

class DashboardRoute extends AppRoute {
  const DashboardRoute();
  @override
  Section get section => Section.dashboard;
  @override
  bool operator ==(Object other) => other is DashboardRoute;
  @override
  int get hashCode => 1;
}

class AppsRoute extends AppRoute {
  const AppsRoute();
  @override
  Section get section => Section.apps;
  @override
  bool operator ==(Object other) => other is AppsRoute;
  @override
  int get hashCode => 2;
}

class AppDetailRoute extends AppRoute {
  const AppDetailRoute(this.app, [this.tab = AppTab.overview]);
  final String app;
  final AppTab tab;
  @override
  Section get section => Section.apps;
  @override
  bool operator ==(Object other) => other is AppDetailRoute && other.app == app && other.tab == tab;
  @override
  int get hashCode => Object.hash(app, tab);
}

class DatastoresRoute extends AppRoute {
  const DatastoresRoute();
  @override
  Section get section => Section.datastores;
  @override
  bool operator ==(Object other) => other is DatastoresRoute;
  @override
  int get hashCode => 3;
}

class MonitoringRoute extends AppRoute {
  const MonitoringRoute();
  @override
  Section get section => Section.monitoring;
  @override
  bool operator ==(Object other) => other is MonitoringRoute;
  @override
  int get hashCode => 4;
}

class ServerRoute extends AppRoute {
  const ServerRoute();
  @override
  Section get section => Section.server;
  @override
  bool operator ==(Object other) => other is ServerRoute;
  @override
  int get hashCode => 5;
}

class InstallRoute extends AppRoute {
  const InstallRoute();
  @override
  Section get section => Section.server;
  @override
  bool operator ==(Object other) => other is InstallRoute;
  @override
  int get hashCode => 6;
}

/// Where the user is, with enough history for the back button.
class RouteStack extends Notifier<List<AppRoute>> {
  @override
  List<AppRoute> build() => const [DashboardRoute()];

  AppRoute get current => state.last;
  bool get canGoBack => state.length > 1;

  void go(AppRoute route) {
    if (route == state.last) return;
    // Switching tabs inside an app replaces the entry rather than stacking.
    final last = state.last;
    final sameApp = route is AppDetailRoute && last is AppDetailRoute && last.app == route.app;
    final base = sameApp ? state.sublist(0, state.length - 1) : state;
    final next = [...base, route];
    state = next.length > 30 ? next.sublist(next.length - 30) : next;
    if (route is AppDetailRoute) ref.read(prefsProvider.notifier).update((p) => p.copyWith(lastApp: () => route.app));
  }

  /// Jumps to a top-level section, clearing history.
  void section(AppRoute route) => state = [if (route is! DashboardRoute) const DashboardRoute(), route];

  void back() {
    if (state.length > 1) state = state.sublist(0, state.length - 1);
  }
}

final routerProvider = NotifierProvider<RouteStack, List<AppRoute>>(RouteStack.new);

final routeProvider = Provider<AppRoute>((ref) => ref.watch(routerProvider).last);
