/// Small pieces the app tabs have in common.
library;

import 'package:flutter/material.dart';

import '../../../core/command.dart';
import '../../../state/queries.dart';
import '../../widgets/kit.dart';

final _quotedBlank = RegExp(r"'([^'\s]*<[a-z][a-z-]*>[^'\s]*)'");

/// The command line for a card footer. Values that are not filled in yet are
/// passed as `<placeholders>`, which are shown bare instead of quoted.
String footerCommand(List<String> args) =>
    '\$ ${displayCommand(args).replaceAllMapped(_quotedBlank, (m) => m[1]!)}';

/// What a card shows until its lookup has data, or null once it has.
Widget? cardPlaceholder(Q<Object?> q, String what) {
  if (q.data != null) return null;
  if (q.loading) return const LoadingRows();
  return EmptyBox('Could not load $what. ${q.errorText}');
}

/// A switch for the right side of a card heading.
class HeadSwitch extends StatelessWidget {
  const HeadSwitch({super.key, required this.label, required this.value, required this.busy, this.onChanged});
  final String label;
  final bool value;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy) const Padding(padding: EdgeInsets.only(right: 8), child: Spinner(size: 11)),
        AppSwitch(value: value, label: label, onChanged: busy ? null : onChanged),
      ]);
}

/// A remove button that turns into a spinner while its command runs.
class RemoveBtn extends StatelessWidget {
  const RemoveBtn({super.key, required this.tooltip, required this.busy, required this.onPressed});
  final String tooltip;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => busy
      ? SizedBox.square(dimension: 26 + touchPad(context), child: const Center(child: Spinner()))
      : IconBtn(LucideIcons.x, tooltip: tooltip, danger: true, onPressed: onPressed);
}
