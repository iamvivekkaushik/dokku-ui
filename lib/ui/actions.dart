/// Helpers screens use to change things on the server.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/jobs.dart';
import 'widgets/kit.dart';

/// Runs a Dokku command as a job, asking first when [ask] is given.
///
/// Returns null if the user cancelled.
Future<ExecResult?> runDokku(
  BuildContext context,
  WidgetRef ref,
  Host host,
  List<String> args, {
  Confirm? ask,
  String? title,
  String? stdin,
  Map<String, String>? files,
  Duration timeout = const Duration(minutes: 30),
  bool quiet = false,
}) async {
  final run = DokkuRunner(ref, host);
  if (ask != null && !await confirm(context, ask)) return null;
  return run(args, title: title, stdin: stdin, files: files, timeout: timeout, quiet: quiet);
}

/// Runs the commands of one action, one after another.
///
/// Take it before the first `await`. From then on it does not need the screen,
/// so commands that belong together (clear the limits, then set the others
/// again) all run even when the user moves on while the first is still going.
class DokkuRunner {
  DokkuRunner(WidgetRef ref, this.host) : _jobs = ref.read(jobsProvider.notifier);
  final Host host;
  final JobsNotifier _jobs;

  /// [quiet] leaves a failure in the dock without opening the error dialog.
  /// [probe] is for a command that older or newer versions of Dokku lack: when
  /// that is why it failed nothing is recorded, and the caller runs another.
  Future<ExecResult> call(
    List<String> args, {
    String? title,
    String? stdin,
    Map<String, String>? files,
    Duration timeout = const Duration(minutes: 30),
    bool quiet = false,
    bool probe = false,
  }) =>
      _jobs.run(host, args, title: title, stdin: stdin, files: files, timeout: timeout, quiet: quiet, probe: probe);

  /// Runs [commands] in order and stops at the first that fails. Returns the
  /// result of the last one that ran, or null when there were none.
  Future<ExecResult?> all(Iterable<List<String>> commands, {String? title, Duration timeout = const Duration(minutes: 30)}) async {
    ExecResult? last;
    for (final args in commands) {
      last = await call(args, title: title, timeout: timeout);
      if (!last.ok) break;
    }
    return last;
  }
}

/// Tracks which actions are in flight so their buttons can show a spinner.
mixin Busy<W extends StatefulWidget> on State<W> {
  final _busy = <String>{};

  bool isBusy(String key) => _busy.contains(key);

  /// Marks [key] busy while [action] runs, which may be several commands.
  Future<R?> busy<R>(String key, Future<R?> Function() action) async {
    if (_busy.contains(key)) return null;
    setState(() => _busy.add(key));
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }
}

const stopConfirmBody = 'All processes stop and the app stops serving traffic until it is started again.';
