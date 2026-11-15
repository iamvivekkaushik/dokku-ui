import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/compose.dart';
import '../../core/parse.dart';
import '../../data/models.dart';
import '../../data/platform.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../widgets/kit.dart';

final _lowercase = [FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]'))];
final _proxyType = RegExp(r'Proxy global type:\s*(\S+)');

Future<void> _openLink(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on Object {
    // Nothing to hand the link to.
  }
}

/// A compose file, read, and the name of the file it came from, or null
/// when it was pasted.
typedef ComposeInput = ({String? name, ComposeSource source});

/// Takes a compose file, pasted or picked. Pops with it read, or with null.
class ComposeSourceDialog extends StatefulWidget {
  const ComposeSourceDialog({super.key});

  @override
  State<ComposeSourceDialog> createState() => _ComposeSourceDialogState();
}

class _ComposeSourceDialogState extends State<ComposeSourceDialog> {
  final _text = TextEditingController();
  String? _file;
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _problem = null);
    try {
      final file = await pickTextFile();
      if (file == null || !mounted) return;
      setState(() {
        _file = file.name;
        _text.text = file.text;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'Could not read that file. ${e is FormatException ? e.message : e}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text.text;
    ComposeSource? source;
    String? error;
    if (text.trim().isNotEmpty) {
      try {
        source = ComposeSource.parse(text);
      } on FormatException catch (e) {
        error = e.message;
      }
    }
    final services = source?.resolve().services ?? const <ComposeService>[];
    return AppDialog(
      title: 'Deploy a compose file',
      subtitle: _file ?? 'docker-compose.yml or compose.yaml',
      width: 600,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Continue',
            size: BtnSize.md,
            variant: BtnVariant.primary,
            onPressed: source == null ? null : () => Navigator.of(context).pop<ComposeInput>((name: _file, source: source!))),
      ],
      children: [
        Text(
          'Each service becomes an app deployed from its image. You choose what goes on the web, '
          'what is kept between deploys and how its variables are set, and see every command before it runs.',
          style: T.sans(12.5, color: C.muted, height: 1.5),
        ),
        AppInput(
          controller: _text,
          maxLines: 16,
          minLines: 10,
          hint: 'services:\n  web:\n    image: nginx:alpine\n    ports: ["8080:80"]',
          onChanged: (_) => setState(() => _file = null),
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(
              _problem ??
                  error ??
                  (services.isEmpty
                      ? 'Paste it here, or open the file.'
                      : '${services.length == 1 ? '1 service' : '${services.length} services'}: ${services.map((s) => s.name).join(', ')}.'),
              style: _problem != null || error != null ? T.sans(11.5, color: Tone.bad.color) : T.hint,
            ),
          ),
          const SizedBox(width: 12),
          Btn('Open file', icon: LucideIcons.folderOpen, onPressed: _open),
        ]),
      ],
    );
  }
}

/// Everything the user decides before a compose file is deployed. Pops with
/// the plan, or with null.
class ComposeDialog extends ConsumerStatefulWidget {
  const ComposeDialog({super.key, required this.host, required this.input});
  final Host host;
  final ComposeInput input;

  @override
  ConsumerState<ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends ConsumerState<ComposeDialog> {
  late ComposeChoices _c = defaultComposeChoices(widget.input.source);
  late final _project = TextEditingController(text: _c.project);
  final _dotenv = TextEditingController();
  final _email = TextEditingController();

  /// Made as they are needed: which ones depends on the services chosen.
  final _vars = <String, TextEditingController>{};
  final _files = <String, TextEditingController>{};
  final _domains = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in [_project, _dotenv, _email, ..._vars.values, ..._files.values, ..._domains.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(ComposeChoices c) => setState(() => _c = c);

  TextEditingController _field(Map<String, TextEditingController> map, String key) => map[key] ??= TextEditingController();

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final state = ref.watch(datastoresProvider(host.id)).value;
    final plugins = {for (final p in state?.plugins ?? <PluginInfo>[]) if (p.enabled) p.name};
    final apps = ref.watch(appsProvider(host.id)).value;
    final vhost = apps?.globalVhosts.firstOrNull ?? host.host;
    final proxy = ref.dokku(host, const ['proxy:report'], (r) => _proxyType.firstMatch(stripAnsi(r.stdout))?[1] ?? '', lenient: true).data ?? '';
    final file = widget.input.source.resolve(_c.effective);
    final plan = planCompose(file, _c, vhost: vhost);
    final problems = composeProblems(file, _c, plugins: plugins, apps: apps?.names ?? const []);
    final project = _c.project.trim();
    final variables = file.variablesOf(_c.services);
    final envFiles = file.envFilesOf(_c.services);
    final web = plan.apps.any((a) => a.exposure == Exposure.web);
    final hasLe = plugins.contains('letsencrypt');
    final count = plan.apps.length;

    return AppDialog(
      title: 'Deploy ${widget.input.name ?? 'a compose file'}',
      subtitle: '${file.services.length == 1 ? '1 service' : '${file.services.length} services'}${widget.input.name == null ? ', pasted' : ''}',
      width: 600,
      gap: 16,
      leading: problems.isEmpty
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(problems.first, maxLines: 3, overflow: TextOverflow.ellipsis, style: T.sans(11.5, color: Tone.warn.color, height: 1.4)),
            ),
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn(count == 1 ? 'Deploy 1 app' : 'Deploy $count apps',
            size: BtnSize.md,
            variant: BtnVariant.primary,
            tooltip: problems.firstOrNull,
            onPressed: problems.isEmpty ? () => Navigator.of(context).pop(plan) : null),
      ],
      children: [
        Text(
          'Each service becomes an app on the network $project, where the others reach it by its service name, as under Compose. '
          'Named volumes stay Docker volumes, and the environment is set as config.',
          style: T.sans(12.5, color: C.muted, height: 1.5),
        ),
        Field(
          'Project',
          hint: 'Apps are named $project-<service>, and the service named $project is the app $project.',
          child: AppInput(controller: _project, large: true, inputFormatters: _lowercase, onChanged: (v) => _set(_c.copyWith(project: v))),
        ),
        _Section('Services', [
          for (final s in file.services) _service(file, s, plan.apps.where((a) => a.service.name == s.name).firstOrNull, vhost, proxy),
        ]),
        if (variables.isNotEmpty || envFiles.isNotEmpty)
          _Section('Variables', [
            Field(
              '.env',
              hint: 'The .env beside the compose file, which Compose reads for these variables'
                  '${envFiles.keys.any(isDotenv) ? ', and the env_file of ${envFiles.entries.where((e) => isDotenv(e.key)).expand((e) => e.value).join(', ')}' : ''}.'
                  ' Fields below win over it.',
              child: AppInput(controller: _dotenv, maxLines: 8, minLines: 3, hint: 'KEY=value, one per line', onChanged: (v) => _set(_c.copyWith(dotenv: v))),
            ),
            for (final v in variables.values) _variable(v),
            for (final e in envFiles.entries)
              if (!isDotenv(e.key))
                Field(
                  'env_file ${e.key}',
                  hint: 'Read by ${e.value.join(', ')}. It is not on the server: paste what it holds.',
                  child: AppInput(
                      controller: _field(_files, e.key),
                      maxLines: 8,
                      minLines: 3,
                      hint: 'KEY=value, one per line',
                      onChanged: (v) => _set(_c.copyWith(envFiles: {..._c.envFiles, e.key: v}))),
                ),
          ]),
        if (web)
          _Section('HTTPS', [
            SwitchRow(
              title: "Let's Encrypt certificates",
              desc: hasLe
                  ? 'Issued after each deploy, for every service on the web; their domains have to resolve to this host by then.'
                  : 'Install the letsencrypt plugin on the Server page first.',
              value: _c.letsencrypt,
              onChanged: hasLe ? (on) => _set(_c.copyWith(letsencrypt: on)) : null,
            ),
            if (_c.letsencrypt)
              Field(
                "Email for Let's Encrypt",
                hint: 'Expiry notices go there.',
                child: AppInput(
                    controller: _email,
                    large: true,
                    mono: false,
                    hint: 'you@example.com',
                    keyboardType: TextInputType.emailAddress,
                    onChanged: (v) => _set(_c.copyWith(email: v))),
              ),
          ]),
        if (file.leftOut.isNotEmpty)
          Text('Not carried over: ${file.leftOut.join(', ')}. Compose mounts these as files; put them in storage or config by hand.', style: T.hint),
        Field(
          'Runs',
          hint: 'Config values are sent base64-encoded. Passwords, keys and URLs are hidden here.',
          child: CodeBlock(describeComposePlan(plan), maxHeight: 280, wrap: false),
        ),
      ],
    );
  }

  /// [proxy] is the host's proxy type: one other than nginx runs in a
  /// container of its own, off the project's network.
  Widget _service(ComposeFile file, ComposeService s, ComposeApp? a, String vhost, String proxy) {
    final on = _c.services.contains(s.name);
    final project = _c.project.trim();
    final app = composeAppName(project, s.name);
    final image = s.deployable ? s.imageRef : 'an image named by variables';
    final String desc;
    if (!s.hasImage) {
      desc = s.build
          ? 'Built from source by Compose, which the server cannot do from this file. Push the image to a registry and name it in image.'
          : 'It names no image.';
    } else if (on) {
      desc = 'The app $app, from $image.${s.build ? ' Compose builds it too: the image has to be in a registry.' : ''}';
    } else if (s.bundledProxy) {
      desc = "$image, a reverse proxy of its own, left out: Dokku's proxy does its job. Put the services behind it on the web.";
    } else {
      desc = '$image, not deployed${s.profiles.isEmpty ? '' : ': in the profile ${s.profiles.join(', ')}'}.';
    }
    final missing = [for (final d in s.dependsOn) if (file.service(d) != null && !_c.services.contains(d)) d];
    final anonymous = [for (final m in s.mounts) if (m.kind == MountKind.anonymous) m.target];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SwitchRow(
        title: s.name,
        desc: desc,
        value: on,
        onChanged: s.hasImage
            ? (v) => _set(_c.copyWith(services: v ? <String>{..._c.services, s.name} : (<String>{..._c.services}..remove(s.name))))
            : null,
      ),
      if (on && a != null)
        Container(
          margin: const EdgeInsets.only(top: 10, left: 2),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: C.lineStrong))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Seg<Exposure>(
              value: a.exposure,
              options: Exposure.values,
              labels: (e) => e.label,
              small: true,
              onChanged: (e) => _set(_c.copyWith(exposure: {..._c.exposure, s.name: e})),
            ),
            const SizedBox(height: 6),
            Text(_exposureText(s, a, project), style: T.hint),
            if (a.exposure == Exposure.web && proxy.isNotEmpty && proxy != 'nginx') ...[
              const SizedBox(height: 6),
              Text(
                "This host's proxy is $proxy, which runs in a container of its own and may not reach an app on the network $project. "
                "Dokku's default, nginx, runs on the host and does.",
                style: T.sans(11.5, color: Tone.warn.color),
              ),
            ],
            if (a.exposure == Exposure.web && s.httpPorts.length > 1) ...[
              const SizedBox(height: 10),
              Field(
                'HTTP port',
                hint: 'The container port the proxy sends requests to.',
                child: AppSelect<int>(
                    value: a.port, options: s.httpPorts, labels: (p) => '$p', onChanged: (p) => _set(_c.copyWith(ports: {..._c.ports, s.name: p}))),
              ),
            ],
            if (a.exposure == Exposure.web) ...[
              const SizedBox(height: 10),
              Field(
                'Domain',
                hint: (_c.domains[s.name] ?? '').trim().isEmpty ? 'Empty means $app.$vhost.' : 'DNS for it has to point at ${widget.host.host}.',
                child: AppInput(
                    controller: _field(_domains, s.name),
                    large: true,
                    mono: false,
                    hint: '$app.example.com',
                    onChanged: (v) => _set(_c.copyWith(domains: {..._c.domains, s.name: v}))),
              ),
            ],
            for (final m in s.mounts)
              if (m.kind != MountKind.anonymous) ...[const SizedBox(height: 10), _mount(file, m)],
            if (anonymous.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Left out: the anonymous ${anonymous.length == 1 ? 'volume' : 'volumes'} ${anonymous.join(', ')}, which Compose recreates too.',
                  style: T.hint),
            ],
            if (s.leftOut.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Not carried over: ${s.leftOut.join(', ')}.', style: T.hint),
            ],
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('It depends on ${missing.join(', ')}, which ${missing.length == 1 ? 'is' : 'are'} not deployed here.',
                  style: T.sans(11.5, color: Tone.warn.color)),
            ],
          ]),
        ),
    ]);
  }

  String _exposureText(ComposeService s, ComposeApp a, String project) {
    final published = a.published.map((p) => p.publish).join(', ');
    final also = a.published.isEmpty ? '' : ' $published ${a.published.length == 1 ? 'is' : 'are'} published on the host directly.';
    return switch (a.exposure) {
      Exposure.web => '${a.domain} goes through the proxy to ${a.port == null ? 'the port the image exposes' : 'port ${a.port}'}.$also',
      Exposure.host => a.published.isEmpty
          ? 'It publishes no ports, so nothing outside reaches it.'
          : '$published ${a.published.length == 1 ? 'is' : 'are'} published on the host directly, without the proxy.',
      Exposure.internal => 'Only the other services reach it, as ${s.name}${s.httpPorts.isEmpty ? '' : ':${s.httpPorts.first}'} on the network $project.'
          '${s.ports.isEmpty ? '' : ' The file publishes ${s.ports.map((p) => p.publish).join(', ')}; Host ports would too.'}',
    };
  }

  Widget _mount(ComposeFile file, ComposeMount m) {
    final project = _c.project.trim();
    final on = _c.mounts.contains(m.id);
    final where = composeMountSource(file, project, m);
    final title = '${m.kind == MountKind.volume ? 'Volume ' : ''}${m.source} → ${m.target}${m.readOnly ? ' (read-only)' : ''}';
    final lost = 'Without it, what ${m.target} holds is lost on every deploy.';
    final desc = !m.usable
        ? 'Dokku cannot mount a path with spaces or quotes in it.'
        : switch (m.kind) {
            MountKind.volume => on ? 'The Docker volume $where.' : lost,
            MountKind.host => on ? 'A path on the host, mounted as it is.' : 'A path on the host, left out.',
            _ when m.file => on
                ? 'A file beside the compose file: copy it to $where on the host before the deploy.'
                : 'A file beside the compose file, left out. Copy it to $where on the host to use it.',
            _ when m.root => 'The project itself, usually source code for development; the image has its own.',
            _ => on
                ? 'Beside the compose file, so not on the server: the storage directory $where takes its place.'
                : m.readOnly
                    ? 'Read-only beside the compose file: copy what it holds to $where on the host to use it.'
                    : lost,
          };
    return SwitchRow(
      title: title,
      desc: desc,
      value: on && m.usable,
      onChanged: m.usable ? (v) => _set(_c.copyWith(mounts: v ? <String>{..._c.mounts, m.id} : (<String>{..._c.mounts}..remove(m.id)))) : null,
    );
  }

  Widget _variable(ComposeVariable v) {
    final typed = (_c.values[v.name] ?? '').isNotEmpty;
    final fromDotenv = parseEnvFile(_c.dotenv).any((e) => e.key == v.name);
    final String hint;
    if (typed) {
      hint = 'Typed here, which wins over the .env.';
    } else if (fromDotenv) {
      hint = 'From the .env.';
    } else if (_c.generated.containsKey(v.name)) {
      hint = 'A random value generated on this device. Type one to use it instead.';
    } else if (v.fallback != null) {
      hint = 'Empty means ${v.fallback!.isEmpty ? 'an empty value' : v.fallback}.';
    } else if (v.required) {
      hint = v.message.isEmpty ? 'Required.' : 'Required: ${v.message}';
    } else if (v.fromShell) {
      hint = 'Compose takes it from the shell. Empty leaves it out.';
    } else {
      hint = 'Not set: Compose would put in an empty value.';
    }
    return Field(
      v.name,
      hint: hint,
      hintTone: v.required && !typed && !fromDotenv && !_c.generated.containsKey(v.name) ? Tone.warn : null,
      child: AppInput(
          controller: _field(_vars, v.name),
          large: true,
          hint: _c.generated.containsKey(v.name) && !fromDotenv ? 'random' : v.fallback ?? '',
          onChanged: (value) => _set(_c.copyWith(values: {..._c.values, v.name: value}))),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: T.sans(12, weight: FontWeight.w600)),
        for (final c in children) ...[const SizedBox(height: 12), c],
      ]);
}

/// What was deployed, and where each service answers.
class ComposeDoneDialog extends StatelessWidget {
  const ComposeDoneDialog(this.plan, {super.key});
  final ComposePlan plan;

  @override
  Widget build(BuildContext context) => AppDialog(
        title: '${plan.project} is up',
        subtitle: '${plan.apps.length == 1 ? '1 app' : '${plan.apps.length} apps'} on the network ${plan.project}',
        width: 500,
        actions: [Btn('Close', size: BtnSize.md, variant: BtnVariant.primary, onPressed: () => Navigator.of(context).pop())],
        children: [
          for (final a in plan.apps)
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(a.app, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12.5)),
                  const SizedBox(height: 2),
                  Text(
                    switch (a.exposure) {
                      Exposure.web => a.url,
                      Exposure.host => 'Host ports ${a.published.map((p) => p.publish).join(', ')}',
                      Exposure.internal => '${a.service.name} on the network',
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.hint,
                  ),
                ]),
              ),
              if (a.exposure == Exposure.web) IconBtn(LucideIcons.externalLink, tooltip: 'Open ${a.url}', onPressed: () => _openLink(a.url)),
            ]),
          Text('Each is an app now: settings, logs and storage are in Apps like for any other.', style: T.small),
        ],
      );
}
