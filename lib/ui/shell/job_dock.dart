import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/jobs.dart';
import '../widgets/kit.dart';

/// Running and recently finished commands, stacked in a corner of the screen.
class JobDock extends ConsumerWidget {
  const JobDock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    if (jobs.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, j) in jobs.indexed) ...[if (i > 0) const SizedBox(height: 8), _JobCard(j, key: ValueKey(j.id))],
      ]),
    );
  }
}

class _JobCard extends ConsumerStatefulWidget {
  const _JobCard(this.job, {super.key});
  final Job job;

  @override
  ConsumerState<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends ConsumerState<_JobCard> {
  bool? _open;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && widget.job.status == JobStatus.running) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final running = job.status == JobStatus.running;
    final elapsed = DateTime.now().difference(job.startedAt).inMilliseconds;
    // Quick commands stay collapsed; anything slow opens to show progress.
    final open = _open ?? (running && elapsed > 1500);
    final tone = switch (job.status) { JobStatus.ok => Tone.ok, JobStatus.failed => Tone.bad, JobStatus.running => Tone.info };
    final lines = job.text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final tail = (lines.length > 12 ? lines.sublist(lines.length - 12) : lines).join('\n');
    final jobs = ref.read(jobsProvider.notifier);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.lineStrong),
        boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 12))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(children: [
            if (running)
              const Spinner(size: 11)
            else
              Container(width: 6, height: 6, decoration: BoxDecoration(color: tone.color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(job.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(11.5)),
                Text(
                  switch (job.status) {
                    JobStatus.running => 'running · ${formatMs(elapsed)}',
                    JobStatus.ok => 'done · ${formatMs(job.durationMs)}',
                    JobStatus.failed => 'failed · exit ${job.code ?? '?'}',
                  },
                  style: T.meta,
                ),
              ]),
            ),
            if (job.status == JobStatus.failed)
              Btn('Details', size: BtnSize.xs, onPressed: () => ref.read(failedJobProvider.notifier).show(job)),
            if (running) Btn('Cancel', size: BtnSize.xs, onPressed: () => jobs.cancel(job.id)),
            IconBtn(open ? LucideIcons.chevronDown : LucideIcons.chevronUp,
                tooltip: open ? 'Hide output' : 'Show output', onPressed: () => setState(() => _open = !open)),
            if (!running) IconBtn(LucideIcons.x, tooltip: 'Dismiss', onPressed: () => jobs.dismiss(job.id)),
          ]),
        ),
        if (open)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: C.term, border: Border(top: BorderSide(color: C.line))),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(tail.isEmpty ? 'waiting for output…' : tail,
                  style: T.mono(10.5, color: tail.isEmpty ? C.dim : C.soft, height: 1.6)),
            ),
          ),
      ]),
    );
  }
}
