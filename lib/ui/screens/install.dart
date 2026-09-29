import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/host_scripts.dart' show sudoShim;
import '../../core/install_script.dart';
import '../../data/models.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../shell/connect_dialog.dart';
import '../widgets/kit.dart';
import 'stream_run.dart';

const _docs = 'https://dokku.com/docs/getting-started/installation/';
const _steps = ['Requirements', 'Method and options', 'Keys and domain', 'Run'];
const _phases = ['deps', 'docker', 'dokku', 'configure', 'done'];
const _runStep = 3;

final _ipAddress = RegExp(r'^[\d.]+$|:');
final _leadingNumber = RegExp(r'^\d+(\.\d+)?');
final _supportedArch = RegExp(r'^(x86_64|amd64|aarch64|arm64)$');
final _installedVersion = RegExp(r'dokku version (\S+)');
final _firstNumber = RegExp(r'\d+');

class Requirement {
  const Requirement(this.label, this.detail, this.state, this.tone);
  final String label;
  final String detail;
  final String state;

  /// [Tone.bad] blocks the install, [Tone.warn] only advises.
  final Tone tone;
}

/// What the preflight script found, as the checks shown in the first step.
@visibleForTesting
List<Requirement> installRequirements(Map<String, String> p) {
  String at(List<String> parts, int i) => i < parts.length ? parts[i].trim() : '';
  final os = (p['os'] ?? '').split('|');
  final id = at(os, 0), ver = at(os, 1), pretty = at(os, 3);
  final version = double.tryParse(_leadingNumber.firstMatch(ver)?[0] ?? '') ?? 0;
  final osOk = (id == 'ubuntu' && version >= 22.04) || (id == 'debian' && version >= 11);
  final arch = (p['arch'] ?? '').trim();
  final archOk = _supportedArch.hasMatch(arch);
  final who = (p['user'] ?? '').split('\n');
  final user = at(who, 0), uid = at(who, 1);
  final sudoOk = uid == '0' || at(who, 2) == 'sudo-ok';
  final nginx = (p['nginx'] ?? 'none').trim();
  final clean = nginx == 'none' || nginx == '0';
  final keys = int.tryParse((p['keys'] ?? '').split('\n').first.trim()) ?? 0;
  final keyCount = '$keys key${keys == 1 ? '' : 's'}';
  final dokku = _installedVersion.firstMatch(p['dokku'] ?? '')?[1];
  final memMb = ((int.tryParse(_firstNumber.firstMatch(p['mem'] ?? '')?[0] ?? '') ?? 0) / 1024).round();

  return [
    Requirement(
      'Operating system',
      '${pretty.isEmpty ? 'unknown' : pretty} · supported: Ubuntu 22.04 / 24.04, Debian 11+',
      osOk ? '$id $ver' : 'unsupported',
      osOk ? Tone.ok : Tone.warn,
    ),
    Requirement(
      'Architecture',
      '${arch.isEmpty ? 'unknown' : arch} · amd64 and arm64 are supported',
      archOk ? arch : 'unsupported',
      archOk ? Tone.ok : Tone.bad,
    ),
    Requirement(
      'Sudo access',
      '${user.isEmpty ? 'unknown user' : user} · the installer must run as root or a user with passwordless sudo',
      sudoOk ? (uid == '0' ? 'root' : 'sudo') : 'no sudo',
      sudoOk ? Tone.ok : Tone.bad,
    ),
    Requirement(
      'Memory',
      '$memMb MiB · at least 1 GiB recommended (builds can need more)',
      '$memMb MiB',
      memMb >= 900 ? Tone.ok : Tone.warn,
    ),
    Requirement(
      'Fresh machine',
      clean ? 'nothing in /etc/nginx/sites-enabled' : '$nginx file(s) in /etc/nginx/sites-enabled will be removed',
      clean ? 'clean' : 'nginx in use',
      clean ? Tone.ok : Tone.warn,
    ),
    Requirement(
      'SSH keypair for deploys',
      '~/.ssh/authorized_keys has $keyCount · can be imported into dokku',
      keyCount,
      keys > 0 ? Tone.ok : Tone.warn,
    ),
    Requirement(
      'Existing Dokku',
      dokku == null
          ? 'dokku: command not found · fresh install'
          : 'dokku $dokku is already installed · use Upgrade on the Server page instead',
      dokku ?? 'none',
      dokku == null ? Tone.ok : Tone.warn,
    ),
  ];
}

final _dockerLine = RegExp('docker', caseSensitive: false);
final _dokkuLine =
    RegExp(r'(installing|setting up|unpacking) dokku|bootstrap\.sh|make install|apt-get.*dokku', caseSensitive: false);
final _configureLine =
    RegExp(r'ssh-keys:add|SHA256:|domains:set-global|Set(ting)? global|plugin:install', caseSensitive: false);

/// How far the installer has got, as an index into the phases under its output.
@visibleForTesting
int installPhase(List<String> lines) {
  var phase = 0;
  for (final l in lines) {
    if (phase < 1 && _dockerLine.hasMatch(l)) phase = 1;
    if (phase < 2 && _dokkuLine.hasMatch(l)) phase = 2;
    if (phase < 3 && _configureLine.hasMatch(l)) phase = 3;
  }
  return phase;
}

Future<void> _openDocs() async {
  try {
    await launchUrl(Uri.parse(_docs), mode: LaunchMode.externalApplication);
  } on Object {
    // no browser to hand the link to
  }
}

/// Lowercase letters, digits and dashes, as Dokku wants its names.
final _slug = TextInputFormatter.withFunction(
  (_, next) => next.copyWith(text: next.text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-')),
);

class InstallScreen extends StatelessWidget {
  const InstallScreen({super.key, required this.host});
  final Host? host;

  @override
  Widget build(BuildContext context) {
    final host = this.host;
    if (host == null || !host.hasShell) return _NeedsShell(host);
    // Options and detected addresses belong to one server.
    return _Wizard(key: ValueKey(host.id), host: host);
  }
}

class _Crumb extends ConsumerWidget {
  const _Crumb();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(children: [
        LinkText('Server & SSH',
            onTap: () => ref.read(routerProvider.notifier).section(const ServerRoute()), style: T.sans(12)),
        Text('  /  ', style: T.sans(12, color: C.muted)),
        Flexible(
          child: Text('Install Dokku',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(12, weight: FontWeight.w500)),
        ),
      ]);
}

class _NeedsShell extends StatelessWidget {
  const _NeedsShell(this.host);
  final Host? host;

  @override
  Widget build(BuildContext context) {
    final host = this.host;
    return PageBody(maxWidth: 1180, children: [
      const _Crumb(),
      const PageHead(title: 'Install Dokku'),
      Panel(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(host == null ? 'Connect to the server first' : '${host.name} is connected as the dokku user', style: T.title),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              'The installer runs over SSH as root or a user with passwordless sudo. Add the server with its root '
              'credentials; the connection test will report that Dokku is missing and offer to continue here.',
              style: T.sans(12.5, color: C.muted, height: 1.6),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Btn('Connect a server',
                variant: BtnVariant.primary, size: BtnSize.md, onPressed: () => showConnectDialog(context)),
            if (host != null)
              Btn('Edit ${host.name}', size: BtnSize.md, onPressed: () => showConnectDialog(context, editing: host)),
            const LinkText('Installation docs', onTap: _openDocs),
          ]),
        ]),
      ),
    ]);
  }
}

class _Wizard extends ConsumerStatefulWidget {
  const _Wizard({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<_Wizard> createState() => _WizardState();
}

class _WizardState extends ConsumerState<_Wizard> {
  static const _defaults = InstallOptions();

  late final _hostIsIp = _ipAddress.hasMatch(widget.host.host);
  late final _run = streamRunProvider('install:${widget.host.id}');

  // Both start from a value that arrives later: the latest release, the server's address.
  final _tag = SyncedController(_defaults.dokkuTag);
  final _ip = SyncedController();
  final _branch = TextEditingController(text: _defaults.dokkuBranch);
  final _repo = TextEditingController(text: _defaults.sourceRepo);
  final _hostname = TextEditingController();
  final _keyFile = TextEditingController(text: _defaults.keyFile);
  final _keyName = TextEditingController(text: _defaults.keyName);
  final _publicKey = TextEditingController();
  late final _domain = TextEditingController(text: _hostIsIp ? '' : widget.host.host);
  final _firstApp = TextEditingController(text: _defaults.firstApp);

  /// The choices that are not typed.
  late var _choices = InstallOptions(domainMode: _hostIsIp ? _defaults.domainMode : DomainMode.custom);
  var _step = 0;

  @override
  void initState() {
    super.initState();
    // Coming back to an install that was started earlier.
    if (ref.read(_run).status != RunStatus.idle) _step = _runStep;
  }

  @override
  void dispose() {
    _tag.dispose();
    _ip.dispose();
    for (final c in [_branch, _repo, _hostname, _keyFile, _keyName, _publicKey, _domain, _firstApp]) {
      c.dispose();
    }
    super.dispose();
  }

  InstallOptions get _options => _choices.copyWith(
        dokkuTag: _tag.text.trim(),
        dokkuBranch: _branch.text.trim(),
        sourceRepo: _repo.text.trim(),
        hostname: _hostname.text.trim(),
        keyFile: _keyFile.text.trim(),
        keyName: _keyName.text,
        publicKey: _publicKey.text,
        globalDomain: _domain.text.trim().toLowerCase(),
        serverIp: _ip.text.trim(),
        firstApp: _firstApp.text,
      );

  void _choose(InstallOptions next) => setState(() => _choices = next);
  void _typed(String _) => setState(() {});

  Future<void> _start(InstallOptions o, String? existing) async {
    final host = widget.host;
    final ok = await confirm(
      context,
      Confirm(
        title: 'Install Dokku on ${host.name}?',
        body: 'The generated script runs as ${host.username}@${host.host} and takes 5 to 10 minutes. '
            'It installs Docker and Dokku and removes files in nginx sites-enabled.'
            '${existing == null ? '' : ' Dokku $existing is already installed on this server.'}',
        label: 'Run installer',
      ),
    );
    if (!ok || !mounted) return;
    // The script calls sudo, which a root login on a minimal image does not have.
    await ref.read(_run.notifier).start(host, '$sudoShim${installScriptText(o)}');
  }

  void _openDashboard() {
    ref.read(_run.notifier).reset();
    ref.read(routerProvider.notifier).section(const DashboardRoute());
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final pre = ref.watch(preflightProvider(host.id));
    final latest = ref.watch(latestDokkuProvider).value;
    final run = ref.watch(_run);

    final facts = pre.hasError ? null : pre.value;
    final detectedIp = _hostIsIp ? host.host : (facts?['ip'] ?? '').trim();
    if (latest != null) _tag.sync(latest);
    _ip.sync(detectedIp);

    final o = _options;
    final reqs = facts == null ? const <Requirement>[] : installRequirements(facts);
    final failing = [for (final r in reqs) if (r.tone == Tone.bad) r.label];
    final errors = validateInstallOptions(o);
    final canRun = facts != null && failing.isEmpty && errors.isEmpty;

    return PageBody(maxWidth: 1180, children: [
      const _Crumb(),
      PageHead(
        eyebrow: 'New host · ${host.host}',
        title: 'Install Dokku',
        actions: const [LinkText('Installation docs', onTap: _openDocs)],
      ),
      UnderlineTabs(
        tabs: [for (final (i, label) in _steps.indexed) ('$i', '0${i + 1}  $label')],
        selected: '$_step',
        onSelect: (id) {
          if (!run.running) setState(() => _step = int.parse(id));
        },
      ),
      LayoutBuilder(builder: (context, box) {
        return TwoCol(
          leftFlex: 7,
          rightFlex: 5,
          left: [
            ...switch (_step) {
              0 => [_requirements(pre, reqs)],
              1 => _method(o, latest),
              2 => _keysAndDomain(o, detectedIp),
              _ => _runner(run, errors: errors, failing: failing, checked: facts != null),
            },
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Btn('Back',
                  variant: BtnVariant.outline,
                  size: BtnSize.md,
                  onPressed: _step == 0 || run.running ? null : () => setState(() => _step--)),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                  if (_step < _runStep)
                    Btn('Continue', variant: BtnVariant.primary, size: BtnSize.md, onPressed: () => setState(() => _step++))
                  else ...[
                    CopyBtn(installScriptText(o), label: 'Copy script', size: BtnSize.md),
                    if (run.running)
                      Btn('Cancel install',
                          variant: BtnVariant.outline, size: BtnSize.md, onPressed: ref.read(_run.notifier).kill),
                    if (run.status == RunStatus.done)
                      Btn('Open dashboard', variant: BtnVariant.primary, size: BtnSize.md, onPressed: _openDashboard)
                    else
                      Btn(
                        switch (run.status) {
                          RunStatus.running => 'Installing…',
                          RunStatus.failed => 'Run again',
                          _ => 'Run installer',
                        },
                        variant: BtnVariant.primary,
                        size: BtnSize.md,
                        loading: run.running,
                        onPressed: canRun ? () => _start(o, _installedVersion.firstMatch(facts['dokku'] ?? '')?[1]) : null,
                      ),
                  ],
                ]),
              ),
            ]),
          ],
          // Stacked under the form the script is shown whole, so the page is the only thing that scrolls.
          right: [_ScriptPanel(buildInstallScript(o), scroll: box.maxWidth >= Bp.twoCol)],
        );
      }),
    ]);
  }

  Widget _requirements(AsyncValue<Map<String, String>> pre, List<Requirement> reqs) {
    final host = widget.host;
    return Panel.column(children: [
      PanelHead(
        'Requirements check',
        trailing: Btn('Re-run checks', loading: pre.isLoading, onPressed: () => ref.invalidate(preflightProvider(host.id))),
      ),
      if (pre.isLoading && reqs.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Spinner(),
            const SizedBox(width: 10),
            Expanded(child: Text('Inspecting ${host.host}…', style: T.small)),
          ]),
        ),
      if (pre.hasError && !pre.isLoading)
        EmptyBox('Could not inspect ${host.host}: ${pre.error}\nCheck the connection, then re-run the checks.'),
      for (final (i, q) in reqs.indexed)
        PanelRow(
          first: i == 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: SizedBox(
                width: 20,
                child: Icon(q.tone == Tone.ok ? LucideIcons.check : LucideIcons.triangleAlert, size: 14, color: q.tone.color),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(q.label, style: T.body),
                const SizedBox(height: 2),
                Text(q.detail, style: T.mono(10.5, color: C.muted, height: 1.45)),
              ]),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(q.state,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(10.5, color: q.tone.color, height: 1.6)),
            ),
          ]),
        ),
      const Padding(
        padding: EdgeInsets.all(12),
        child: AlertBox(
          title: 'Fresh VM recommended.',
          text: 'First-time installation removes files in nginx sites-enabled. '
              'Back up any existing nginx config before continuing.',
        ),
      ),
    ]);
  }

  List<Widget> _method(InstallOptions o, String? latest) {
    const methods = [
      (
        InstallMethod.bootstrap,
        'bootstrap.sh (recommended)',
        'Official installer: installs Docker, the dokku apt package and core plugin dependencies. '
            'Pin a release with DOKKU_TAG.',
      ),
      (
        InstallMethod.apt,
        'Unattended apt package',
        'For provisioning tools. Pre-seed debconf answers, add the packagecloud repo, then apt-get install dokku.',
      ),
      (
        InstallMethod.source,
        'From source (make install)',
        'Clone a repository and run sudo make install. For development or a patched fork.',
      ),
    ];

    _OptRow toggle(String key, String label, String desc, bool value, InstallOptions Function(bool) change) => _OptRow(
          label: label,
          name: key,
          desc: desc,
          control: AppSwitch(value: value, label: label, onChanged: (v) => _choose(change(v))),
        );
    _OptRow text(String key, String label, String desc, TextEditingController controller, {String? hint}) => _OptRow(
          label: label,
          name: key,
          desc: desc,
          wide: true,
          control: AppInput(controller: controller, hint: hint, onChanged: _typed),
        );

    final source = o.method == InstallMethod.source;
    final apt = o.method == InstallMethod.apt;
    final options = [
      if (!source)
        toggle(
          'DOKKU_NO_INSTALL_RECOMMENDS',
          'Skip recommended packages',
          'Skips herokuish (Heroku buildpacks) and other recommended dependencies. Only for Dockerfile-only hosts.',
          o.noRecommends,
          (v) => _choices.copyWith(noRecommends: v),
        ),
      if (!source)
        toggle('dokku/vhost_enable', 'Vhost-based deployments',
            'Apps get <app>.<hostname> instead of a port on the host IP.', o.vhost, (v) => _choices.copyWith(vhost: v)),
      if (!source)
        text(
          'dokku/hostname',
          'Hostname',
          'Used as the vhost domain and for the app URL printed after deploy. Defaults to the global domain.',
          _hostname,
          hint: globalDomainFor(o),
        ),
      if (apt)
        toggle('dokku/skip_key_file', 'Skip key file check', 'When on, you must add an SSH key manually after install.',
            o.skipKey, (v) => _choices.copyWith(skipKey: v)),
      if (apt && !o.skipKey)
        text('dokku/key_file', 'SSH key file', 'Public key file on the server that is added to the dokku user.', _keyFile),
      if (!source)
        toggle('dokku/nginx_enable', 'Enable nginx-vhosts plugin',
            'Turn off only if you will run a different proxy (Traefik, Caddy).', o.nginx, (v) => _choices.copyWith(nginx: v)),
      if (source)
        text('git clone', 'Source repository', 'HTTPS URL of the dokku repository or your fork.', _repo),
    ];

    return [
      Panel.column(children: [
        const PanelHead('Install method'),
        for (final (i, (method, label, desc)) in methods.indexed)
          Semantics(
            button: true,
            selected: o.method == method,
            child: PanelRow(
              first: i == 0,
              tint: o.method == method ? C.w(.04) : null,
              onTap: () => _choose(_choices.copyWith(method: method)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: RadioDot(o.method == method)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(label, style: T.sans(12.5, weight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(desc, style: T.small),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
      if (o.method == InstallMethod.bootstrap)
        Panel.column(children: [
          const PanelHead('Version'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Seg<VersionMode>(
                  value: o.versionMode,
                  options: VersionMode.values,
                  labels: (m) => m == VersionMode.tag ? 'Release tag' : 'Git branch (source)',
                  onChanged: (m) => _choose(_choices.copyWith(versionMode: m)),
                ),
              ),
              const SizedBox(height: 14),
              if (o.versionMode == VersionMode.tag)
                Field(
                  'DOKKU_TAG',
                  hint: 'Pinning a tag makes the install reproducible. Keep the latest release unless you need a specific one.',
                  child: Row(children: [
                    Expanded(child: AppInput(controller: _tag.controller, large: true, onChanged: _typed)),
                    if (latest != null && latest == o.dokkuTag) ...[
                      const SizedBox(width: 8),
                      const Pill('latest stable', tone: Tone.ok, mono: true, dot: false),
                    ],
                  ]),
                )
              else
                Field(
                  'DOKKU_BRANCH',
                  hint: 'Installs from source. Unreleased branches may break; use for development only.',
                  hintTone: Tone.warn,
                  child: AppInput(controller: _branch, large: true, onChanged: _typed),
                ),
            ]),
          ),
        ]),
      Panel.column(children: [
        const PanelHead('Options', note: 'env vars · debconf'),
        for (final (i, row) in options.indexed) i == 0 ? row.asFirst() : row,
      ]),
    ];
  }

  List<Widget> _keysAndDomain(InstallOptions o, String detectedIp) {
    final host = widget.host;
    final paste = o.keyMode == KeyMode.paste;
    final key = o.publicKey.trim();
    final keyOk = publicKeyPattern.hasMatch(key);
    final address = o.serverIp.isEmpty ? host.host : o.serverIp;

    final name = Field('Key name', child: AppInput(controller: _keyName, large: true, inputFormatters: [_slug], onChanged: _typed));
    final source = paste
        ? Field(
            'Public key',
            hint: key.contains('PRIVATE KEY')
                ? 'This is a private key. Never paste a private key here. Use the matching .pub file instead.'
                : key.isNotEmpty && !keyOk
                    ? 'This does not look like an OpenSSH public key. Never paste a private key here.'
                    : 'One line, starting with ssh-ed25519, ssh-rsa or ecdsa-sha2. Never paste a private key here.',
            hintTone: key.isNotEmpty && !keyOk ? Tone.bad : null,
            child: AppInput(controller: _publicKey, large: true, hint: 'ssh-ed25519 AAAA… user@host', onChanged: _typed),
          )
        : Field(
            'Source',
            child: Container(
              height: 32 + touchPad(context),
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.centerLeft,
              decoration:
                  BoxDecoration(color: C.w(.03), border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
              child: Text('~/.ssh/authorized_keys of ${host.username}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12, color: C.muted)),
            ),
          );

    final after = [
      (
        'Disable web installer',
        'sudo systemctl disable --now dokku-installer',
        o.disableInstaller,
        (bool v) => _choices.copyWith(disableInstaller: v),
      ),
      (
        'Install letsencrypt plugin',
        'dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git',
        o.letsencrypt,
        (bool v) => _choices.copyWith(letsencrypt: v),
      ),
      ('Create first app', 'dokku apps:create ${o.firstApp}', o.createFirst, (bool v) => _choices.copyWith(createFirst: v)),
    ];

    return [
      Panel.column(children: [
        const PanelHead('Admin SSH key'),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('Grants push access to the dokku user.', style: T.small),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Seg<KeyMode>(
                value: o.keyMode,
                options: KeyMode.values,
                labels: (m) => m == KeyMode.authorizedKeys ? 'Reuse authorized_keys' : 'Paste public key',
                onChanged: (m) => _choose(_choices.copyWith(keyMode: m)),
              ),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, box) {
              if (box.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [name, const SizedBox(height: 10), source],
                );
              }
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 140, child: name),
                const SizedBox(width: 10),
                Expanded(child: source),
              ]);
            }),
          ]),
        ),
      ]),
      Panel.column(children: [
        const PanelHead('Global domain'),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('Apps deploy to <app>.<global domain>. Needs an A record or CNAME pointing at the server.', style: T.small),
            const SizedBox(height: 12),
            _Choice(
              selected: o.domainMode == DomainMode.custom,
              label: 'Domain you control',
              desc: 'A record or CNAME → $address; wildcard for per-app subdomains',
              value: o.globalDomain.isEmpty ? 'dokku.me' : o.globalDomain,
              onTap: () => _choose(_choices.copyWith(domainMode: DomainMode.custom)),
            ),
            const SizedBox(height: 10),
            _Choice(
              selected: o.domainMode == DomainMode.ip,
              label: 'Server IP',
              desc: 'Apps are served on ports; no subdomain routing',
              value: o.serverIp.isEmpty ? '—' : o.serverIp,
              onTap: () => _choose(_choices.copyWith(domainMode: DomainMode.ip)),
            ),
            const SizedBox(height: 10),
            _Choice(
              selected: o.domainMode == DomainMode.sslip,
              label: 'sslip.io',
              desc: 'Free wildcard DNS for the IP; subdomains without owning a domain',
              value: o.serverIp.isEmpty ? '—' : '${o.serverIp}.sslip.io',
              onTap: () => _choose(_choices.copyWith(domainMode: DomainMode.sslip)),
            ),
            if (o.domainMode == DomainMode.custom) ...[
              const SizedBox(height: 10),
              AppInput(
                  controller: _domain,
                  large: true,
                  hint: 'apps.example.com',
                  keyboardType: TextInputType.url,
                  onChanged: _typed),
            ],
            // Only asked for when the address could not be worked out, or was typed before it was.
            if (o.domainMode != DomainMode.custom && (detectedIp.isEmpty || _ip.dirty)) ...[
              const SizedBox(height: 10),
              AppInput(controller: _ip.controller, large: true, hint: 'Public IP of the server', onChanged: _typed),
            ],
          ]),
        ),
      ]),
      Panel.column(children: [
        const PanelHead('After install'),
        for (final (i, (label, command, value, change)) in after.indexed)
          PanelRow(
            first: i == 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label, style: T.body),
                  const SizedBox(height: 3),
                  Text(command, style: T.mono(10.5, color: C.muted, height: 1.45)),
                ]),
              ),
              const SizedBox(width: 16),
              AppSwitch(value: value, label: label, onChanged: (v) => _choose(change(v))),
            ]),
          ),
        if (o.createFirst)
          PanelRow(
            tint: C.w(.02),
            child: Row(children: [
              Text('First app name', style: T.sans(12, color: C.muted)),
              const SizedBox(width: 10),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: AppInput(controller: _firstApp, inputFormatters: [_slug], onChanged: _typed),
                ),
              ),
            ]),
          ),
      ]),
    ];
  }

  List<Widget> _runner(RunState run, {required List<String> errors, required List<String> failing, required bool checked}) {
    final host = widget.host;
    final phase = run.status == RunStatus.done ? _phases.length - 1 : installPhase(run.lines);
    final tone = switch (run.status) {
      RunStatus.running => Tone.info,
      RunStatus.done => Tone.ok,
      RunStatus.failed => Tone.bad,
      RunStatus.idle => Tone.mute,
    };

    Color dot(int i) {
      if (run.status == RunStatus.idle) return C.w(.12);
      if (run.status == RunStatus.done || phase > i) return Tone.ok.color;
      if (phase == i && run.running) return Tone.info.color;
      if (phase == i && run.status == RunStatus.failed) return Tone.bad.color;
      return C.w(.12);
    }

    return [
      if (errors.isNotEmpty) AlertBox(tone: Tone.bad, title: 'Fix these before running:', text: errors.join(' · ')),
      if (failing.isNotEmpty)
        AlertBox(tone: Tone.bad, title: 'Requirements not met.', text: '${failing.join(', ')}. See step 01.'),
      if (!checked)
        const AlertBox(
          title: 'Requirements not checked yet.',
          text: 'The installer can run once the checks in step 01 have finished.',
        ),
      Panel(
        color: C.term,
        child: SizedBox(
          height: 460,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: C.card, border: Border(bottom: BorderSide(color: C.line))),
              child: Row(children: [
                const Icon(LucideIcons.terminal, size: 13, color: C.fg),
                const SizedBox(width: 8),
                Expanded(child: Text('Installer output', style: T.sans(12.5, weight: FontWeight.w600))),
                Pill(run.status == RunStatus.done ? 'complete' : run.status.name, tone: tone, mono: true, pulse: run.running),
              ]),
            ),
            Expanded(
              child: StreamOutput(
                lines: run.lines,
                idle: switch (run.status) {
                  RunStatus.idle => TextSpan(children: [
                      const TextSpan(text: 'Press Run installer to run the generated script over SSH as '),
                      TextSpan(text: '${host.username}@${host.host}', style: const TextStyle(color: C.soft)),
                      const TextSpan(text: '. It takes 5 to 10 minutes depending on connection speed.'),
                    ]),
                  RunStatus.running => const TextSpan(text: 'Starting…'),
                  _ => const TextSpan(text: 'The installer printed nothing.'),
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.line))),
              child: Wrap(spacing: 16, runSpacing: 4, children: [
                for (final (i, label) in _phases.indexed)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: dot(i), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(label,
                        style: T.mono(10.5, color: run.status != RunStatus.idle && phase >= i ? C.fg : C.dim)),
                  ]),
              ]),
            ),
          ]),
        ),
      ),
    ];
  }
}

/// One install option: what it is, the variable or debconf key behind it, and its control.
class _OptRow extends StatelessWidget {
  const _OptRow({
    required this.label,
    required this.name,
    required this.desc,
    required this.control,
    this.wide = false,
    this.first = false,
  });
  final String label;
  final String name;
  final String desc;
  final Widget control;

  /// A text field, which moves below the description when there is no room beside it.
  final bool wide;
  final bool first;

  _OptRow asFirst() => _OptRow(label: label, name: name, desc: desc, control: control, wide: wide, first: true);

  @override
  Widget build(BuildContext context) {
    final lead = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(label, style: T.body),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: C.w(.05), borderRadius: BorderRadius.circular(4)),
          child: Text(name, style: T.mono(10, color: C.muted)),
        ),
      ]),
      const SizedBox(height: 3),
      Text(desc, style: T.hint),
    ]);
    return PanelRow(
      first: first,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: LayoutBuilder(builder: (context, box) {
        if (wide && box.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [lead, const SizedBox(height: 8), control],
          );
        }
        return Row(children: [
          Expanded(child: lead),
          const SizedBox(width: 16),
          if (wide) SizedBox(width: 220, child: control) else control,
        ]);
      }),
    );
  }
}

/// One of a few exclusive choices, with the value it would produce.
class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.label, required this.desc, required this.value, required this.onTap});
  final bool selected;
  final String label;
  final String desc;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: T.sans(12.5, weight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(desc, style: T.hint),
    ]);
    final shown = Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11, color: C.soft));
    final radius = BorderRadius.circular(8);

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: C.w(.04),
          splashColor: Colors.transparent,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10 + touchPad(context) / 4),
            decoration: BoxDecoration(
              color: selected ? C.w(.04) : null,
              border: Border.all(color: selected ? C.w(.18) : C.line),
              borderRadius: radius,
            ),
            child: LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 420;
              return Row(crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
                Padding(padding: EdgeInsets.only(top: narrow ? 1 : 0), child: RadioDot(selected)),
                const SizedBox(width: 12),
                Expanded(
                  child: narrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [text, const SizedBox(height: 4), shown],
                        )
                      : text,
                ),
                if (!narrow) ...[
                  const SizedBox(width: 12),
                  // Takes what it needs and leaves the rest to the description.
                  ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * .45), child: shown),
                ],
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _ScriptPanel extends StatelessWidget {
  const _ScriptPanel(this.lines, {required this.scroll});
  final List<ScriptLine> lines;

  /// Keeps a long script inside the window when it sits beside the form.
  final bool scroll;

  static Color _color(ScriptLineKind kind) => switch (kind) {
        ScriptLineKind.comment => C.dim,
        ScriptLineKind.emph => C.fg,
        ScriptLineKind.warn => Tone.warn.color,
        ScriptLineKind.cmd || ScriptLineKind.blank => C.soft,
      };

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 14, vertical: 12);
    final script = SelectableText.rich(
      TextSpan(children: [
        for (final (i, l) in lines.indexed)
          TextSpan(text: i == lines.length - 1 ? l.text : '${l.text}\n', style: TextStyle(color: _color(l.kind))),
      ]),
      style: T.mono(11, height: 1.75),
    );
    return Panel(
      color: C.term,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: C.card, border: Border(bottom: BorderSide(color: C.line))),
          child: Row(children: [
            Expanded(child: Text('Generated script', style: T.sans(12.5, weight: FontWeight.w600))),
            Text('install-dokku.sh', style: T.meta),
          ]),
        ),
        if (scroll)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
            child: SingleChildScrollView(padding: padding, child: script),
          )
        else
          Padding(padding: padding, child: script),
      ]),
    );
  }
}
