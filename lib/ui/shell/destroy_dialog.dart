import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/command.dart';
import '../../core/parse.dart';
import '../../data/models.dart';
import '../../state/datastores.dart';
import '../../state/queries.dart';
import '../actions.dart';
import '../widgets/kit.dart';

List<String> destroyAppArgs(String app) => ['--force', 'apps:destroy', app];

/// Shows what destroying [app] removes and, once its name is typed, destroys it.
///
/// Returns the result of the command, or null if the user backed out.
Future<ExecResult?> destroyApp(BuildContext context, WidgetRef ref, Host host, String app) async {
  // Taken first: the screen that asked may be gone by the time the name is typed.
  final run = DokkuRunner(ref, host);
  final agreed = await showAppDialog<bool>(context, (_) => DestroyAppDialog(host: host, app: app)) ?? false;
  if (!agreed) return null;
  return run(destroyAppArgs(app), title: 'Destroy $app', timeout: const Duration(minutes: 10));
}

String _plural(int n, String one, [String? many]) => n == 1 ? '1 $one' : '$n ${many ?? '${one}s'}';

/// How many variables the user set, or null when that could not be read.
int? _configCount(ExecResult r) {
  if (!r.ok) return null;
  try {
    final vars = jsonDecode(r.stdout.trim().isEmpty ? '{}' : r.stdout.trim()) as Map<String, dynamic>;
    return vars.keys.where((k) => !dokkuConfigKeys.contains(k)).length;
  } on Object {
    return null;
  }
}

class DestroyAppDialog extends ConsumerStatefulWidget {
  const DestroyAppDialog({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  ConsumerState<DestroyAppDialog> createState() => _DestroyAppDialogState();
}

class _DestroyAppDialogState extends ConsumerState<DestroyAppDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host, app = widget.app;
    final ps = ref.report(host, 'ps', app);
    final git = ref.report(host, 'git', app);
    final domains = ref.report(host, 'domains', app);
    final certs = ref.report(host, 'certs', app);
    final config = ref.dokku(host, ['config:export', '--format', 'json', app], _configCount, lenient: true);
    final mounts = ref.dokku(host, ['storage:list', app, '--format', 'json'],
        (r) => r.ok ? parseStorage(r.stdout) : const <Mount>[], lenient: true);
    final services = ref.watch(datastoresProvider(host.id));

    final links = [
      for (final s in services.value?.services ?? const <Service>[])
        if (s.links.contains(app)) s.name,
    ];
    final procs = ps.data == null ? const <ProcStatus>[] : procStatuses(ps.data!);
    final image = git.data?['git source image'] ?? '';
    final names = words(domains.data?['domains app vhosts']);
    final paths = {for (final m in mounts.data ?? const <Mount>[]) m.host}.toList();

    // Each line is left out while it is unknown, rather than guessed at.
    final effects = [
      if (ps.data != null)
        procs.isEmpty
            ? 'no containers'
            : '${_plural(procs.length, 'container')}${image.isEmpty ? '' : ' · image $image'}',
      if (config.data != null) _plural(config.data!, 'config var'),
      if (domains.data != null)
        names.isEmpty ? 'no domains' : '${names.join(', ')}${isYes(certs.data?['ssl enabled']) ? ' + TLS certificate' : ''}',
      if (services.hasValue) links.isEmpty ? 'no linked services' : 'unlink ${links.join(', ')}',
    ];
    final loading = ps.loading || config.loading || domains.loading || (services.isLoading && !services.hasValue);
    final ok = _typed.text == app;

    return AppDialog(
      title: 'Destroy $app',
      width: 460,
      danger: true,
      header: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
        decoration: BoxDecoration(color: Tone.bad.fill, border: Border(bottom: BorderSide(color: Tone.bad.border))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.trash2, size: 18, color: C.bad)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Destroy $app',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(14, weight: FontWeight.w600, color: C.bad)),
              const SizedBox(height: 2),
              Text('This cannot be undone.', style: T.sans(12, color: C.bad.withValues(alpha: .8))),
            ]),
          ),
        ]),
      ),
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop(false)),
        Btn('Destroy app',
            size: BtnSize.md,
            variant: BtnVariant.destructive,
            onPressed: ok ? () => Navigator.of(context).pop(true) : null),
      ],
      children: [
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'Removes all containers and images, config vars, domains and certificates'),
            if (links.isNotEmpty) ...[
              const TextSpan(text: ', and unlinks '),
              TextSpan(text: _plural(links.length, 'datastore service'), style: const TextStyle(color: C.fg)),
            ],
            const TextSpan(text: '. Persistent storage on the host is kept'),
            if (paths.isNotEmpty) ...[
              const TextSpan(text: ': '),
              TextSpan(text: paths.join(', '), style: T.mono(11.5, color: C.soft)),
            ],
            const TextSpan(text: '.'),
          ]),
          style: T.sans(12.5, color: C.muted, height: 1.55),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          for (final (i, e) in effects.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: C.bad, shape: BoxShape.circle)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(e, style: T.sans(12, color: C.soft, height: 1.5))),
              ]),
            ),
          if (loading) Padding(padding: EdgeInsets.only(top: effects.isEmpty ? 0 : 8), child: const Skeleton(width: 180, height: 10)),
        ]),
        Field(
          'Type $app to confirm',
          child: AppInput(
            controller: _typed,
            large: true,
            autofocus: true,
            hint: app,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (ok) Navigator.of(context).pop(true);
            },
          ),
        ),
        CodeBlock('\$ ${displayCommand(destroyAppArgs(app))}', color: C.muted),
      ],
    );
  }
}
