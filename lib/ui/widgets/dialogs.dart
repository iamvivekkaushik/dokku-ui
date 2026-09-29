import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import 'buttons.dart';
import 'inputs.dart';

/// Modal card: header, scrolling body, footer with actions.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.actions = const [],
    this.leading,
    this.width = 480,
    this.header,
    this.dismissible = true,
    this.danger = false,
    this.bodyPadding = const EdgeInsets.all(20),
    this.gap = 14,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget> actions;

  /// Shown at the left of the footer, e.g. a secondary link.
  final Widget? leading;
  final double width;

  /// Replaces the default header.
  final Widget? header;
  final bool dismissible;

  /// Outlines the card in red, for something that cannot be undone.
  final bool danger;
  final EdgeInsets bodyPadding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final compact = Bp.isCompact(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24, vertical: compact ? 16 : 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: danger ? C.bad.withValues(alpha: .3) : C.lineStrong),
            boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 20))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header ??
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(title, style: T.sans(15, weight: FontWeight.w600, spacing: -.15)),
                        if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: T.small)],
                      ]),
                    ),
                    if (dismissible)
                      IconBtn(LucideIcons.x, tooltip: 'Close', onPressed: () => Navigator.of(context).maybePop()),
                  ]),
                ),
            Flexible(
              child: SingleChildScrollView(
                padding: bodyPadding,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  for (final (i, c) in children.indexed) ...[if (i > 0) SizedBox(height: gap), c],
                ]),
              ),
            ),
            if (actions.isNotEmpty || leading != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(color: C.w(.02), border: Border(top: BorderSide(color: C.line))),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    leading ?? const SizedBox.shrink(),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

Future<R?> showAppDialog<R>(BuildContext context, WidgetBuilder builder, {bool dismissible = true}) => showDialog<R>(
      context: context,
      barrierDismissible: dismissible,
      barrierColor: C.bg.withValues(alpha: .7),
      builder: builder,
    );

/// What a destructive or disruptive action needs the user to agree to.
class Confirm {
  const Confirm({required this.title, this.body, this.label = 'Confirm', this.danger = false, this.typeToConfirm});
  final String title;
  final String? body;
  final String label;
  final bool danger;

  /// When set, the user must type this text before the action is enabled.
  final String? typeToConfirm;
}

Future<bool> confirm(BuildContext context, Confirm c) async =>
    await showAppDialog<bool>(context, (_) => _ConfirmDialog(c)) ?? false;

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog(this.c);
  final Confirm c;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final ok = c.typeToConfirm == null || _typed.text == c.typeToConfirm;
    return AppDialog(
      title: c.title,
      width: 420,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.pop(context, false)),
        Btn(c.label,
            size: BtnSize.md,
            variant: c.danger ? BtnVariant.danger : BtnVariant.primary,
            onPressed: ok ? () => Navigator.pop(context, true) : null),
      ],
      children: [
        if (c.body != null) Text(c.body!, style: T.sans(12.5, color: C.muted, height: 1.5)),
        if (c.typeToConfirm != null)
          Field(
            'Type ${c.typeToConfirm} to confirm',
            child: AppInput(
              controller: _typed,
              large: true,
              autofocus: true,
              hint: c.typeToConfirm,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (ok) Navigator.pop(context, true);
              },
            ),
          ),
      ],
    );
  }
}
