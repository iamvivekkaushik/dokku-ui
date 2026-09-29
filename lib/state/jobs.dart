/// Commands that change something. Each one becomes a job with live output,
/// shown in the dock at the bottom of the screen.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/command.dart';
import '../core/parse.dart';
import '../core/tar.dart';
import '../data/models.dart';
import '../data/ssh_service.dart';
import 'core.dart';

enum JobStatus { running, ok, failed }

class JobChunk {
  const JobChunk(this.text, this.isStderr);
  final String text;
  final bool isStderr;
}

class Job {
  const Job({
    required this.id,
    required this.title,
    required this.command,
    required this.args,
    required this.host,
    required this.startedAt,
    this.output = const [],
    this.status = JobStatus.running,
    this.code,
    this.durationMs = 0,
  });

  final int id;
  final String title;

  /// As shown to the user: secrets are already masked.
  final String command;
  final List<String> args;
  final Host host;
  final DateTime startedAt;
  final List<JobChunk> output;
  final JobStatus status;
  final int? code;
  final int durationMs;

  String get text => stripAnsi(output.map((c) => c.text).join());

  Job copyWith({List<JobChunk>? output, JobStatus? status, int? code, int? durationMs}) => Job(
        id: id,
        title: title,
        command: command,
        args: args,
        host: host,
        startedAt: startedAt,
        output: output ?? this.output,
        status: status ?? this.status,
        code: code ?? this.code,
        durationMs: durationMs ?? this.durationMs,
      );
}

class JobsNotifier extends Notifier<List<Job>> {
  var _seq = 0;
  final _streams = <int, RemoteStream>{};

  /// What a failed job was sent on stdin, kept while the job is in the dock so
  /// that retrying it sends the same again. Never written to storage.
  final _retry = <int, ({List<int>? input, Duration timeout})>{};

  @override
  List<Job> build() {
    ref.onDispose(() {
      for (final s in _streams.values) {
        s.kill();
      }
    });
    return const [];
  }

  void _update(int id, Job Function(Job) change) {
    state = [for (final j in state) j.id == id ? change(j) : j];
  }

  void dismiss(int id) {
    _retry.remove(id);
    state = [for (final j in state) if (j.id != id) j];
  }

  /// Runs a failed job again, with the input it had the first time.
  Future<ExecResult> retry(Job job) {
    final before = _retry[job.id];
    dismiss(job.id);
    return _run(job.host, job.args, title: job.title, input: before?.input, timeout: before?.timeout ?? const Duration(minutes: 30));
  }

  void cancel(int id) => _streams[id]?.kill();

  /// Runs a Dokku command on [host], streaming its output into a job.
  ///
  /// [files] are sent as a tar archive on stdin, which is how `certs:add`
  /// expects its certificate and key. A [quiet] run does not open the error
  /// dialog when it fails. A [probe] leaves no trace when it fails because
  /// this Dokku does not have the command.
  Future<ExecResult> run(
    Host host,
    List<String> args, {
    String? title,
    String? stdin,
    Map<String, String>? files,
    Duration timeout = const Duration(minutes: 30),
    bool quiet = false,
    bool probe = false,
  }) =>
      _run(
        host,
        args,
        title: title,
        input: files != null ? makeTar(files) : (stdin == null ? null : utf8.encode(stdin)),
        timeout: timeout,
        quiet: quiet,
        probe: probe,
      );

  Future<ExecResult> _run(
    Host host,
    List<String> args, {
    String? title,
    List<int>? input,
    required Duration timeout,
    bool quiet = false,
    bool probe = false,
  }) async {
    final id = ++_seq;
    final shown = displayCommand(args);
    final job = Job(
      id: id,
      title: title ?? subcommandOf(args),
      command: shown,
      args: args,
      host: host,
      startedAt: DateTime.now(),
    );
    final recent = state.length > 5 ? state.sublist(state.length - 5) : state;
    state = [...recent, job];
    _retry.removeWhere((job, _) => !state.any((j) => j.id == job));

    final out = StringBuffer(), err = StringBuffer();
    ExecResult result;
    try {
      validateDokkuArgs(args);
      final stream = await ref.read(sshServiceProvider).dokkuStream(
        host,
        args,
        stdin: input,
        onData: (chunk, isStderr) {
          (isStderr ? err : out).write(chunk);
          _update(id, (j) => j.copyWith(output: [...j.output, JobChunk(chunk, isStderr)]));
        },
      );
      _streams[id] = stream;
      final exit = await stream.done.timeout(timeout, onTimeout: () {
        stream.kill();
        return StreamExit(null, 'TIMEOUT', timeout.inMilliseconds);
      });
      result = ExecResult(
        code: exit.code ?? (exit.signal == null ? null : -1),
        signal: exit.signal,
        stdout: '$out',
        stderr: exit.signal == 'TIMEOUT' ? '$err\nTimed out after ${timeout.inMinutes} minutes.' : '$err',
        durationMs: exit.durationMs,
        command: shown,
      );
    } on Object catch (e) {
      final message = '$e';
      _update(id, (j) => j.copyWith(output: [...j.output, JobChunk(message, true)]));
      result = ExecResult(code: -1, stdout: '$out', stderr: '$err$message', durationMs: 0, command: shown);
    } finally {
      _streams.remove(id);
    }

    if (!ref.mounted) return result;
    // Asking for a command this Dokku does not have changed nothing, and the
    // caller goes on to run the one it does have.
    if (probe && !result.ok && notSupported(result.output)) {
      dismiss(id);
      return result;
    }
    if (!result.ok) _retry[id] = (input: input, timeout: timeout);
    _update(
      id,
      (j) => j.copyWith(status: result.ok ? JobStatus.ok : JobStatus.failed, code: result.code, durationMs: result.durationMs),
    );

    if (!isReadOnly(args)) {
      await ref.read(activityLogProvider).add(
            hostId: host.id,
            command: shown,
            code: result.code,
            durationMs: result.durationMs,
            stderr: stripAnsi(result.stderr.isEmpty ? result.stdout : result.stderr),
          );
    }
    if (!ref.mounted) return result;
    ref.read(generationProvider(host.id).notifier).bump();

    if (result.ok) {
      Timer(const Duration(seconds: 6), () {
        if (ref.mounted && state.any((j) => j.id == id && j.status == JobStatus.ok)) dismiss(id);
      });
    } else if (!quiet && result.signal != 'KILLED') {
      final failed = state.where((j) => j.id == id).firstOrNull;
      if (failed != null) ref.read(failedJobProvider.notifier).show(failed);
    }
    return result;
  }
}

final jobsProvider = NotifierProvider<JobsNotifier, List<Job>>(JobsNotifier.new);

/// The job whose failure is currently being explained to the user.
class FailedJob extends Notifier<Job?> {
  @override
  Job? build() => null;

  void show(Job job) => state = job;
  void clear() => state = null;
}

final failedJobProvider = NotifierProvider<FailedJob, Job?>(FailedJob.new);

/// Plain-language advice for a failed command, chosen from its output.
String remediation(String out) {
  bool has(String pattern) => RegExp(pattern, caseSensitive: false).hasMatch(out);
  if (has(r'could not resolve host|temporary failure in name resolution|network is unreachable')) {
    return 'The server could not reach the internet (DNS or network failure). Check its resolver and outbound firewall, then retry.';
  }
  if (has(r'must be run as root|requires root|sudo: a password is required|a terminal is required|docker\.sock.*permission denied')) {
    return 'This command needs root. Edit the connection to sign in as root, or as a user with passwordless sudo and "Run dokku with sudo" turned on.';
  }
  // What apps:unlock says when the app was not locked.
  if (has(r'unable to remove deploy lock|deploy lock does not exist')) {
    return 'This app has no deploy lock, so there was nothing to clear. Nothing was changed.';
  }
  if (has(r'deploy lock|is locked|currently being deployed')) {
    return 'A deploy lock is held. Unlock deploys in the app\'s Settings tab, or wait for the running deploy to finish.';
  }
  if (has(r'is not a dokku command')) {
    return 'This Dokku version does not have that command. Upgrade Dokku from the Server page, or install the plugin that provides it.';
  }
  if (has(r'not deployed')) {
    return 'The app has not been deployed yet. Push code, sync from a repository, or deploy an image first.';
  }
  if (has(r'pull access denied|unauthorized|no basic auth credentials')) {
    return 'The image registry rejected the request. Log in to the registry on the Server page.';
  }
  if (has(r'timed? ?out|TIMEOUT')) {
    return 'The command timed out. The host may be busy or the connection dropped; retry once the connection indicator is green.';
  }
  if (has(r'build failed|failure during|failed to solve')) {
    return 'The build failed. Read the output above; crashed deploy containers are also listed under Logs, in the failed view.';
  }
  if (has(r'still linked|is linked')) return 'Unlink the service from every app before destroying it.';
  if (has(r'does not exist|not found')) {
    return 'That resource does not exist (it may have been removed elsewhere). Refresh and try again.';
  }
  return 'Dokku returned a non-zero exit status. The full output is above.';
}
