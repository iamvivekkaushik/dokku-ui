/// Cached, read-only lookups: the output of Dokku commands and host scripts.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/host_scripts.dart';
import '../core/parse.dart';
import '../data/models.dart';
import '../data/platform.dart';
import 'core.dart';

class DokkuError implements Exception {
  DokkuError(this.result);
  final ExecResult result;
  @override
  String toString() {
    final out = stripAnsi(result.output).trim();
    return out.isEmpty ? 'exit ${result.code}' : out;
  }
}

/// One read-only command against one host.
class DokkuQuery {
  DokkuQuery(this.hostId, this.args, {this.lenient = false, this.refresh});
  final String hostId;
  final List<String> args;

  /// Return the result even when the command fails, e.g. to detect a missing command.
  final bool lenient;

  /// Re-run on this interval while something is watching.
  final Duration? refresh;

  late final String _key = '$hostId\u0001${args.join('\u0001')}\u0001$lenient\u0001${refresh?.inSeconds}';

  @override
  bool operator ==(Object other) => other is DokkuQuery && other._key == _key;
  @override
  int get hashCode => _key.hashCode;
}

Host _host(Ref ref, String id) {
  final host = ref.watch(hostsProvider.select((h) => h.value?.where((x) => x.id == id).firstOrNull));
  if (host == null) throw StateError('This host is no longer saved.');
  return host;
}

/// Keeps a result for a short while after the last screen stops watching, so
/// moving between tabs does not refetch everything.
void _cacheFor(Ref ref, Duration duration) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() => timer = Timer(duration, link.close));
  ref.onResume(() => timer?.cancel());
  ref.onDispose(() => timer?.cancel());
}

void _refreshEvery(Ref ref, Duration? interval) {
  if (interval == null) return;
  final timer = Timer(interval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
}

final dokkuProvider = FutureProvider.autoDispose.family<ExecResult, DokkuQuery>((ref, q) async {
  ref.watch(generationProvider(q.hostId));
  final host = _host(ref, q.hostId);
  _cacheFor(ref, const Duration(seconds: 20));
  final result = await ref.watch(sshServiceProvider).dokku(host, q.args, timeout: const Duration(minutes: 1));
  _refreshEvery(ref, q.refresh);
  if (!result.ok && !q.lenient) throw DokkuError(result);
  return result;
});

class BatchQuery {
  BatchQuery(this.hostId, this.commands, {this.refresh});
  final String hostId;
  final List<List<String>> commands;
  final Duration? refresh;

  late final String _key = '$hostId\u0002${commands.map((c) => c.join('\u0001')).join('\u0002')}\u0002${refresh?.inSeconds}';

  @override
  bool operator ==(Object other) => other is BatchQuery && other._key == _key;
  @override
  int get hashCode => _key.hashCode;
}

/// Several commands in one go over the same connection.
final dokkuBatchProvider = FutureProvider.autoDispose.family<List<ExecResult>, BatchQuery>((ref, q) async {
  ref.watch(generationProvider(q.hostId));
  final host = _host(ref, q.hostId);
  _cacheFor(ref, const Duration(seconds: 20));
  final results = await ref.watch(sshServiceProvider).dokkuAll(host, q.commands);
  _refreshEvery(ref, q.refresh);
  return results;
});

/// The state of a lookup as a screen needs it: data stays visible while it
/// refreshes, and parsing problems surface as errors instead of crashes.
class Q<T> {
  const Q._({this.data, this.error, this.loading = false, this.refreshing = false});
  final T? data;
  final Object? error;
  final bool loading;
  final bool refreshing;

  bool get hasData => data != null;
  String get errorText => error == null ? '' : '$error';

  static Q<T> from<T, R>(AsyncValue<R> value, T Function(R) parse) {
    final raw = value.value;
    if (raw != null) {
      try {
        return Q._(data: parse(raw), refreshing: value.isLoading);
      } on Object catch (e) {
        return Q._(error: e);
      }
    }
    if (value.hasError) return Q._(error: value.error);
    return const Q._(loading: true);
  }
}

extension DokkuLookups on WidgetRef {
  /// Runs a read-only command and parses its output.
  Q<T> dokku<T>(Host host, List<String> args, T Function(ExecResult) parse, {bool lenient = false, Duration? refresh}) =>
      Q.from(watch(dokkuProvider(DokkuQuery(host.id, args, lenient: lenient, refresh: refresh))), parse);

  /// `<plugin>:report <app>` as a key/value map.
  Q<Report> report(Host host, String plugin, String app, {Duration? refresh, bool lenient = false}) =>
      dokku(host, ['$plugin:report', app], (r) => parseReport(r.stdout), refresh: refresh, lenient: lenient);

  Q<T> batch<T>(Host host, List<List<String>> commands, T Function(List<ExecResult>) parse, {Duration? refresh}) =>
      Q.from(watch(dokkuBatchProvider(BatchQuery(host.id, commands, refresh: refresh))), parse);
}

class AppSummary {
  const AppSummary({required this.name, required this.health, required this.ps, required this.domains});
  final String name;
  final AppHealth health;
  final Report ps;
  final List<String> domains;

  List<ProcStatus> get procs => procStatuses(ps);
}

class AppsData {
  const AppsData(this.apps, this.globalVhosts);
  final List<AppSummary> apps;
  final List<String> globalVhosts;

  List<String> get names => [for (final a in apps) a.name];
  AppSummary? find(String name) => apps.where((a) => a.name == name).firstOrNull;
}

final _appName = RegExp(r'^[a-z0-9][a-z0-9-]*$');
final _noApps = RegExp(r"haven't deployed|no apps", caseSensitive: false);

/// Every app on a host with its processes and domains.
final appsProvider = FutureProvider.autoDispose.family<AppsData, String>((ref, hostId) async {
  final results = await ref.watch(dokkuBatchProvider(BatchQuery(
    hostId,
    [['--quiet', 'apps:list'], ['ps:report'], ['domains:report']],
    refresh: const Duration(seconds: 30),
  )).future);
  final list = results[0], ps = results[1], dom = results[2];
  if (!list.ok && !_noApps.hasMatch(list.output)) throw DokkuError(list);
  final psReports = parseReports(ps.stdout), domReports = parseReports(dom.stdout);
  final names = parseLines(list.stdout).where(_appName.hasMatch);
  return AppsData(
    [
      for (final name in names)
        AppSummary(
          name: name,
          ps: psReports[name] ?? const {},
          health: appHealth(psReports[name]),
          domains: words(domReports[name]?['domains app vhosts']),
        ),
    ],
    words(domReports.values.firstOrNull?['domains global vhosts']),
  );
});

/// CPU, memory, disk and containers. Only for hosts connected with a shell user.
final metricsProvider = FutureProvider.autoDispose.family<HostMetrics, String>((ref, hostId) async {
  final host = _host(ref, hostId);
  if (!host.hasShell) throw StateError('Host metrics need a shell user.');
  _cacheFor(ref, const Duration(seconds: 15));
  final r = await ref.watch(sshServiceProvider).exec(host, metricsScript, timeout: const Duration(seconds: 30));
  _refreshEvery(ref, const Duration(seconds: 10));
  final metrics = parseMetrics(r.stdout);
  ref.read(samplesProvider.notifier).record(hostId, metrics);
  return metrics;
});

class Sample {
  const Sample(this.cpu, this.mem, this.limit);
  final double cpu;
  final double mem;
  final double limit;
}

/// Recent CPU and memory samples per app, built up from [metricsProvider].
class SamplesNotifier extends Notifier<Map<String, List<Sample>>> {
  @override
  Map<String, List<Sample>> build() => const {};

  void record(String hostId, HostMetrics m) {
    final byApp = <String, List<ContainerMetric>>{};
    for (final c in m.containers.where((c) => c.running && !c.name.startsWith('dokku.'))) {
      byApp.putIfAbsent(c.name.split('.').first, () => []).add(c);
    }
    final next = {...state};
    byApp.forEach((app, cs) {
      final key = '$hostId/$app';
      final sample = Sample(
        cs.fold(0, (s, c) => s + (c.cpuPct ?? 0)),
        cs.fold(0, (s, c) => s + (c.memBytes ?? 0)),
        cs.fold(0, (s, c) => (c.memLimit ?? 0) > s ? c.memLimit! : s),
      );
      final list = [...?next[key], sample];
      next[key] = list.length > 30 ? list.sublist(list.length - 30) : list;
    });
    Future.microtask(() {
      if (ref.mounted) state = next;
    });
  }
}

final samplesProvider = NotifierProvider<SamplesNotifier, Map<String, List<Sample>>>(SamplesNotifier.new);

/// Versions and OS details shown on the dashboard and server page.
final systemProvider = FutureProvider.autoDispose.family<Map<String, String>, String>((ref, hostId) async {
  ref.watch(generationProvider(hostId));
  final host = _host(ref, hostId);
  _cacheFor(ref, const Duration(minutes: 5));
  final ssh = ref.watch(sshServiceProvider);
  final version = await ssh.dokku(host, ['version'], timeout: const Duration(seconds: 20));
  final out = <String, String>{
    'dokku': RegExp(r'dokku version (\S+)', caseSensitive: false).firstMatch(version.output)?[1] ?? '',
  };
  if (host.hasShell) {
    final r = await ssh.exec(host, systemScript, timeout: const Duration(seconds: 20));
    out.addAll(sections(r.stdout));
  }
  return out;
});

/// What the install wizard checks before it runs.
final preflightProvider = FutureProvider.autoDispose.family<Map<String, String>, String>((ref, hostId) async {
  final host = _host(ref, hostId);
  final r = await ref.watch(sshServiceProvider).exec(host, preflightScript, timeout: const Duration(seconds: 30));
  return sections(r.stdout);
});

/// The newest Dokku release, from GitHub. Null when it cannot be reached.
final latestDokkuProvider = FutureProvider<String?>((ref) async {
  try {
    final r = await http
        .get(Uri.parse('https://api.github.com/repos/dokku/dokku/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    return (jsonDecode(r.body) as Map<String, dynamic>)['tag_name'] as String?;
  } on Object {
    return null;
  }
});

class DnsCheck {
  const DnsCheck(this.name, this.addresses, this.matches);
  final String name;
  final List<String> addresses;

  /// Whether the name points at this host. Null when that cannot be told.
  final bool? matches;
}

class DnsQuery {
  DnsQuery(this.hostId, this.names);
  final String hostId;
  final List<String> names;
  late final String _key = '$hostId ${names.join(',')}';

  @override
  bool operator ==(Object other) => other is DnsQuery && other._key == _key;
  @override
  int get hashCode => _key.hashCode;
}

final _ipAddress = RegExp(r'^[\d.]+$|:');

/// Checks whether each domain resolves to the host it is configured on.
final dnsProvider = FutureProvider.autoDispose.family<Map<String, DnsCheck>, DnsQuery>((ref, q) async {
  final host = _host(ref, q.hostId);
  _cacheFor(ref, const Duration(minutes: 5));
  final hostIps = _ipAddress.hasMatch(host.host) ? [host.host] : await resolveHost(host.host);
  final checks = await Future.wait(q.names.map((name) async {
    final probe = name.startsWith('*.') ? 'dokku-console-probe.${name.substring(2)}' : name;
    final addresses = await resolveHost(probe);
    return DnsCheck(name, addresses, hostIps.isEmpty ? null : addresses.any(hostIps.contains));
  }));
  return {for (final c in checks) c.name: c};
});

final activityProvider = FutureProvider.autoDispose.family<List<ActivityEntry>, String>((ref, hostId) async {
  ref.watch(generationProvider(hostId));
  final all = await ref.watch(activityLogProvider).load();
  return [for (final e in all) if (e.hostId == hostId) e];
});
