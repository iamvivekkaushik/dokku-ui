import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/command.dart';
import '../../core/parse.dart';
import '../../data/models.dart';
import '../../data/ssh_service.dart';
import '../../state/core.dart';
import '../widgets/kit.dart';

/// What an interactive terminal should run: a login shell, or a Dokku command
/// such as `enter` or `run` that needs a real terminal.
class TerminalSpec {
  const TerminalSpec.shell() : args = null;
  const TerminalSpec.dokku(List<String> this.args);
  final List<String>? args;

  bool get isShell => args == null;
}

const _theme = TerminalTheme(
  cursor: C.fg,
  selection: Color(0x2EFFFFFF),
  foreground: C.soft,
  background: C.term,
  black: C.bg,
  white: C.soft,
  red: C.bad,
  green: C.ok,
  yellow: C.warn,
  blue: C.info,
  magenta: C.violet,
  cyan: Color(0xFF22D3EE),
  brightBlack: C.dim,
  brightRed: Color(0xFFF87171),
  brightGreen: Color(0xFF4ADE80),
  brightYellow: Color(0xFFFBBF24),
  brightBlue: Color(0xFF60A5FA),
  brightMagenta: Color(0xFFC4B5FD),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: C.fg,
  searchHitBackground: Color(0x66F59E0B),
  searchHitBackgroundCurrent: C.warn,
  searchHitForeground: C.bg,
);

Future<void> openTerminal(BuildContext context, Host host, TerminalSpec spec, {String? title}) {
  final label = title ?? (spec.isShell ? 'SSH terminal · ${host.name}' : displayCommand(spec.args!));
  // A phone has no room for a floating window: use the whole screen.
  if (Bp.isCompact(context)) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: C.term,
        body: SafeArea(child: TerminalPane(host: host, spec: spec, title: label)),
      ),
    ));
  }
  return showAppDialog<void>(
    context,
    dismissible: false,
    (_) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 620),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: C.term,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.lineStrong),
            boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 20))],
          ),
          child: TerminalPane(host: host, spec: spec, title: label),
        ),
      ),
    ),
  );
}

enum _State { connecting, live, exited }

class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane({super.key, required this.host, required this.spec, required this.title});
  final Host host;
  final TerminalSpec spec;
  final String title;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
  final _terminal = Terminal(maxLines: 5000);
  final _focus = FocusNode();
  RemoteStream? _stream;
  var _state = _State.connecting;
  int? _exitCode;
  var _closed = false;
  var _retried = false;
  // The terminal reports its size once laid out; the session starts after that.
  final _sized = Completer<void>();

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) => _stream?.write(data);
    _terminal.onResize = (cols, rows, _, _) {
      if (!_sized.isCompleted && cols > 1 && rows > 1) _sized.complete();
      _stream?.resize(cols, rows);
    };
    unawaited(_start());
  }

  Future<void> _start() async {
    await _sized.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (_closed) return;
    await _run(widget.spec.args);
  }

  /// Runs [args], or a login shell when null, until it exits.
  Future<void> _run(List<String>? args) async {
    final host = widget.host;
    final ssh = ref.read(sshServiceProvider);
    final pty = Pty(cols: _terminal.viewWidth, rows: _terminal.viewHeight);
    // The end of the output, to see how a command failed.
    final tail = StringBuffer();
    void onData(String chunk, bool _) {
      if (_closed) return;
      _terminal.write(chunk);
      tail.write(chunk);
      if (tail.length > 4096) {
        final keep = '$tail'.substring(tail.length - 2048);
        tail
          ..clear()
          ..write(keep);
      }
    }

    try {
      final RemoteStream stream;
      if (args == null) {
        if (!host.hasShell) throw StateError('An interactive shell needs a shell user; the dokku user can only run dokku commands.');
        stream = await ssh.stream(host, '', shell: true, pty: pty, onData: onData);
      } else {
        stream = await ssh.dokkuStream(host, args, pty: pty, onData: onData);
      }
      if (_closed) {
        stream.kill();
        return;
      }
      _stream = stream;
      setState(() => _state = _State.live);
      final exit = await stream.done;
      if (_closed) return;
      if (args != null && exit.code != 0 && _wantsSh(args, '$tail')) {
        // Dokku starts /bin/bash unless DOKKU_APP_SHELL says otherwise, and
        // Alpine images only have sh.
        _retried = true;
        _terminal.write('\r\n\x1b[90mNo /bin/bash in this image; opening sh instead. '
            'Set DOKKU_APP_SHELL=/bin/sh on the app to make that the default.\x1b[0m\r\n');
        return _run([...args, 'sh']);
      }
      _terminal.write('\r\n\x1b[90m[process exited${exit.code != null ? ' with code ${exit.code}' : ''}]\x1b[0m\r\n');
      setState(() {
        _state = _State.exited;
        _exitCode = exit.code;
      });
      ref.read(generationProvider(host.id).notifier).bump();
    } on Object catch (e) {
      if (_closed) return;
      _terminal.write('\x1b[31m$e\x1b[0m\r\n');
      setState(() => _state = _State.exited);
    }
  }

  /// Whether `enter` failed only because the image lacks the shell Dokku
  /// starts by default, rather than a program the user asked for.
  bool _wantsSh(List<String> args, String output) {
    if (_retried || subcommandOf(args) != 'enter') return false;
    final program = missingProgram.firstMatch(output)?.group(1);
    return program != null && !args.contains(program);
  }

  @override
  void dispose() {
    _closed = true;
    _stream?.kill();
    _focus.dispose();
    super.dispose();
  }

  void _send(String data) {
    _stream?.write(data);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final compact = Bp.isCompact(context);
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: C.card, border: Border(bottom: BorderSide(color: C.line))),
        child: Row(children: [
          const Icon(LucideIcons.squareTerminal, size: 14, color: C.fg),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12.5, weight: FontWeight.w600))),
          if (!compact) ...[Text(widget.host.address, style: T.meta), const SizedBox(width: 10)],
          switch (_state) {
            _State.connecting => const Pill('connecting', tone: Tone.info, mono: true),
            _State.live => const Pill('live', tone: Tone.ok, mono: true, pulse: true),
            _State.exited => Pill('exited${_exitCode != null ? ' $_exitCode' : ''}',
                tone: _exitCode == 0 ? Tone.mute : Tone.bad, mono: true),
          },
          const SizedBox(width: 6),
          IconBtn(LucideIcons.x, tooltip: 'Close terminal', onPressed: () => Navigator.of(context).maybePop()),
        ]),
      ),
      Expanded(
        child: TerminalView(
          _terminal,
          theme: _theme,
          focusNode: _focus,
          autofocus: true,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          textStyle: TerminalStyle(fontFamily: fontMono, fontSize: compact ? 12 : 12.5, height: 1.3),
          keyboardType: TextInputType.visiblePassword,
          deleteDetection: true,
        ),
      ),
      // Phone keyboards have no Ctrl, Tab or arrow keys.
      if (compact && _state == _State.live)
        Container(
          decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.line))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (label, data) in const [
                ('esc', '\x1b'), ('tab', '\t'), ('ctrl-c', '\x03'), ('ctrl-d', '\x04'), ('↑', '\x1b[A'), ('↓', '\x1b[B'),
                ('←', '\x1b[D'), ('→', '\x1b[C'), ('|', '|'), ('/', '/'), ('-', '-'), ('~', '~'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Btn(label, mono: true, onPressed: () => _send(data)),
                ),
            ]),
          ),
        ),
    ]);
  }
}

class _Line {
  const _Line(this.text, this.color);
  final String text;
  final Color color;
}

/// Line-based Dokku console: each line typed is run as a Dokku command.
class DokkuConsole extends ConsumerStatefulWidget {
  const DokkuConsole({super.key, required this.host, this.app});
  final Host host;
  final String? app;

  @override
  ConsumerState<DokkuConsole> createState() => _DokkuConsoleState();
}

class _DokkuConsoleState extends ConsumerState<DokkuConsole> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _history = <String>[];
  late final _lines = <_Line>[
    _Line('Type a dokku command, e.g. ps:report${widget.app == null ? '' : ' ${widget.app}'}. '
        '"enter" and "run" open an interactive terminal.', C.dim),
  ];
  var _historyIndex = -1;
  RemoteStream? _running;

  String get _prompt => '${widget.host.username}@${widget.host.name}:~\$';

  @override
  void dispose() {
    _running?.kill();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _push(String text, Color color) {
    if (!mounted) return;
    setState(() {
      _lines.add(_Line(text, color));
      if (_lines.length > 2000) _lines.removeRange(0, _lines.length - 2000);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _submit() async {
    final line = _input.text.trim();
    if (line.isEmpty || _running != null) return;
    _history
      ..remove(line)
      ..add(line);
    _historyIndex = -1;
    _input.clear();
    _focus.requestFocus();
    _push('$_prompt $line', C.fg);
    if (line == 'clear') {
      setState(_lines.clear);
      return;
    }

    List<String> args;
    try {
      args = splitArgs(line);
      if (args.firstOrNull == 'dokku') args = args.sublist(1);
      validateDokkuArgs(args);
    } on Object catch (e) {
      _push('$e', C.bad);
      return;
    }
    final sub = subcommandOf(args);
    // run:detached is a command of its own and returns at once.
    final interactive = sub == 'enter' || sub == 'shell' || (sub == 'run' && !args.contains('--no-tty'));
    if (interactive) {
      _push('Opening interactive terminal…', C.dim);
      await openTerminal(context, widget.host, TerminalSpec.dokku(args));
      return;
    }

    final pending = StringBuffer();
    void flush(String chunk, bool isStderr) {
      pending.write(stripAnsi(chunk));
      final parts = '$pending'.split('\n');
      pending
        ..clear()
        ..write(parts.removeLast());
      for (final p in parts) {
        _push(p, isStderr ? C.bad : C.soft);
      }
    }

    try {
      final stream = await ref.read(sshServiceProvider).dokkuStream(widget.host, args, onData: flush);
      if (!mounted) {
        stream.kill();
        return;
      }
      setState(() => _running = stream);
      final exit = await stream.done;
      if (pending.isNotEmpty) _push('$pending', C.soft);
      if (exit.code != 0) _push(exit.signal == 'KILLED' ? '^C' : 'exit ${exit.code ?? '?'}', C.bad);
    } on Object catch (e) {
      _push('$e', C.bad);
    } finally {
      if (mounted) {
        setState(() => _running = null);
        ref.read(generationProvider(widget.host.id).notifier).bump();
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.arrowUp && _history.isNotEmpty) {
      _historyIndex = _historyIndex < 0 ? _history.length - 1 : (_historyIndex - 1).clamp(0, _history.length - 1);
      _setInput(_history[_historyIndex]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && _historyIndex >= 0) {
      _historyIndex++;
      if (_historyIndex >= _history.length) {
        _historyIndex = -1;
        _setInput('');
      } else {
        _setInput(_history[_historyIndex]);
      }
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC && _running != null) {
      _running!.kill();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyL) {
      setState(_lines.clear);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _setInput(String text) {
    _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  @override
  Widget build(BuildContext context) => Panel(
        color: C.term,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: C.card, border: Border(bottom: BorderSide(color: C.line))),
            child: Row(children: [
              const Icon(LucideIcons.squareTerminal, size: 13, color: C.fg),
              const SizedBox(width: 8),
              Text('Console', style: T.sans(12.5, weight: FontWeight.w600)),
              const Spacer(),
              Flexible(
                child: Text('${widget.host.username}@${widget.host.name}${widget.app == null ? '' : ' · ${widget.app}'}',
                    style: T.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focus.requestFocus,
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _lines.length,
                  itemBuilder: (_, i) => Text(_lines[i].text.isEmpty ? ' ' : _lines[i].text,
                      style: T.mono(11.5, color: _lines[i].color, height: 1.7)),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.line))),
            child: Row(children: [
              Text(r'$', style: T.mono(11.5, color: C.ok)),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    onSubmitted: (_) => _submit(),
                    autocorrect: false,
                    enableSuggestions: false,
                    style: T.mono(11.5),
                    cursorWidth: 1.2,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8 + touchPad(context) / 2),
                      hintText: _running != null ? 'running…' : 'ps:report ${widget.app ?? '<app>'}',
                      hintStyle: T.mono(11.5, color: C.dim),
                    ),
                  ),
                ),
              ),
              if (_running != null)
                Btn('Stop', size: BtnSize.xs, onPressed: _running!.kill)
              else if (Bp.isCompact(context))
                IconBtn(LucideIcons.cornerDownLeft, tooltip: 'Run', onPressed: _submit)
              else
                const Kbd('↵'),
            ]),
          ),
        ]),
      );
}
