import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/platform.dart';
import '../../data/stores.dart';
import '../../state/core.dart';
import '../../state/router.dart';
import '../widgets/kit.dart';

/// Adds a host, or edits [editing]. Saving needs a successful connection test,
/// so a saved host is always one that worked at least once.
Future<void> showConnectDialog(BuildContext context, {Host? editing}) =>
    showAppDialog<void>(context, (_) => ConnectDialog(editing: editing));

const _stepLabels = ['ssh connect', 'host key', 'authentication', 'dokku version'];

class ConnectDialog extends ConsumerStatefulWidget {
  const ConnectDialog({super.key, this.editing});
  final Host? editing;

  @override
  ConsumerState<ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends ConsumerState<ConnectDialog> {
  late final Host? _editing = widget.editing;
  late final _host = TextEditingController(text: _editing?.host ?? '');
  late final _port = TextEditingController(text: '${_editing?.port ?? 22}');
  late final _name = TextEditingController(text: _editing?.name ?? '');
  late final _user = TextEditingController(text: _editing?.username ?? 'dokku');
  late final _keyPath = TextEditingController(text: _editing?.keyPath ?? '');
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  final _password = TextEditingController();

  late AuthMethod _auth = _editing?.auth ?? AuthMethod.key;
  late bool _sudo = _editing?.sudo ?? false;
  HostSecrets _stored = const HostSecrets();
  final _steps = <int, HandshakeStep>{};
  StreamSubscription<HandshakeStep>? _test;
  var _testing = false;
  var _saving = false;
  // Set once the user has accepted a key that differs from the saved one.
  var _trustNewKey = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    if (editing != null) {
      // Only to show that something is stored; the values are never displayed.
      ref.read(hostRepositoryProvider).secrets(editing.id).then((s) {
        if (mounted) setState(() => _stored = s);
      });
    }
  }

  @override
  void dispose() {
    _test?.cancel();
    for (final c in [_host, _port, _name, _user, _keyPath, _key, _passphrase, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() {
        _steps.clear();
        _error = null;
        _trustNewKey = false;
      });

  String get _username => _user.text.trim();
  bool get _isDokkuUser => _username == 'dokku';

  Host _draft({String? hostKey, String? hostKeyType}) {
    final address = _host.text.trim();
    // Re-verify against the remembered key only while the address is unchanged.
    final sameAddress = !_trustNewKey &&
        _editing != null &&
        _editing.host == address &&
        _editing.port == (int.tryParse(_port.text) ?? 22);
    return Host(
      id: _editing?.id ?? '',
      name: _name.text.trim().isEmpty ? address : _name.text.trim(),
      host: address,
      port: int.tryParse(_port.text) ?? 22,
      username: _username,
      auth: _auth,
      keyPath: _auth == AuthMethod.keyFile ? _keyPath.text.trim() : null,
      sudo: _sudo && !_isDokkuUser,
      hostKey: hostKey ?? (sameAddress ? _editing.hostKey : null),
      hostKeyType: hostKeyType ?? (sameAddress ? _editing.hostKeyType : null),
      createdAt: _editing?.createdAt ?? DateTime.now(),
    );
  }

  HostSecrets get _typed => HostSecrets(
        privateKey: _auth == AuthMethod.key ? _key.text : null,
        passphrase: _auth == AuthMethod.password ? null : _passphrase.text,
        password: _auth == AuthMethod.password ? _password.text : null,
      );

  List<String> _validate() {
    final d = _draft();
    final errs = validateHost(name: d.name, host: d.host, port: int.tryParse(_port.text), username: d.username);
    if (_auth == AuthMethod.keyFile && (d.keyPath ?? '').isEmpty) errs.add('Enter the path to a private key');
    return errs;
  }

  void _runTest() {
    final errs = _validate();
    if (errs.isNotEmpty) {
      setState(() => _error = errs.join('. '));
      return;
    }
    _test?.cancel();
    setState(() {
      _steps.clear();
      _error = null;
      _testing = true;
    });
    final secrets = _stored.merge(_typed);
    _test = ref.read(sshServiceProvider).test(_draft(), secrets).listen(
          (s) => setState(() => _steps[s.step] = s),
          onError: (Object e) => setState(() {
            _error = '$e';
            _testing = false;
          }),
          onDone: () => setState(() => _testing = false),
        );
  }

  HandshakeStep? get _last => _steps.isEmpty ? null : _steps[_steps.keys.reduce((a, b) => a > b ? a : b)];
  bool get _sshOk => _steps[2]?.status == StepStatus.ok;
  bool get _dokkuOk => _steps[3]?.status == StepStatus.ok;
  bool get _canSave => !_testing && _sshOk && (_dokkuOk || _last?.status == StepStatus.warn);

  Future<void> _save({required bool thenInstall}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final verified = _steps.values.where((s) => s.hostKey != null).lastOrNull;
      final draft = _draft(hostKey: verified?.hostKey, hostKeyType: verified?.hostKeyType);
      final hosts = ref.read(hostsProvider.notifier);
      final saved = _editing == null ? await hosts.add(draft, _typed) : await hosts.edit(draft, _typed);
      ref.read(prefsProvider.notifier).update((p) => p.copyWith(hostId: () => saved.id));
      if (!mounted) return;
      Navigator.of(context).pop();
      if (thenInstall) ref.read(routerProvider.notifier).go(const InstallRoute());
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final host = _editing!;
    final ok = await confirm(
      context,
      Confirm(
        title: 'Remove ${host.name}?',
        body: 'This removes the saved connection and its key from this device. Nothing on the server changes.',
        label: 'Remove host',
        danger: true,
      ),
    );
    if (!ok) return;
    await ref.read(hostsProvider.notifier).remove(host.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickKey() async {
    try {
      final file = await pickTextFile(maxBytes: 64 * 1024);
      if (file == null) return;
      _key.text = file.text;
      _changed();
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    final authOptions = [AuthMethod.key, if (keyFilesSupported) AuthMethod.keyFile, AuthMethod.password];
    final saveLabel = editing != null ? 'Save changes' : (_dokkuOk || !_sshOk ? 'Save host' : 'Save & install Dokku');

    return AppDialog(
      title: editing == null ? 'Connect a Dokku host' : 'Edit ${editing.name}',
      subtitle: 'Keys and passwords are kept in this device\'s secure storage and go nowhere else.',
      width: 500,
      leading: editing != null
          ? Btn('Remove host', variant: BtnVariant.ghost, onPressed: _remove)
          : Btn('No Dokku yet? Install it', variant: BtnVariant.ghost, onPressed: _canSave && !_dokkuOk ? () => _save(thenInstall: true) : null,
              tooltip: _canSave ? null : 'Connect as root or a sudo user first, then test the connection'),
      actions: [
        Btn('Test connection', size: BtnSize.md, icon: LucideIcons.terminal, loading: _testing, onPressed: _runTest),
        Btn(saveLabel,
            size: BtnSize.md,
            variant: BtnVariant.primary,
            loading: _saving,
            onPressed: _canSave ? () => _save(thenInstall: editing == null && !_dokkuOk) : null,
            tooltip: _canSave ? null : 'Run a successful connection test first'),
      ],
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Field('Hostname or IP',
                child: AppInput(controller: _host, large: true, hint: '165.227.14.92', autofocus: editing == null, onChanged: (_) => _changed(),
                    keyboardType: TextInputType.url)),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Field('SSH port',
                child: AppInput(controller: _port, large: true, inputFormatters: digitsOnly, keyboardType: TextInputType.number, onChanged: (_) => _changed())),
          ),
        ]),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Field('Display name', child: AppInput(controller: _name, large: true, hint: _host.text.isEmpty ? 'prod-01' : _host.text))),
          const SizedBox(width: 10),
          Expanded(child: Field('Username', child: AppInput(controller: _user, large: true, onChanged: (_) => _changed()))),
        ]),
        Text(
          'Use dokku for app management. SSH keys, plugin installs, host metrics and the terminal need root or a sudo user.',
          style: T.sans(11, color: C.dim, height: 1.45),
        ),
        if (!_isDokkuUser)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: C.w(.02), border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
            child: SwitchRow(
              title: 'Run dokku with sudo',
              desc: 'Needs passwordless sudo. Leave off when signing in as root.',
              value: _sudo,
              onChanged: (v) => setState(() {
                _sudo = v;
                _steps.clear();
              }),
            ),
          ),
        Field(
          'Sign in with',
          child: Seg<AuthMethod>(
            expand: true,
            value: _auth,
            options: authOptions,
            labels: (a) => switch (a) { AuthMethod.key => 'Private key', AuthMethod.keyFile => 'Key file', AuthMethod.password => 'Password' },
            onChanged: (a) => setState(() {
              _auth = a;
              _steps.clear();
            }),
          ),
        ),
        if (_auth == AuthMethod.key)
          Field(
            'Private key',
            trailing: Btn('Choose file', size: BtnSize.xs, onPressed: _pickKey),
            child: AppInput(
              controller: _key,
              maxLines: 5,
              minLines: 4,
              dashed: true,
              onChanged: (_) => _changed(),
              hint: _stored.hasPrivateKey
                  ? 'A key is stored. Paste a new one to replace it.'
                  : '-----BEGIN OPENSSH PRIVATE KEY-----\n…\nPaste the key, or choose the file',
            ),
          ),
        if (_auth == AuthMethod.keyFile)
          Field('Key file on this device',
              hint: 'Only the path is saved. The key stays in its file.',
              child: AppInput(controller: _keyPath, large: true, hint: '~/.ssh/id_ed25519', onChanged: (_) => _changed())),
        if (_auth != AuthMethod.password)
          Field('Key passphrase',
              child: AppInput(
                  controller: _passphrase,
                  large: true,
                  obscure: true,
                  onChanged: (_) => _changed(),
                  hint: _stored.hasPassphrase ? 'stored' : 'only if the key has one')),
        if (_auth == AuthMethod.password)
          Field('Password',
              child: AppInput(
                  controller: _password,
                  large: true,
                  obscure: true,
                  onChanged: (_) => _changed(),
                  hint: _stored.hasPassword ? 'stored, type to replace' : null)),
        if (_steps.isNotEmpty || _testing) _HandshakeLog(_steps),
        if (!_testing && _steps[1]?.presentedKey != null)
          AlertBox(
            tone: Tone.bad,
            title: 'This is not the key saved for this server.',
            text: 'That is expected after the server was reinstalled or rebuilt. If you did not expect it, '
                'stop here: the connection may be intercepted.',
            action: Btn('Trust new key',
                variant: BtnVariant.dangerGhost,
                onPressed: () {
                  _trustNewKey = true;
                  _runTest();
                }),
          ),
        if (_error != null) Text(_error!, style: T.sans(12, color: C.bad, height: 1.45)),
      ],
    );
  }
}

class _HandshakeLog extends StatelessWidget {
  const _HandshakeLog(this.steps);
  final Map<int, HandshakeStep> steps;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: C.term, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < _stepLabels.length; i++) _row(i, steps[i]),
        ]),
      );

  Widget _row(int i, HandshakeStep? s) {
    final color = switch (s?.status) {
      null => C.dim,
      StepStatus.fail => C.bad,
      StepStatus.warn => C.warn,
      StepStatus.running => C.fg,
      StepStatus.ok => C.soft,
    };
    final Widget mark = switch (s?.status) {
      null => Container(width: 4, height: 4, decoration: const BoxDecoration(color: C.dim, shape: BoxShape.circle)),
      StepStatus.running => const Spinner(size: 10),
      StepStatus.ok => const Icon(LucideIcons.check, size: 12, color: C.ok),
      StepStatus.fail => const Icon(LucideIcons.x, size: 12, color: C.bad),
      StepStatus.warn => const Icon(LucideIcons.triangleAlert, size: 11, color: C.warn),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 3), child: SizedBox(width: 12, height: 12, child: Center(child: mark))),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s?.text ?? _stepLabels[i], style: T.mono(11.5, color: color, height: 1.5)),
            if (s?.detail != null) Text(s!.detail!, style: T.mono(10.5, color: C.muted, height: 1.5)),
          ]),
        ),
      ]),
    );
  }
}
