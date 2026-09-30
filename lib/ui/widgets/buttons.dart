import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';

enum BtnVariant {
  primary,
  outline,
  secondary,
  ghost,

  /// Tinted red: an action to think about, such as Stop.
  danger,

  /// Quiet until hovered, then red: a destructive action among ordinary ones.
  dangerGhost,

  /// Solid red: the final step of something that cannot be undone.
  destructive,
}

enum BtnSize { xs, sm, md }

/// Touch screens get taller controls than the dense desktop design.
double touchPad(BuildContext context) => Bp.isCompact(context) ? 8 : 0;

class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 12, this.color = C.fg});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color, backgroundColor: C.w(.2)),
      );
}

class Btn extends StatelessWidget {
  const Btn(
    this.label, {
    super.key,
    this.onPressed,
    this.variant = BtnVariant.secondary,
    this.size = BtnSize.sm,
    this.loading = false,
    this.icon,
    this.tooltip,
    this.mono = false,
    this.selected = false,
    this.square = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final BtnVariant variant;
  final BtnSize size;
  final bool loading;
  final IconData? icon;
  final String? tooltip;
  final bool mono;

  /// Draws the button in its "on" state, for toggles.
  final bool selected;

  /// As wide as it is tall, for a button that is only an icon.
  final bool square;

  /// Height, side padding, font size and corner radius of a button of [size].
  static (double height, double hPad, double font, double radius) _metrics(BuildContext context, BtnSize size) {
    final pad = touchPad(context);
    return switch (size) {
      BtnSize.xs => (24 + pad, 8, 11, 6),
      BtnSize.sm => (28 + pad, 10, 12, 7),
      BtnSize.md => (32 + pad, 12, 12.5, 8),
    };
  }

  /// How tall a button of [size] is here; a square one is as wide.
  static double heightOf(BuildContext context, [BtnSize size = BtnSize.sm]) => _metrics(context, size).$1;

  TextStyle _textStyle(double font) {
    final weight = switch (variant) {
      BtnVariant.primary || BtnVariant.destructive => FontWeight.w600,
      BtnVariant.outline || BtnVariant.danger => FontWeight.w500,
      _ => FontWeight.w400,
    };
    return mono ? T.mono(font - .5, weight: weight) : T.sans(font, weight: weight);
  }

  /// The narrowest width that shows the whole label, for a layout that decides
  /// how many buttons fit side by side. The spinner that stands in for the icon
  /// while loading is left out, so such a layout does not jump on a press.
  double naturalWidth(BuildContext context) {
    final (height, hPad, font, _) = _metrics(context, size);
    if (square) return height;
    final painter = TextPainter(
      text: TextSpan(text: label, style: _textStyle(font)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final text = painter.width;
    painter.dispose();
    return 2 * hPad + (icon == null ? 0 : font + 1 + (label.isEmpty ? 0 : 7)) + text;
  }

  @override
  Widget build(BuildContext context) {
    final (height, hPad, font, radius) = _metrics(context, size);
    final enabled = onPressed != null && !loading;

    Color bg(Set<WidgetState> s) {
      final hover = s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed);
      return switch (variant) {
        BtnVariant.primary => !enabled ? C.w(.12) : (hover ? C.fg.withValues(alpha: .88) : C.fg),
        BtnVariant.outline => hover ? C.elev : C.card,
        BtnVariant.secondary => selected || hover ? C.elev2 : C.elev,
        BtnVariant.ghost => hover ? C.w(.08) : Colors.transparent,
        BtnVariant.danger => C.bad.withValues(alpha: hover ? .18 : .10),
        BtnVariant.dangerGhost => hover && enabled ? C.bad.withValues(alpha: .08) : C.elev,
        BtnVariant.destructive => !enabled ? C.bad.withValues(alpha: .10) : (hover ? C.bad.withValues(alpha: .9) : C.bad),
      };
    }

    Color fg(Set<WidgetState> s) {
      final hover = s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed);
      final c = switch (variant) {
        BtnVariant.primary => enabled ? C.bg : C.muted,
        BtnVariant.outline || BtnVariant.secondary => C.fg,
        BtnVariant.ghost => hover ? C.fg : C.muted,
        BtnVariant.danger => C.bad,
        BtnVariant.dangerGhost => hover ? C.bad : C.muted,
        BtnVariant.destructive => enabled ? Colors.white : C.bad.withValues(alpha: .6),
      };
      return enabled || variant == BtnVariant.primary || variant == BtnVariant.destructive ? c : c.withValues(alpha: .45);
    }

    BorderSide side(Set<WidgetState> s) {
      final hover = s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed);
      return switch (variant) {
        BtnVariant.primary || BtnVariant.ghost => BorderSide.none,
        BtnVariant.danger => BorderSide(color: C.bad.withValues(alpha: .35)),
        BtnVariant.destructive => BorderSide(color: C.bad.withValues(alpha: .4)),
        BtnVariant.dangerGhost => BorderSide(color: hover && enabled ? C.bad.withValues(alpha: .4) : C.lineStrong),
        _ => BorderSide(color: C.lineStrong),
      };
    }

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading) ...[
          Spinner(size: 11, color: variant == BtnVariant.primary ? C.muted : C.fg),
          if (label.isNotEmpty) const SizedBox(width: 7),
        ],
        if (icon != null && !loading) ...[Icon(icon, size: font + 1), if (label.isNotEmpty) const SizedBox(width: 7)],
        if (label.isNotEmpty) Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false)),
      ],
    );

    final button = TextButton(
      onPressed: enabled ? onPressed : null,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(square ? height : 0, height)),
        maximumSize: WidgetStatePropertyAll(Size(square ? height : double.infinity, height)),
        fixedSize: WidgetStatePropertyAll(square ? Size.square(height) : Size.fromHeight(height)),
        padding: WidgetStatePropertyAll(square ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: hPad)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: WidgetStateProperty.resolveWith(bg),
        foregroundColor: WidgetStateProperty.resolveWith(fg),
        iconColor: WidgetStateProperty.resolveWith(fg),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStateProperty.resolveWith(side),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius))),
        textStyle: WidgetStatePropertyAll(_textStyle(font)),
        mouseCursor: WidgetStatePropertyAll(enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden),
      ),
      child: child,
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, required this.tooltip, this.onPressed, this.danger = false, this.size = 13, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final box = 26 + touchPad(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: size),
        constraints: BoxConstraints.tightFor(width: box, height: box),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        splashRadius: 1,
        style: ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith((s) {
            if (!s.contains(WidgetState.hovered) && !s.contains(WidgetState.pressed)) return Colors.transparent;
            return danger ? C.bad.withValues(alpha: .12) : C.w(.08);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((s) {
            if (s.contains(WidgetState.disabled)) return C.dim.withValues(alpha: .5);
            if (s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)) return danger ? C.bad : C.fg;
            return color ?? C.muted;
          }),
        ),
      ),
    );
  }
}

/// Copies [text] and briefly confirms it.
class CopyBtn extends StatefulWidget {
  const CopyBtn(this.text, {super.key, this.label, this.size = BtnSize.sm});
  final String text;
  final String? label;
  final BtnSize size;

  @override
  State<CopyBtn> createState() => _CopyBtnState();
}

class _CopyBtnState extends State<CopyBtn> {
  bool _done = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _done = false);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    if (label == null) {
      return IconBtn(_done ? LucideIcons.check : LucideIcons.copy,
          tooltip: _done ? 'Copied' : 'Copy', onPressed: _copy, color: _done ? C.ok : null);
    }
    return Btn(_done ? 'Copied' : label, onPressed: _copy, size: widget.size);
  }
}

/// Text that behaves like a link.
class LinkText extends StatelessWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.style});
  final String text;
  final VoidCallback onTap;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Text(text, style: (style ?? T.small).copyWith(color: C.info)),
        ),
      );
}
