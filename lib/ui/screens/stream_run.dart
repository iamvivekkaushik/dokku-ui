/// A long-running script (install, upgrade) and its output.
///
/// The run lives in a provider rather than in the widget that started it, so
/// leaving the screen and coming back shows the same run instead of
/// cancelling it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/parse.dart';
import '../../data/models.dart';
import '../../data/ssh_service.dart';
import '../../state/core.dart';
import '../widgets/kit.dart';

enum RunStatus { idle, running, done, failed }

class RunState {
  const RunState({this.status = RunStatus.idle, this.lines = const [], this.exitCode});
  final RunStatus status;
  final List<String> lines;
  final int? exitCode;

  bool get running => status == RunStatus.running;

  RunState copyWith({RunStatus? status, List<String>? lines, int? exitCode}) =>
      RunState(status: status ?? this.status, lines: lines ?? this.lines, exitCode: exitCode ?? this.exitCode);
}

const _maxLines = 5000;
final _errorPrefix = RegExp(r'^(Exception|Bad state|StateError)(\([^)]*\))?:\s*');

class StreamRun extends Notifier<RunState> {
  StreamRun(this.id);

  /// What is being run and where, e.g. `install:<host id>`.
  final String id;
  RemoteStream? _stream;
  var _cancelled = false;

  @override
  RunState build() => const RunState();

  /// Runs [script] with bash on [host]. Does nothing while a run is in progress.
  Future<void> start(Host host, String script) async {
    if (state.running) return;
    _cancelled = false;
    state = const RunState(status: RunStatus.running);

    // Output and errors arrive separately, so each keeps its own unfinished
    // line: half a line of one must not run into the other.
    final pending = {false: '', true: ''};
    void add(List<String> lines) {
      if (!ref.mounted || lines.isEmpty) return;
      final all = [...state.lines, ...lines];
      state = state.copyWith(lines: all.length > _maxLines ? all.sublist(all.length - _maxLines) : all);
    }

    void end(RunStatus status, {int? code, String? note}) {
      add([for (final rest in pending.values) if (rest.isNotEmpty) rest, if (note != null) ' !     $note']);
      pending.updateAll((_, _) => '');
      if (!ref.mounted) return;
      state = state.copyWith(status: status, exitCode: code);
      // Whatever the script got through, what is on screen is now stale.
      ref.read(generationProvider(host.id).notifier).bump();
    }

    if (!host.hasShell) {
      end(RunStatus.failed, note: 'This needs root or a user with passwordless sudo.');
      return;
    }
    try {
      final stream = await ref.read(sshServiceProvider).stream(
        host,
        'bash -s',
        stdin: utf8.encode(script),
        onData: (chunk, isStderr) {
          final parts = (pending[isStderr]! + stripAnsi(chunk)).split('\n');
          pending[isStderr] = parts.removeLast();
          add(parts);
        },
      );
      _stream = stream;
      // Cancel can be pressed while the channel is still being opened.
      if (_cancelled) stream.kill();
      final exit = await stream.done;
      end(
        exit.code == 0 ? RunStatus.done : RunStatus.failed,
        code: exit.code,
        note: exit.signal == 'KILLED' ? 'Cancelled before it finished. Steps that already ran are not undone.' : null,
      );
    } on Object catch (e) {
      end(RunStatus.failed, note: '$e'.replaceFirst(_errorPrefix, ''));
    } finally {
      _stream = null;
    }
  }

  /// Stops waiting for the run. Steps that already ran are not undone.
  void kill() {
    if (!state.running) return;
    _cancelled = true;
    _stream?.kill();
  }

  /// Forgets a finished run.
  void reset() {
    if (!state.running) state = const RunState();
  }
}

final streamRunProvider = NotifierProvider.family<StreamRun, RunState, String>(StreamRun.new);

final _badLine = RegExp(r'^\s*!\s|\b(error|failed|fatal)\b', caseSensitive: false);
final _warnLine = RegExp(r'\b(warning|warn)\b|^-----> Note', caseSensitive: false);

Color lineColor(String line) {
  if (line.startsWith('=====>')) return Tone.ok.color;
  if (_badLine.hasMatch(line)) return Tone.bad.color;
  if (_warnLine.hasMatch(line)) return Tone.warn.color;
  if (line.startsWith('----->')) return C.soft;
  return C.muted;
}

/// The output of a run. Needs a bounded height from its parent.
///
/// Follows new lines as they arrive unless the user has scrolled up to read.
class StreamOutput extends StatefulWidget {
  const StreamOutput({super.key, required this.lines, this.idle});

  /// A new list whenever lines were added, as [RunState.lines] is.
  final List<String> lines;

  /// Shown while there are no lines.
  final InlineSpan? idle;

  @override
  State<StreamOutput> createState() => _StreamOutputState();
}

class _StreamOutputState extends State<StreamOutput> {
  final _scroll = ScrollController();
  var _stick = true;

  @override
  void initState() {
    super.initState();
    _toBottom();
  }

  @override
  void didUpdateWidget(StreamOutput old) {
    super.didUpdateWidget(old);
    if (!identical(widget.lines, old.lines)) _toBottom();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom([int passes = 3]) {
    if (!_stick) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stick || !_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      _scroll.jumpTo(position.maxScrollExtent);
      // Rows are measured as they come into view, so the end can move once.
      if (passes > 1) _toBottom(passes - 1);
    });
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) _stick = n.metrics.maxScrollExtent - n.metrics.pixels < 40;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    if (lines.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text.rich(widget.idle ?? const TextSpan(), style: T.mono(11.5, color: C.dim, height: 1.7)),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          itemCount: lines.length,
          itemBuilder: (_, i) =>
              Text(lines[i].isEmpty ? ' ' : lines[i], style: T.mono(11.5, color: lineColor(lines[i]), height: 1.7)),
        ),
      ),
    );
  }
}
