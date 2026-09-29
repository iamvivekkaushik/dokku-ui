import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'buttons.dart';

/// Pill with a status dot: running, degraded, deployed, failed…
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.tone, this.dot = true, this.pulse = false, this.mono = false});
  final String label;
  final Tone tone;
  final bool dot;
  final bool pulse;
  final bool mono;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: tone.fill,
          border: Border.all(color: tone.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot) ...[pulse ? PulseDot(color: tone.color, size: 5) : _dot(tone.color, 5), const SizedBox(width: 6)],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono ? T.mono(10.5, color: tone.color) : T.sans(11, color: tone.color, weight: FontWeight.w500)),
          ),
        ]),
      );
}

Widget _dot(Color color, double size) =>
    Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));

/// Small coloured dot with a label, for table cells.
class Dot extends StatelessWidget {
  const Dot(this.label, {super.key, required this.tone});
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        _dot(tone.color, 6),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.sans(11.5, color: tone.color))),
        ],
      ]);
}

class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 8, this.ring = false});
  final Color color;
  final double size;
  final bool ring;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = _c.value;
            final pulse = .35 + .65 * (0.5 + 0.5 * math.cos(t * 2 * math.pi));
            return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              if (widget.ring)
                Transform.scale(
                  scale: 1 + 1.4 * t,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: widget.color.withValues(alpha: .6 * (1 - t))),
                    ),
                  ),
                ),
              Container(decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withValues(alpha: pulse))),
            ]);
          },
        ),
      );
}

/// Bordered card.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.danger = false, this.padding, this.color = C.card});
  final Widget child;
  final bool danger;
  final EdgeInsetsGeometry? padding;
  final Color color;

  factory Panel.column({Key? key, required List<Widget> children, bool danger = false, EdgeInsetsGeometry? padding, double gap = 0}) =>
      Panel(
        key: key,
        danger: danger,
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, c) in children.indexed) ...[if (i > 0 && gap > 0) SizedBox(height: gap), c],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger ? C.bad.withValues(alpha: .3) : C.line),
        ),
        child: child,
      );
}

class PanelHead extends StatelessWidget {
  const PanelHead(this.title, {super.key, this.trailing, this.note, this.danger = false});
  final String title;
  final Widget? trailing;

  /// Short muted text on the right.
  final String? note;
  final bool danger;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        constraints: const BoxConstraints(minHeight: 46),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: danger ? C.bad.withValues(alpha: .2) : C.line))),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(title, style: T.title.copyWith(color: danger ? C.bad : C.fg)),
            if (trailing != null) trailing! else if (note != null) Text(note!, style: T.hint),
          ],
        ),
      );
}

/// Mono strip at the bottom of a card showing the exact command behind it.
class CmdFooter extends StatelessWidget {
  const CmdFooter(this.command, {super.key, this.action, this.bright = false});
  final String command;
  final Widget? action;
  final bool bright;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: C.w(.02), border: Border(top: BorderSide(color: C.line))),
        child: Row(children: [
          Expanded(child: SelectableText(command, style: T.codeMuted.copyWith(color: bright ? C.soft : C.muted))),
          if (action != null) ...[const SizedBox(width: 10), action!],
        ]),
      );
}

/// A row inside a card, separated from the one above by a hairline.
class PanelRow extends StatelessWidget {
  const PanelRow({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10), this.first = false, this.tint});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool first;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(color: tint, border: first ? null : Border(top: BorderSide(color: C.lineSoft))),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, hoverColor: C.w(.04), splashColor: Colors.transparent, child: box),
    );
  }
}

/// Uppercase mono column headings.
class THead extends StatelessWidget {
  const THead(this.cells, {super.key});

  /// The headings, laid out in a row. Build them with [th], and use the same
  /// widths in the rows below so that the columns line up.
  final List<Widget> cells;

  @override
  Widget build(BuildContext context) => Container(
        color: C.w(.03),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: DefaultTextStyle.merge(style: T.th, child: Row(children: cells)),
      );
}

Widget th(String label, {int flex = 1, double? width, TextAlign align = TextAlign.left}) {
  final t = Text(label.toUpperCase(), style: T.th, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis);
  return width != null ? SizedBox(width: width, child: t) : Expanded(flex: flex, child: t);
}

/// Key on the left, mono value on the right.
class KV extends StatelessWidget {
  const KV(this.k, this.v, {super.key, this.mono = true, this.last = false, this.child});
  final String k;
  final String v;
  final bool mono;
  final bool last;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: C.lineSoft))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: T.sans(12, color: C.muted)),
          const SizedBox(width: 12),
          Expanded(
            child: child != null
                ? Align(alignment: Alignment.centerRight, child: child)
                : SelectableText(v, textAlign: TextAlign.right, style: mono ? T.code : T.sans(12)),
          ),
        ]),
      );
}

class KVList extends StatelessWidget {
  const KVList(this.rows, {super.key});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final (i, r) in rows.indexed) KV(r.$1, r.$2, last: i == rows.length - 1),
      ]);
}

/// Dashed box with one line of copy, for empty lists.
class EmptyBox extends StatelessWidget {
  const EmptyBox(this.text, {super.key, this.child, this.margin = const EdgeInsets.all(16)});
  final String text;
  final Widget? child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Padding(
        padding: margin,
        child: CustomPaint(
          painter: _DashedBorder(color: C.w(.14), radius: 10),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(color: C.w(.02), borderRadius: BorderRadius.circular(10)),
            child: child ?? Text(text, textAlign: TextAlign.center, style: T.small),
          ),
        ),
      );
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 8) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 4, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color || old.radius != radius;
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 12, this.radius = 4});
  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 1.0, end: .55).animate(_c),
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(color: C.w(.08), borderRadius: BorderRadius.circular(widget.radius)),
        ),
      );
}

/// Placeholder rows while a card loads.
class LoadingRows extends StatelessWidget {
  const LoadingRows({super.key, this.rows = 2});
  final int rows;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < rows; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            FractionallySizedBox(widthFactor: i.isEven ? 1 : .6, child: const Skeleton(height: 14)),
          ],
        ]),
      );
}

class PageHead extends StatelessWidget {
  const PageHead({super.key, this.eyebrow, required this.title, this.actions = const [], this.below, this.titleTrailing});
  final String? eyebrow;
  final String title;
  final List<Widget> actions;
  final Widget? below;
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 16,
        runSpacing: 12,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (eyebrow != null) ...[Text(eyebrow!.toUpperCase(), style: T.eyebrow), const SizedBox(height: 6)],
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(title, style: T.h1, maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (titleTrailing != null) ...[const SizedBox(width: 10), titleTrailing!],
            ]),
            if (below != null) ...[const SizedBox(height: 8), below!],
          ]),
          if (actions.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
        ],
      );
}

/// Scrolling page body with the standard width and gutters.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.maxWidth = 1280});
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final compact = Bp.isCompact(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(compact ? 14 : 24, compact ? 16 : 24, compact ? 14 : 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: 16), c],
          ]),
        ),
      ),
    );
  }
}

/// Lays children out in as many equal columns as fit, like CSS auto-fit.
class AutoGrid extends StatelessWidget {
  const AutoGrid({
    super.key,
    required this.children,
    this.minWidth = 220,
    this.gap = 16,
    this.equalHeight = true,
    this.fit = false,
  });
  final List<Widget> children;
  final double minWidth;
  final double gap;
  final bool equalHeight;

  /// Whether the children share the full width, for a fixed set of cards:
  /// rows are balanced (four cards become two and two, not three and one) and
  /// a shorter last row widens instead of leaving empty columns.
  final bool fit;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final room = math.max(1, ((box.maxWidth + gap) / (minWidth + gap)).floor());
        var cols = room;
        if (fit && children.isNotEmpty) {
          final rowCount = (children.length / room).ceil();
          cols = (children.length / rowCount).ceil();
        }
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += cols) {
          final slice = children.sublist(i, math.min(i + cols, children.length));
          final cells = fit ? slice.length : cols;
          // Stretching needs a known height, which only the multi-column case measures.
          final stretch = equalHeight && cells > 1;
          final row = Row(
            crossAxisAlignment: stretch ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < cells; c++) ...[
                if (c > 0) SizedBox(width: gap),
                Expanded(child: c < slice.length ? slice[c] : const SizedBox.shrink()),
              ],
            ],
          );
          if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
          rows.add(stretch ? IntrinsicHeight(child: row) : row);
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      });
}

/// Two columns of cards that stack on narrow screens.
class TwoCol extends StatelessWidget {
  const TwoCol({super.key, required this.left, required this.right, this.leftFlex = 1, this.rightFlex = 1, this.breakpoint = Bp.twoCol});
  final List<Widget> left;
  final List<Widget> right;
  final int leftFlex;
  final int rightFlex;
  final double breakpoint;

  static Widget _stack(List<Widget> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [for (final (i, c) in items.indexed) ...[if (i > 0) const SizedBox(height: 16), c]],
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < breakpoint) return _stack([...left, ...right]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: leftFlex, child: _stack(left)),
          const SizedBox(width: 16),
          Expanded(flex: rightFlex, child: _stack(right)),
        ]);
      });
}

/// Tinted full-surface notice. Never a left-border-only card.
class AlertBox extends StatelessWidget {
  const AlertBox({super.key, this.tone = Tone.warn, this.title, required this.text, this.action});
  final Tone tone;
  final String? title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final message = Text.rich(
      TextSpan(children: [
        if (title != null) TextSpan(text: '$title ', style: TextStyle(fontWeight: FontWeight.w600, color: tone.color)),
        TextSpan(text: text, style: TextStyle(color: tone.color.withValues(alpha: .8))),
      ]),
      style: T.sans(12, height: 1.5),
    );
    final action = this.action;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.color.withValues(alpha: .08),
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: action == null
          ? message
          // A button beside the text leaves the text a narrow column on a phone.
          : Bp.isCompact(context)
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  message,
                  const SizedBox(height: 8),
                  action,
                ])
              : Row(children: [Expanded(child: message), const SizedBox(width: 10), action]),
    );
  }
}

/// Dark block of mono text: command previews, raw output.
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.text, {super.key, this.maxHeight, this.color = C.soft, this.wrap = true});
  final String text;
  final double? maxHeight;
  final Color color;

  /// Turn off for text laid out in columns: long lines then scroll sideways
  /// instead of breaking the alignment.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final lines = SelectableText(text, style: T.mono(11, color: color, height: 1.7));
    final content = wrap ? lines : SingleChildScrollView(scrollDirection: Axis.horizontal, child: lines);
    return Container(
      width: double.infinity,
      constraints: maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight!),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: C.term, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(8)),
      child: maxHeight == null ? content : SingleChildScrollView(child: content),
    );
  }
}

class Kbd extends StatelessWidget {
  const Kbd(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: C.w(.06), border: Border.all(color: C.line), borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: T.mono(10, color: C.muted)),
      );
}

/// 22-segment meter used on the dashboard stat cards.
class TickMeter extends StatelessWidget {
  const TickMeter({super.key, required this.percent, this.color = C.fg});
  final double percent;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${percent.round()} percent',
        child: SizedBox(
          height: 6,
          child: Row(children: [
            for (var i = 0; i < 22; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: i / 22 < percent / 100 ? color : C.w(.08),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ]),
        ),
      );
}

/// 30 bars of recent samples.
class Sparkbars extends StatelessWidget {
  const Sparkbars({super.key, required this.values, required this.max, this.opacity = .85, this.empty});
  final List<double> values;
  final double max;
  final double opacity;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final recent = values.length > 30 ? values.sublist(values.length - 30) : values;
    final bars = [...List<double?>.filled(30 - recent.length, null), ...recent];
    return Container(
      height: 56,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
      // Expanded, so that the bars stand on the bottom line whatever their height.
      child: Stack(fit: StackFit.expand, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final (i, v) in bars.indexed) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: FractionallySizedBox(
                alignment: Alignment.bottomCenter,
                heightFactor: v == null ? 0 : (v / (max <= 0 ? 1 : max)).clamp(.04, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: C.fg.withValues(alpha: opacity),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(1)),
                  ),
                ),
              ),
            ),
          ],
        ]),
        if (values.isEmpty && empty != null) Center(child: Text(empty!, style: T.tiny, textAlign: TextAlign.center)),
      ]),
    );
  }
}

/// Header strip plus action, for the tabs of a page.
class UnderlineTabs extends StatelessWidget {
  const UnderlineTabs({super.key, required this.tabs, required this.selected, required this.onSelect});
  final List<(String id, String label)> tabs;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (id, label) in tabs)
              _Tab(label: label, selected: id == selected, onTap: () => onSelect(id), height: 36 + touchPad(context)),
          ]),
        ),
      );
}

class _Tab extends StatefulWidget {
  const _Tab({required this.label, required this.selected, required this.onTap, required this.height});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: widget.selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(width: 2, color: widget.selected ? C.fg : Colors.transparent)),
              ),
              child: Text(widget.label,
                  style: T.sans(12.5, weight: FontWeight.w500, color: widget.selected || _hover ? C.fg : C.muted)),
            ),
          ),
        ),
      );
}
