/// SSH connections to saved hosts.
///
/// Each host gets two connections: one for the short commands that render the
/// UI and one for long-lived streams (log tails, terminals, deploys), so a
/// screen full of open streams can never starve the queries.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/command.dart';
import 'models.dart';

const _maxChannels = 8;
const _connectTimeout = Duration(seconds: 15);

enum Lane { command, stream }

/// Terminal size for commands that need one.
class Pty {
  const Pty({this.cols = 80, this.rows = 24});
  final int cols;
  final int rows;

  SSHPtyConfig get _config => SSHPtyConfig(width: cols, height: rows);
}

class HostKeyMismatch implements Exception {
  HostKeyMismatch(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'Host key mismatch: expected $expected, server presented $actual. The server may have been reinstalled, or the connection is being intercepted.';
}

class ConnectionFailed implements Exception {
  ConnectionFailed(this.message, {this.step = 0});
  final String message;

  /// Which handshake step failed: 0 connect, 1 host key, 2 authentication.
  final int step;
  @override
  String toString() => message;
}

class _Semaphore {
  _Semaphore(this._free);
  int _free;
  final _queue = <Completer<void>>[];

  Future<void Function()> acquire() async {
    if (_free > 0) {
      _free--;
    } else {
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      } else {
        _free++;
      }
    };
  }
}

class _Connection {
  SSHClient? client;
  Future<SSHClient>? connecting;
  final semaphore = _Semaphore(_maxChannels);
}

class OpenedClient {
  OpenedClient(this.client, this.hostKey, this.hostKeyType);
  final SSHClient client;
  final String hostKey;
  final String hostKeyType;
}

/// A running remote command whose output arrives as it is produced.
abstract class RemoteStream {
  /// Completes when the command ends or is killed.
  Future<StreamExit> get done;

  void write(String data);
  void writeBytes(List<int> data);
  void resize(int cols, int rows);

  /// Stops the command. Safe to call more than once.
  void kill();
}

class _SshStream implements RemoteStream {
  _SshStream(this._session, this._pty, this._finish, this.done);
  final SSHSession _session;
  final bool _pty;
  final void Function(String? signal) _finish;

  @override
  final Future<StreamExit> done;
  bool _killed = false;

  @override
  void write(String data) => writeBytes(utf8.encode(data));

  @override
  void writeBytes(List<int> data) {
    if (_killed) return;
    try {
      _session.write(data is Uint8List ? data : Uint8List.fromList(data));
    } on Object {
      // the channel is already closed
    }
  }

  @override
  void resize(int cols, int rows) {
    if (_killed || cols < 1 || rows < 1) return;
    try {
      _session.resizeTerminal(cols, rows);
    } on Object {
      // the channel is already closed
    }
  }

  @override
  void kill() {
    if (_killed) return;
    // With a PTY, Ctrl-C reaches the foreground process and closing the
    // channel then hangs up the session. Without one, sshd keeps the process
    // until it next writes, so we stop waiting for it right away.
    if (_pty) writeBytes(const [3]);
    _killed = true;
    try {
      _session.kill(SSHSignal.INT);
    } on Object {
      // not supported by every server
    }
    Timer(Duration(milliseconds: _pty ? 150 : 0), () {
      try {
        _session.close();
      } on Object {
        // already closed
      }
      _finish('KILLED');
    });
  }
}

class StreamExit {
  const StreamExit(this.code, this.signal, this.durationMs);
  final int? code;
  final String? signal;
  final int durationMs;
}

typedef SecretsLoader = Future<HostSecrets> Function(Host host);
typedef KeyFileReader = Future<String> Function(String path);
typedef HostKeyPinner = Future<void> Function(Host host, String type, String fingerprint);

class SshService {
  SshService({required this.loadSecrets, this.readKeyFile, this.pinHostKey, this.onStatus});

  final SecretsLoader loadSecrets;

  /// Reads a private key file from this device. Null where files are unavailable.
  final KeyFileReader? readKeyFile;

  /// Called the first time a host key is seen, so it can be remembered.
  final HostKeyPinner? pinHostKey;
  final void Function(String hostId, ConnStatus status)? onStatus;

  final _connections = <String, _Connection>{};
  final _status = <String, ConnStatus>{};

  _Connection _conn(Host h, Lane lane) => _connections.putIfAbsent('${h.id}:${lane.name}', _Connection.new);

  ConnStatus status(String hostId) => _status[hostId] ?? ConnStatus.idle;

  void _setStatus(String hostId, ConnStatus s) {
    _status[hostId] = s;
    onStatus?.call(hostId, s);
  }

  /// Closes every connection to [hostId].
  void drop(String hostId) {
    for (final lane in Lane.values) {
      final c = _connections.remove('$hostId:${lane.name}');
      c?.client?.close();
    }
    _status.remove(hostId);
  }

  void dispose() {
    for (final c in _connections.values) {
      c.client?.close();
    }
    _connections.clear();
  }

  /// Opens a fresh connection. Used directly by the connection test.
  Future<OpenedClient> open(Host h, HostSecrets secrets, {void Function(int step)? onStep}) async {
    final List<SSHKeyPair>? identities;
    if (h.auth == AuthMethod.password) {
      identities = null;
    } else {
      final pem = h.auth == AuthMethod.keyFile ? await _readKey(h) : secrets.privateKey;
      if (pem == null || pem.trim().isEmpty) {
        throw ConnectionFailed('No private key is stored for this host.', step: 2);
      }
      try {
        identities = SSHKeyPair.fromPem(pem, secrets.hasPassphrase ? secrets.passphrase : null);
      } on SSHKeyDecryptError {
        throw ConnectionFailed('The key passphrase is wrong.', step: 2);
      } on Object catch (e) {
        if (SSHKeyPairSafe.isEncrypted(pem) && !secrets.hasPassphrase) {
          throw ConnectionFailed('This key is protected by a passphrase. Enter it to continue.', step: 2);
        }
        throw ConnectionFailed('Could not read the private key: ${_message(e)}', step: 2);
      }
    }

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(h.host, h.port, timeout: _connectTimeout);
    } on Object catch (e) {
      throw ConnectionFailed('Could not reach ${h.host}:${h.port}: ${_message(e)}');
    }
    onStep?.call(0);

    var seenKey = '';
    var seenType = '';
    HostKeyMismatch? mismatch;
    final client = SSHClient(
      socket,
      username: h.username,
      identities: identities,
      onPasswordRequest: h.auth == AuthMethod.password ? () => secrets.password : null,
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: _connectTimeout,
      authTimeout: _connectTimeout,
      onVerifyHostKey: (type, fingerprint) {
        seenType = type;
        seenKey = utf8.decode(fingerprint, allowMalformed: true);
        final pinned = h.hostKey;
        if (pinned != null && pinned.isNotEmpty && pinned != seenKey) {
          mismatch = HostKeyMismatch(pinned, seenKey);
          return false;
        }
        onStep?.call(1);
        return true;
      },
    );

    try {
      await client.authenticated;
    } on Object catch (e) {
      client.close();
      if (mismatch != null) throw mismatch!;
      if (e is SSHAuthError) {
        throw ConnectionFailed(
          h.auth == AuthMethod.password
              ? 'The server rejected the password for ${h.username}.'
              : 'The server rejected this key for ${h.username}. Check that its public key is authorised on the server.',
          step: 2,
        );
      }
      if (e is SSHHostkeyError) throw ConnectionFailed('Host key check failed: ${_message(e)}', step: 1);
      throw ConnectionFailed('SSH handshake failed: ${_message(e)}', step: seenKey.isEmpty ? 0 : 2);
    }
    onStep?.call(2);
    return OpenedClient(client, seenKey, seenType);
  }

  Future<String?> _readKey(Host h) async {
    final path = h.keyPath;
    final reader = readKeyFile;
    if (path == null || path.isEmpty) return null;
    if (reader == null) throw ConnectionFailed('Key files are not available on this platform. Paste the key instead.', step: 2);
    try {
      return await reader(path);
    } on Object catch (e) {
      throw ConnectionFailed('Could not read $path: ${_message(e)}', step: 2);
    }
  }

  Future<SSHClient> _client(Host h, Lane lane) {
    final c = _conn(h, lane);
    final existing = c.client;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    return c.connecting ??= _connect(h, lane, c).whenComplete(() => c.connecting = null);
  }

  Future<SSHClient> _connect(Host h, Lane lane, _Connection c) async {
    final primary = lane == Lane.command;
    if (primary) _setStatus(h.id, ConnStatus(ConnState.connecting, since: DateTime.now()));
    try {
      final opened = await open(h, await loadSecrets(h));
      if ((h.hostKey ?? '').isEmpty && opened.hostKey.isNotEmpty) {
        await pinHostKey?.call(h, opened.hostKeyType, opened.hostKey);
      }
      final client = opened.client;
      c.client = client;
      if (primary) _setStatus(h.id, ConnStatus(ConnState.connected, since: DateTime.now(), rttMs: status(h.id).rttMs));
      unawaited(client.done.then((_) => null, onError: (Object e) => e).then((e) {
        if (c.client != client) return;
        c.client = null;
        if (primary) _setStatus(h.id, _disconnected(e));
      }));
      return client;
    } on Object catch (e) {
      if (primary) _setStatus(h.id, _disconnected(e));
      rethrow;
    }
  }

  static ConnStatus _disconnected(Object? e) => ConnStatus(
        ConnState.disconnected,
        error: e == null ? 'Connection closed' : _message(e),
        since: DateTime.now(),
        hostKeyChanged: e is HostKeyMismatch,
      );

  Future<({SSHSession session, void Function() release})> _openChannel(
    Host h,
    String cmd,
    Lane lane, {
    Pty? pty,
    bool shell = false,
  }) async {
    final c = _conn(h, lane);
    final release = await c.semaphore.acquire();
    try {
      Future<SSHSession> start(SSHClient client) =>
          shell ? client.shell(pty: (pty ?? const Pty())._config) : client.execute(cmd, pty: pty?._config);
      var client = await _client(h, lane);
      SSHSession session;
      try {
        session = await start(client);
      } on Object {
        // Stale connection: reconnect once.
        if (c.client == client) {
          client.close();
          c.client = null;
        }
        client = await _client(h, lane);
        session = await start(client);
      }
      return (session: session, release: release);
    } on Object {
      release();
      rethrow;
    }
  }

  /// Runs [cmd] to completion and collects its output.
  Future<ExecResult> exec(
    Host h,
    String cmd, {
    List<int>? stdin,
    Duration timeout = const Duration(minutes: 2),
    String? display,
  }) async {
    final started = DateTime.now();
    final (:session, :release) = await _openChannel(h, cmd, Lane.command);
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    final done = Completer<ExecResult>();
    String? signal;
    Timer? timer;

    void finish() {
      if (done.isCompleted) return;
      timer?.cancel();
      release();
      done.complete(ExecResult(
        code: session.exitCode,
        signal: signal ?? session.exitSignal?.signalName,
        stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
        durationMs: DateTime.now().difference(started).inMilliseconds,
        command: display ?? cmd,
      ));
    }

    // The output streams end once the remote process has exited and been
    // drained; `done` alone can complete while data is still buffered.
    var open = 2;
    void streamDone() {
      if (--open == 0) session.done.whenComplete(finish);
    }

    session.stdout.listen(out.add, onDone: streamDone, onError: (_) => streamDone(), cancelOnError: true);
    session.stderr.listen(err.add, onDone: streamDone, onError: (_) => streamDone(), cancelOnError: true);

    // sshd only confirms the close once the remote process exits, so a
    // timeout must not wait for it.
    timer = Timer(timeout, () {
      signal = 'TIMEOUT';
      err.add(utf8.encode('\nTimed out after ${timeout.inSeconds}s.\n'));
      try {
        session.close();
      } on Object {
        // already closed
      }
      finish();
    });

    if (stdin != null) session.stdin.add(stdin is Uint8List ? stdin : Uint8List.fromList(stdin));
    unawaited(session.stdin.close().catchError((_) {}));
    return done.future;
  }

  Future<ExecResult> dokku(Host h, List<String> args, {List<int>? stdin, Duration timeout = const Duration(minutes: 2)}) {
    validateDokkuArgs(args);
    return exec(
      h,
      remoteCommand(args, username: h.username, sudo: h.sudo),
      stdin: stdin,
      timeout: timeout,
      display: displayCommand(args),
    );
  }

  /// Runs several commands at once over the same connection.
  Future<List<ExecResult>> dokkuAll(Host h, List<List<String>> commands) => Future.wait([
        for (final args in commands)
          dokku(h, args, timeout: const Duration(minutes: 1)).catchError(
            (Object e) => ExecResult(code: -1, stdout: '', stderr: _message(e), durationMs: 0, command: displayCommand(args)),
          ),
      ]);

  /// Starts [cmd] and reports its output as it arrives.
  Future<RemoteStream> stream(
    Host h,
    String cmd, {
    Pty? pty,
    List<int>? stdin,
    bool shell = false,
    required void Function(String chunk, bool isStderr) onData,
  }) async {
    final started = DateTime.now();
    final (:session, :release) = await _openChannel(h, cmd, Lane.stream, pty: pty, shell: shell);
    final done = Completer<StreamExit>();

    void finish(String? signal) {
      if (done.isCompleted) return;
      release();
      done.complete(StreamExit(
        session.exitCode,
        signal ?? session.exitSignal?.signalName,
        DateTime.now().difference(started).inMilliseconds,
      ));
    }

    var open = 2;
    void streamDone() {
      if (--open == 0) session.done.whenComplete(() => finish(null));
    }

    void listen(Stream<Uint8List> s, bool isStderr) {
      s.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
        (chunk) {
          if (!done.isCompleted) onData(chunk, isStderr);
        },
        onDone: streamDone,
        onError: (_) => streamDone(),
        cancelOnError: true,
      );
    }

    listen(session.stdout, false);
    listen(session.stderr, true);

    if (stdin != null) session.stdin.add(stdin is Uint8List ? stdin : Uint8List.fromList(stdin));
    // Interactive sessions keep stdin open for typing; everything else gets EOF.
    if (pty == null && !shell) unawaited(session.stdin.close().catchError((_) {}));
    return _SshStream(session, pty != null || shell, finish, done.future);
  }

  /// Starts a Dokku command as a stream. Follow-mode commands never exit by
  /// themselves, so they get a PTY, which lets us hang them up reliably.
  Future<RemoteStream> dokkuStream(
    Host h,
    List<String> args, {
    Pty? pty,
    List<int>? stdin,
    required void Function(String chunk, bool isStderr) onData,
  }) {
    validateDokkuArgs(args);
    final sub = subcommandOf(args);
    final follows = (sub == 'logs' || sub == 'events') && args.any((a) => a == '-t' || a == '--tail');
    return stream(
      h,
      remoteCommand(args, username: h.username, sudo: h.sudo),
      pty: pty ?? (follows ? const Pty(cols: 250, rows: 50) : null),
      stdin: stdin,
      onData: onData,
    );
  }

  /// Round trip used by the connection indicator.
  Future<ConnStatus> ping(Host h) async {
    try {
      final r = await exec(h, h.isDokkuUser ? 'version' : 'true', timeout: const Duration(seconds: 10));
      final s = ConnStatus(ConnState.connected, rttMs: r.durationMs, since: status(h.id).since);
      _setStatus(h.id, s);
      return s;
    } on Object catch (e) {
      final s = _disconnected(e);
      _setStatus(h.id, s);
      return s;
    }
  }

  /// Walks through the handshake, reporting each step for the connect dialog.
  Stream<HandshakeStep> test(Host h, HostSecrets secrets) async* {
    final target = 'ssh -p ${h.port} ${h.username}@${h.host}';
    yield HandshakeStep(0, StepStatus.running, target);
    final watch = Stopwatch()..start();
    final OpenedClient opened;
    try {
      opened = await open(h, secrets);
    } on HostKeyMismatch catch (e) {
      yield HandshakeStep(0, StepStatus.ok, target);
      yield HandshakeStep(1, StepStatus.fail, 'host key changed',
          detail: 'saved  ${e.expected}\nsent   ${e.actual}', presentedKey: e.actual);
      return;
    } on ConnectionFailed catch (e) {
      for (var i = 0; i < e.step; i++) {
        yield HandshakeStep(i, StepStatus.ok, i == 0 ? target : 'host key accepted');
      }
      yield HandshakeStep(e.step, StepStatus.fail, e.message);
      return;
    }
    final pinned = (h.hostKey ?? '').isNotEmpty;
    yield HandshakeStep(0, StepStatus.ok, target, detail: '${watch.elapsedMilliseconds} ms');
    yield HandshakeStep(1, StepStatus.ok, 'host key ${opened.hostKey}',
        detail: pinned ? 'matches the saved key' : 'will be remembered', hostKey: opened.hostKey, hostKeyType: opened.hostKeyType);
    yield HandshakeStep(2, StepStatus.ok, '${h.auth == AuthMethod.password ? 'password' : 'publickey'} authentication ok');
    yield const HandshakeStep(3, StepStatus.running, 'dokku version');

    final cmd = h.isDokkuUser ? 'version' : 'cd / && ${h.sudo ? 'sudo -n ' : ''}dokku version';
    var text = '';
    int? code;
    try {
      final r = await opened.client.runWithResult(cmd).timeout(const Duration(seconds: 20));
      text = utf8.decode(r.output, allowMalformed: true).trim();
      code = r.exitCode;
    } on Object catch (e) {
      text = _message(e);
    } finally {
      opened.client.close();
    }
    final version = RegExp(r'dokku version (\S+)', caseSensitive: false).firstMatch(text)?[1];
    if (code == 0 && version != null) {
      yield HandshakeStep(3, StepStatus.ok, 'dokku version → $version',
          dokkuVersion: version, hostKey: opened.hostKey, hostKeyType: opened.hostKeyType);
    } else {
      yield HandshakeStep(
        3,
        h.isDokkuUser ? StepStatus.fail : StepStatus.warn,
        text.isEmpty ? 'dokku not found' : text.split('\n').last,
        detail: h.isDokkuUser
            ? null
            : 'SSH works, but Dokku is not installed (or needs sudo). You can still save this host and run the installer.',
        hostKey: opened.hostKey,
        hostKeyType: opened.hostKeyType,
      );
    }
  }
}

/// `SSHKeyPair.isEncryptedPem` throws on malformed input; this does not.
abstract final class SSHKeyPairSafe {
  static bool isEncrypted(String pem) {
    try {
      return SSHKeyPair.isEncryptedPem(pem);
    } on Object {
      return false;
    }
  }
}

String _message(Object e) {
  final s = '$e';
  return s
      .replaceFirst(RegExp(r'^(Exception|SSH\w+Error|SocketException|StateError|TimeoutException)(\([^)]*\))?:?\s*'), '')
      .trim()
      .replaceFirst(RegExp(r'^$'), s);
}
