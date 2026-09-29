import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/parse.dart';
import '../../state/jobs.dart';
import '../widgets/kit.dart';

/// Explains a failed command: what ran, what came back, and what to do next.
class CommandErrorDialog extends ConsumerWidget {
  const CommandErrorDialog(this.job, {super.key});
  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = job.text;
    final full = '\$ ssh -p ${job.host.port} ${job.host.username}@${job.host.host} -- ${job.command}\n$text';
    return AppDialog(
      title: 'Command failed',
      width: 560,
      header: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        decoration: BoxDecoration(color: C.bad.withValues(alpha: .1), border: Border(bottom: BorderSide(color: Tone.bad.border))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.triangleAlert, size: 18, color: C.bad)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Command failed · ${job.code == null ? 'no exit code' : 'exit ${job.code}'}',
                  style: T.sans(14, weight: FontWeight.w600, color: C.bad)),
              const SizedBox(height: 2),
              Text(
                '${job.command} returned a non-zero status${job.durationMs > 0 ? ' after ${formatMs(job.durationMs)}' : ''}',
                style: T.sans(12, color: C.bad.withValues(alpha: .8), height: 1.4),
              ),
            ]),
          ),
          IconBtn(LucideIcons.x, tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
        ]),
      ),
      actions: [
        Btn('Copy output', size: BtnSize.md, onPressed: () => Clipboard.setData(ClipboardData(text: full))),
        Btn('Dismiss', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Retry', size: BtnSize.md, variant: BtnVariant.primary, onPressed: () {
          Navigator.of(context).pop();
          ref.read(jobsProvider.notifier).retry(job);
        }),
      ],
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 320),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: C.term, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            child: SelectableText.rich(
              TextSpan(style: T.mono(11.5, color: C.soft, height: 1.7), children: [
                TextSpan(text: '\$ ${job.command}\n', style: const TextStyle(color: C.muted)),
                for (final c in job.output)
                  TextSpan(text: stripAnsi(c.text), style: c.isStderr ? const TextStyle(color: C.bad) : null),
              ]),
            ),
          ),
        ),
        Text(remediation(text), style: T.sans(12.5, color: C.muted, height: 1.5)),
      ],
    );
  }
}
