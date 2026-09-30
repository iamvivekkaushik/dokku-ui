import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/parse.dart';
import '../../core/templates.dart';
import '../../data/models.dart';
import '../../state/core.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../../state/router.dart';
import '../actions.dart';
import '../widgets/kit.dart';

const _needsRoot = 'Installing plugins needs root. Connect as root or as a user with sudo.';
final _lowercase = [FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]'))];

Future<void> _openLink(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on Object {
    // Nothing to hand the link to.
  }
}

/// Runs [plan] step by step as jobs and stops at the first failure. Takes
/// what it needs from [ref] before the first await, so the screen may go.
Future<ExecResult?> installTemplate(WidgetRef ref, Host host, InstallPlan plan) async {
  final run = DokkuRunner(ref, host);
  final ssh = ref.read(sshServiceProvider);
  final title = 'Install ${plan.template.name}';
  ExecResult? last;
  for (final step in plan.steps) {
    last = step is HostStep
        ? await run.shell(step.args, title: title, timeout: step.timeout, quiet: step.quiet)
        : await run(step.args, title: title, timeout: step.timeout, quiet: step.quiet);
    if (!last.ok) {
      if (step.quiet) continue;
      return last;
    }
    if (step is LinkStep && step.service.env.isNotEmpty) {
      // Read without a job: the URL carries the password, and the dock shows output.
      var got = await ssh.dokku(host, ['config:get', plan.app, step.service.from]);
      if (!got.ok) got = await run(['config:get', plan.app, step.service.from], title: title);
      if (!got.ok) return got;
      last = await run(configSetArgs(plan.app, step.derive(got.stdout)), title: title);
      if (!last.ok) return last;
    }
  }
  return last;
}

/// Templates for well-known apps, each installed with ordinary Dokku commands.
class StoreScreen extends ConsumerStatefulWidget {
  const StoreScreen({super.key, required this.host});
  final Host host;

  @override
  ConsumerState<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends ConsumerState<StoreScreen> with Busy {
  final _filter = TextEditingController();

  /// Empty means every category.
  String _category = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _install(AppTemplate t) async {
    final host = widget.host;
    final plan = await showAppDialog<InstallPlan>(context, (_) => InstallDialog(host: host, template: t));
    if (plan == null || !mounted) return;
    // The install outlives this screen; so do these two.
    final navigator = Navigator.of(context, rootNavigator: true);
    final router = ref.read(routerProvider.notifier);
    final r = await busy(t.id, () => installTemplate(ref, host, plan));
    if (r?.ok != true) return;
    router.go(AppDetailRoute(plan.app));
    if (navigator.mounted) unawaited(showAppDialog<void>(navigator.context, (_) => _DoneDialog(plan)));
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final ds = ref.watch(datastoresProvider(host.id));
    final plugins = {for (final p in ds.value?.plugins ?? <PluginInfo>[]) if (p.enabled) p.name};
    final q = _filter.text.trim().toLowerCase();
    final categories = templateCategories();
    final list = [
      for (final t in templates)
        if ((_category.isEmpty || t.category == _category) && (q.isEmpty || '${t.name} ${t.category} ${t.tagline}'.toLowerCase().contains(q))) t,
    ];
    final compact = Bp.isCompact(context);

    return PageBody(children: [
      PageHead(eyebrow: host.name, title: 'Store', actions: [
        SizedBox(
          width: compact ? 170 : 220,
          child: AppInput(controller: _filter, large: true, mono: false, hint: 'Filter templates', onChanged: (_) => setState(() {})),
        ),
      ]),
      Text(
        'Each template creates an app from its official image, with storage, config and datastores set up the Dokku way. '
        'Every command is shown before it runs, and afterwards the app is yours to change like any other.',
        style: T.small,
      ),
      Seg<String>(
        value: _category,
        options: ['', ...categories.keys],
        labels: (c) => c.isEmpty ? 'All · ${templates.length}' : '$c · ${categories[c]}',
        small: true,
        onChanged: (c) => setState(() => _category = c),
      ),
      if (list.isEmpty) EmptyBox(q.isEmpty ? 'No templates in $_category.' : 'No templates match “$q”.', margin: EdgeInsets.zero),
      if (list.isNotEmpty)
        AutoGrid(minWidth: 280, children: [
          for (final t in list)
            _TemplateCard(
              t,
              plugins: plugins,
              shell: host.hasShell,
              loading: ds.isLoading && !ds.hasValue,
              installing: isBusy(t.id),
              onInstall: () => _install(t),
              onDocs: () => _openLink(t.homepage),
            ),
        ]),
    ]);
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard(this.t,
      {required this.plugins, required this.shell, required this.loading, required this.installing, required this.onInstall, required this.onDocs});
  final AppTemplate t;
  final Set<String> plugins;

  /// Whether the login can run commands on the host itself.
  final bool shell;
  final bool loading;
  final bool installing;
  final VoidCallback onInstall;
  final VoidCallback onDocs;

  @override
  Widget build(BuildContext context) {
    final hue = Color(t.hue);
    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: hue.withValues(alpha: .12), borderRadius: BorderRadius.circular(7)),
            child: Text(t.glyph, style: T.mono(11, color: hue, weight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.category.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: T.mono(10, color: C.dim, spacing: .4)),
          ),
        ]),
        const SizedBox(height: 10),
        Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(13.5, weight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(t.tagline, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.sans(12, color: C.muted, height: 1.4)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (t.mounts.isNotEmpty) const Pill('storage', tone: Tone.mute, dot: false, mono: true),
          if (t.publish.isNotEmpty) const Pill('host ports', tone: Tone.mute, dot: false, mono: true),
          if (needsChown(t))
            Tooltip(
              message: 'Its storage is handed to the uid the image runs as, with chown on the host'
                  '${shell ? '.' : ', which needs root. Connect as root or as a user with sudo.'}',
              child: Pill('needs root', tone: shell ? Tone.mute : Tone.warn, dot: false, mono: true),
            ),
          for (final s in t.services) _need(s),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Btn('Install',
                key: ValueKey('install-${t.id}'), variant: BtnVariant.outline, loading: installing, onPressed: loading ? null : onInstall),
          ),
          const SizedBox(width: 6),
          IconBtn(LucideIcons.externalLink, tooltip: 'Documentation', onPressed: onDocs),
        ]),
      ]),
    );
  }

  Widget _need(TemplateService s) {
    final has = plugins.contains(s.type) || loading;
    final pill = Pill(s.required ? s.type : '${s.type} · optional', tone: has || !s.required ? Tone.mute : Tone.warn, dot: false, mono: true);
    if (has) return pill;
    return Tooltip(
      message: 'The ${s.type} plugin is not installed${s.required ? '' : ', and it is optional'}. '
          'The install dialog can add it, or take the URL of one running elsewhere.',
      child: pill,
    );
  }
}

/// Everything the user decides before a template is installed. Pops with the
/// plan, or with null.
class InstallDialog extends ConsumerStatefulWidget {
  const InstallDialog({super.key, required this.host, required this.template});
  final Host host;
  final AppTemplate template;

  @override
  ConsumerState<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends ConsumerState<InstallDialog> with Busy {
  late InstallChoices _c = defaultChoices(widget.template);
  late final _name = TextEditingController(text: _c.app);
  final _domain = TextEditingController();
  final _email = TextEditingController();
  final _memory = TextEditingController();
  late final _settings = {for (final s in widget.template.settings) s.id: TextEditingController(text: s.value)};
  late final _urls = {for (final s in widget.template.services) s.type: TextEditingController()};

  @override
  void dispose() {
    for (final c in [_name, _domain, _email, _memory, ..._settings.values, ..._urls.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(InstallChoices c) => setState(() => _c = c);

  void _setting(String id, String value) => _set(_c.copyWith(settings: {..._c.settings, id: value}));

  void _url(String type, String value) => _set(_c.copyWith(urls: {..._c.urls, type: value}));

  Future<void> _installPlugin(String type) async {
    final d = datastoreOf(type);
    if (d == null) return;
    await busy(
      'plugin-$type',
      () => runDokku(context, ref, widget.host, ['plugin:install', d.repo, '--name', d.type],
          title: 'Install ${d.name} plugin', timeout: const Duration(minutes: 15)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template, host = widget.host;
    final state = ref.watch(datastoresProvider(host.id)).value;
    final plugins = {for (final p in state?.plugins ?? <PluginInfo>[]) if (p.enabled) p.name};
    final apps = ref.watch(appsProvider(host.id)).value;
    final names = apps?.names ?? const <String>[];
    final vhost = apps?.globalVhosts.firstOrNull ?? host.host;
    final defaultDomain = '${_c.app}.$vhost';
    final plan = planInstall(t, _c, defaultDomain: defaultDomain);
    final problems = installProblems(t, _c, plugins: plugins, apps: names, shell: host.hasShell);
    final exists = names.contains(_c.app);
    final hasLe = plugins.contains('letsencrypt');
    final custom = _c.domain.trim();

    return AppDialog(
      title: 'Install ${t.name}',
      subtitle: t.tagline,
      width: 560,
      gap: 16,
      leading: problems.isEmpty
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(problems.first, maxLines: 3, overflow: TextOverflow.ellipsis, style: T.sans(11.5, color: Tone.warn.color, height: 1.4)),
            ),
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Install ${t.name}',
            size: BtnSize.md,
            variant: BtnVariant.primary,
            tooltip: problems.firstOrNull,
            onPressed: problems.isEmpty ? () => Navigator.of(context).pop(plan) : null),
      ],
      children: [
        Text(t.description, style: T.sans(12.5, color: C.muted, height: 1.5)),
        Field(
          'App name',
          hint: exists ? 'An app with this name already exists.' : 'Also the git remote and the default subdomain.',
          hintTone: exists ? Tone.bad : null,
          child: AppInput(controller: _name, large: true, inputFormatters: _lowercase, onChanged: (v) => _set(_c.copyWith(app: v))),
        ),
        if (t.tags.length > 1)
          Field(
            'Version',
            hint: '${t.image}:${_c.tag}',
            child: AppSelect<String>(value: _c.tag, options: t.tags, onChanged: (v) => _set(_c.copyWith(tag: v))),
          ),
        Field(
          'Domain',
          hint: custom.isEmpty
              ? 'Empty means $defaultDomain.${t.proxy ? '' : ' Clients connect to this name.'}'
              : 'DNS for $custom has to point at ${host.host}.',
          child: AppInput(
              controller: _domain, large: true, mono: false, hint: '${t.id}.example.com', onChanged: (v) => _set(_c.copyWith(domain: v))),
        ),
        if (t.mounts.isNotEmpty)
          _Section('Storage', [
            for (final m in t.mounts)
              SwitchRow(
                title: 'Keep ${m.what} on the host',
                desc: _c.mounts.contains(m.name)
                    ? '$storageRoot/${_c.app}-${m.name} → ${m.path}${m.uid == null ? '' : ', handed to uid ${m.uid} with chown'}'
                    : 'Without it, ${m.what} are lost on every deploy.',
                value: _c.mounts.contains(m.name),
                onChanged: (on) => _set(_c.copyWith(mounts: on ? <String>{..._c.mounts, m.name} : (<String>{..._c.mounts}..remove(m.name)))),
              ),
          ]),
        if (t.services.isNotEmpty) _Section('Datastores', [for (final s in t.services) ..._service(s, plugins)]),
        if (t.proxy)
          _Section('HTTPS', [
          SwitchRow(
            title: "Let's Encrypt certificate",
            desc: hasLe
                ? 'Issued after the deploy; the domain has to resolve to this host by then.'
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
        if (t.settings.isNotEmpty)
          _Section('Settings', [
            for (final s in t.settings)
              Field(
                s.label,
                hint: s.hint.isEmpty ? null : s.hint,
                child: s.choices.isNotEmpty
                    ? AppSelect<String>(value: _c.settings[s.id] ?? s.value, options: s.choices, onChanged: (v) => _setting(s.id, v))
                    : AppInput(controller: _settings[s.id], large: true, onChanged: (v) => _setting(s.id, v)),
              ),
          ]),
        Field(
          'Memory limit',
          hint: 'Set with resource:limit; empty means none.',
          child: AppInput(controller: _memory, large: true, hint: '512m', onChanged: (v) => _set(_c.copyWith(memory: v))),
        ),
        Field(
          'Runs',
          hint: 'Config values are sent base64-encoded. Secrets are generated on this device and hidden here.',
          child: CodeBlock(describePlan(plan), maxHeight: 240, wrap: false),
        ),
      ],
    );
  }

  /// A datastore is provisioned with its plugin or, given a URL, taken from
  /// wherever one runs; only the first needs the plugin.
  List<Widget> _service(TemplateService s, Set<String> plugins) {
    final def = datastoreOf(s.type);
    final name = def?.name ?? s.type;
    final has = plugins.contains(s.type);
    final on = _c.services.contains(s.type);
    final url = _c.urlOf(s.type);
    final valid = looksLikeServiceUrl(url);
    final example = serviceUrlExample(s.type);
    final why = s.why.isEmpty ? '' : ' ${s.why}';
    final root = widget.host.hasShell;
    return [
      SwitchRow(
        title: s.required ? '$name, required' : name,
        desc: on && url.isNotEmpty
            ? 'Nothing is provisioned: ${s.from} is set from the URL below.'
            : has
                ? '${s.type}:create ${_c.app}-${s.suffix}, linked as ${s.from}.$why'
                : 'The ${s.type} plugin is not installed. Install it, or give the URL of one running elsewhere.$why',
        value: on,
        onChanged: s.required
            ? null
            : (v) => _set(_c.copyWith(services: v ? <String>{..._c.services, s.type} : (<String>{..._c.services}..remove(s.type)))),
      ),
      if (on)
        Field(
          '$name URL',
          hint: url.isEmpty
              ? 'Empty means a new service on this host. Or the URL of one running elsewhere, reachable from this host.'
              : valid
                  ? 'Set as ${s.from} before the deploy; the preview hides it.'
                  : 'That needs a scheme and a host, like $example.',
          hintTone: url.isNotEmpty && !valid ? Tone.bad : null,
          child: AppInput(controller: _urls[s.type], large: true, hint: example, onChanged: (v) => _url(s.type, v)),
        ),
      if (on && url.isEmpty && !has && def != null)
        Row(children: [
          Expanded(child: Text(root ? 'plugin:install ${def.repo}' : _needsRoot, style: T.hint)),
          const SizedBox(width: 8),
          Btn('Install plugin',
              loading: isBusy('plugin-${s.type}'), tooltip: root ? null : _needsRoot, onPressed: root ? () => _installPlugin(s.type) : null),
        ]),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: T.sans(12, weight: FontWeight.w600)),
        for (final c in children) ...[const SizedBox(height: 10), c],
      ]);
}

class _DoneDialog extends StatelessWidget {
  const _DoneDialog(this.plan);
  final InstallPlan plan;

  @override
  Widget build(BuildContext context) => AppDialog(
        title: '${plan.template.name} is up',
        subtitle: plan.url,
        width: 460,
        actions: [
          Btn('Close', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          Btn('Open ${plan.template.name}',
              size: BtnSize.md, variant: BtnVariant.primary, icon: LucideIcons.externalLink, onPressed: () => _openLink(plan.url)),
        ],
        children: [
          Text(plan.notes, style: T.sans(12.5, color: C.soft, height: 1.5)),
          Text('It is the app ${plan.app} now: settings, logs and storage are in Apps like for any other.', style: T.small),
        ],
      );
}
