import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/command.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../data/platform.dart';
import '../../../data/ssh_service.dart';
import '../../../state/core.dart';
import '../../../state/queries.dart';
import '../../shell/terminal.dart';
import '../../widgets/kit.dart';

enum TailState { idle, live, ended, error }

typedef LineParser = LogLine? Function(String line);

/// An event in the shape of a log line: the trigger takes the place of the process.
LogLine eventLogLine(EventLine e) => LogLine(
      ts: e.ts,
      proc: e.kind,
      msg: '${e.text}${e.user.isEmpty ? '' : '  by ${e.user}'}',
      level: RegExp('fail|error', caseSensitive: false).hasMatch(e.kind) ? LogLevel.error : LogLevel.info,
    );

String lineCount(int n) => '$n ${n == 1 ? 'line' : 'lines'}';

String _reason(Object e) => '$e'.replaceFirst(RegExp(r'^(Bad state|Exception|\w+Exception|\w+Error):\s*'), '');

/// Follows the output of a Dokku command line by line, reconnecting when the
/// connection drops.
class LogTail extends ChangeNotifier {
  LogTail(this._ssh);
  final SshService _ssh;

  static const maxLines = 3000;
  static const _flushEvery = Duration(milliseconds: 80);
  static const _retryAfter = Duration(seconds: 4);

  List<LogLine> _lines = const [];
  var _pending = <LogLine>[];
  var _state = TailState.idle;
  var _error = '';
  String? _following;
  RemoteStream? _stream;
  Timer? _flush;
  Timer? _retry;
  var _disposed = false;

  // Bumped whenever the stream is replaced, so output from an old one can be told apart.
  var _run = 0;

  List<LogLine> get lines => _lines;
  TailState get state => _state;
  String get error => _error;

  /// Follows [args] on [host], or nothing when [args] is null. Does nothing if
  /// that is already being followed, so it can be called on every build.
  void follow(Host host, List<String>? args, LineParser parse) {
    final next = args == null ? null : '${host.id}\u0001${args.join('\u0001')}';
    if (next == _following) return;
    _following = next;
    _stop();
    _lines = const [];
    _state = TailState.idle;
    _error = '';
    if (args != null) unawaited(_open(host, args, parse));
    // Listeners may be in the middle of building.
    scheduleMicrotask(_notify);
  }

  Future<void> _open(Host host, List<String> args, LineParser parse) async {
    final run = ++_run;
    bool stopped() => run != _run;
    final partial = [StringBuffer(), StringBuffer()];

    void take(String chunk, bool isStderr) {
      // A stopped terminal still echoes ^C.
      if (stopped()) return;
      final buffer = partial[isStderr ? 1 : 0]..write(chunk);
      final parts = '$buffer'.split('\n');
      buffer
        ..clear()
        ..write(parts.removeLast());
      for (final p in parts) {
        final line = parse(p);
        if (line != null) _pending.add(line);
      }
      // A busy log would otherwise rebuild the list for every line.
      _flush ??= Timer(_flushEvery, _append);
    }

    void failed(String message) {
      _stream = null;
      _error = message;
      _state = TailState.error;
      _notify();
      // A reconnect keeps what is already on screen.
      _retry = Timer(_retryAfter, () => unawaited(_open(host, args, parse)));
    }

    try {
      final stream = await _ssh.dokkuStream(host, args, onData: take);
      if (stopped()) {
        stream.kill();
        return;
      }
      _stream = stream;
      _state = TailState.live;
      _error = '';
      _notify();
      final exit = await stream.done;
      if (stopped()) return;
      for (final (i, b) in partial.indexed) {
        if (b.isNotEmpty) take('\n', i == 1);
      }
      // No exit status and no signal: the connection went away underneath it.
      if (exit.code == null && exit.signal == null) {
        failed('The connection to the server was lost.');
        return;
      }
      _stream = null;
      _state = TailState.ended;
      _notify();
    } on Object catch (e) {
      if (!stopped()) failed(_reason(e));
    }
  }

  void _append() {
    _flush = null;
    if (_pending.isEmpty) return;
    final all = [..._lines, ..._pending];
    _pending = [];
    _lines = all.length > maxLines ? all.sublist(all.length - maxLines) : all;
    _notify();
  }

  void _stop() {
    _run++;
    _stream?.kill();
    _stream = null;
    _flush?.cancel();
    _flush = null;
    _retry?.cancel();
    _retry = null;
    _pending = [];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}

enum _Mode { live, failed, events }

const _counts = [100, 200, 500, 1000, 5000];
const _procColors = [C.info, C.violet, C.warn, C.ok, Color(0xFFEC4899), Color(0xFF14B8A6)];

Color _levelColor(LogLevel level) => switch (level) {
      LogLevel.info => C.soft,
      LogLevel.warn => Tone.warn.color,
      LogLevel.error => Tone.bad.color,
    };

class LogsTab extends ConsumerStatefulWidget {
  const LogsTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  ConsumerState<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends ConsumerState<LogsTab> {
  late final _tail = LogTail(ref.read(sshServiceProvider));
  final _search = TextEditingController();
  final _scroll = ScrollController();
  // Keeps the console's history when the layout switches between stacked and side by side.
  final _console = GlobalKey();
  var _mode = _Mode.live;
  var _filter = 'all';
  var _count = 200;
  var _auto = true;

  @override
  void initState() {
    super.initState();
    _tail.addListener(_stick);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _tail.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _args => switch (_mode) {
        _Mode.live => ['logs', widget.app, '-t', '-n', '$_count', if (_filter != 'all') ...['-p', _filter]],
        _Mode.failed => ['logs:failed', widget.app],
        _Mode.events => ['events', '-t'],
      };

  /// Only the events that changed something on this app.
  LogLine? _parseEvent(String line) {
    final e = parseEvent(line);
    if (e == null || !isKeyEvent(e.kind) || !words(e.text).contains(widget.app)) return null;
    return eventLogLine(e);
  }

  void _onScroll() {
    final p = _scroll.position;
    final atEnd = p.maxScrollExtent - p.pixels < 40;
    if (atEnd != _auto) setState(() => _auto = atEnd);
  }

  /// Keeps the newest line in view while autoscroll is on.
  void _stick([int pass = 0]) {
    if (!_auto) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_auto || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      // The height of rows not yet laid out is an estimate, so look again once they are.
      if (pass < 2) _stick(pass + 1);
    });
  }

  Future<void> _download(List<LogLine> shown) async {
    final text = shown.map((l) => '${l.ts} ${l.proc} ${l.msg}').join('\n');
    try {
      await saveTextFile('${widget.app}-${_mode.name}.log', text);
    } on Object catch (e) {
      if (!mounted) return;
      await showAppDialog<void>(
        context,
        (context) => AppDialog(
          title: 'Could not save the log',
          width: 420,
          actions: [Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop())],
          children: [Text('${_reason(e)}\nTry again, or copy the lines from the log instead.', style: T.small)],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final types = ref.dokku(host, ['ps:scale', app], (r) => parseScale(r.stdout).keys.toList()).data ?? const <String>[];
    final args = _args;
    _tail.follow(host, args, _mode == _Mode.events ? _parseEvent : parseLogLine);

    Color procColor(String proc) {
      final i = types.indexOf(proc.split('.').first);
      if (i >= 0) return _procColors[i % _procColors.length];
      if (proc == 'router' || proc == 'events') return C.muted;
      return _procColors[proc.codeUnits.fold(0, (a, c) => a + c) % _procColors.length];
    }

    final stream = ListenableBuilder(
      listenable: _tail,
      builder: (context, _) {
        final q = _search.text.trim().toLowerCase();
        final lines = _tail.lines;
        final shown = q.isEmpty
            ? lines
            : [for (final l in lines) if (l.msg.toLowerCase().contains(q) || l.proc.toLowerCase().contains(q)) l];
        return Panel(
          color: C.term,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _toolbar(types, shown),
            Expanded(child: _list(shown, procColor)),
            CmdFooter(
              '\$ ${displayCommand(args)}',
              action: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_tail.state == TailState.live) ...[
                  const PulseDot(color: C.ok, size: 5),
                  const SizedBox(width: 6),
                  Text('live', style: T.mono(10.5, color: C.ok)),
                  const SizedBox(width: 8),
                ],
                Text(lineCount(shown.length), style: T.meta),
              ]),
            ),
          ]),
        );
      },
    );
    final console = DokkuConsole(key: _console, host: host, app: app);

    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < Bp.twoCol) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 520, child: stream),
          const SizedBox(height: 16),
          SizedBox(height: 420, child: console),
        ]);
      }
      return SizedBox(
        height: 600,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 3, child: stream),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: console),
        ]),
      );
    });
  }

  Widget _toolbar(List<String> types, List<LogLine> shown) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: C.card, border: Border(bottom: BorderSide(color: C.line))),
        child: LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_mode == _Mode.live)
                Seg<String>(
                  small: true,
                  mono: true,
                  value: _filter,
                  options: ['all', ...types],
                  onChanged: (f) => setState(() => _filter = f),
                ),
              Seg<_Mode>(
                small: true,
                value: _mode,
                options: _Mode.values,
                labels: (m) => m.name,
                onChanged: (m) => setState(() => _mode = m),
              ),
              // On a phone the search field gets a row to itself.
              SizedBox(
                width: box.maxWidth < 520 ? box.maxWidth : 200,
                child: AppInput(controller: _search, mono: false, hint: 'Search logs', onChanged: (_) => setState(() {})),
              ),
              if (_mode == _Mode.live)
                SizedBox(
                  width: 96,
                  child: AppSelect<int>(
                    value: _count,
                    options: _counts,
                    labels: (n) => '-n $n',
                    onChanged: (n) => setState(() => _count = n),
                  ),
                ),
              Btn(
                'Autoscroll',
                icon: LucideIcons.arrowDownToLine,
                selected: _auto,
                tooltip: _auto ? 'Following new lines' : 'Paused. Scroll to the end to follow again.',
                onPressed: () {
                  setState(() => _auto = !_auto);
                  _stick();
                },
              ),
              IconBtn(
                LucideIcons.download,
                tooltip: 'Download shown lines',
                onPressed: shown.isEmpty ? null : () => _download(shown),
              ),
            ],
          ),
        ),
      );

  Widget _list(List<LogLine> shown, Color Function(String) procColor) {
    final failed = _tail.state == TailState.error;
    final reconnecting = '${_tail.error}${_tail.error.endsWith('.') ? '' : '.'} Reconnecting…';
    if (shown.isEmpty) {
      final text = failed
          ? reconnecting
          : _tail.lines.isNotEmpty
              ? 'No lines match.'
              : switch (_tail.state) {
                  TailState.live => 'Waiting for output…',
                  TailState.ended => 'No output.',
                  _ => 'Connecting…',
                };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(text, textAlign: TextAlign.center, style: T.mono(11.5, color: failed ? C.bad : C.dim, height: 1.7)),
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 460;
      return SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          itemCount: shown.length + (failed ? 1 : 0),
          itemBuilder: (_, i) => i == shown.length
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(reconnecting, textAlign: TextAlign.center, style: T.mono(11.5, color: C.bad, height: 1.7)),
                )
              : _LogRow(shown[i], procColor: procColor, showTime: !narrow),
        ),
      );
    });
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow(this.line, {required this.procColor, required this.showTime});
  final LogLine line;
  final Color Function(String) procColor;
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final message = Text(line.msg.isEmpty ? ' ' : line.msg, style: T.mono(11.5, color: _levelColor(line.level), height: 1.7));
    // Output that is not a log line (headings, warnings) uses the full width.
    if (line.ts.isEmpty && line.proc.isEmpty) return message;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (showTime) ...[
        SizedBox(width: 70, child: Text(line.ts, maxLines: 1, style: T.mono(11.5, color: C.dim, height: 1.7))),
        const SizedBox(width: 12),
      ],
      SizedBox(
        width: showTime ? 90 : 64,
        child: Text(line.proc,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5, color: procColor(line.proc), height: 1.7)),
      ),
      const SizedBox(width: 12),
      Expanded(child: message),
    ]);
  }
}
