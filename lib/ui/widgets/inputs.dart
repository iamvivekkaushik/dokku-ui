import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import 'buttons.dart';

/// Single-line text field in the design's style. Mono by default because most
/// values here are technical.
class AppInput extends StatelessWidget {
  const AppInput({
    super.key,
    this.controller,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.mono = true,
    this.large = false,
    this.obscure = false,
    this.enabled = true,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.inputFormatters,
    this.focusNode,
    this.dashed = false,
    this.autocorrect = false,
    this.textInputAction,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool mono;
  final bool large;
  final bool obscure;
  final bool enabled;
  final bool autofocus;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode;
  final bool dashed;
  final bool autocorrect;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final multi = maxLines != 1;
    final height = (large ? 32.0 : 30.0) + touchPad(context);
    final size = mono ? (large ? 12.0 : 11.5) : 12.5;
    final style = mono ? T.mono(size, height: multi ? 1.6 : null) : T.sans(size);
    final radius = BorderRadius.circular(large ? 8 : 7);
    OutlineInputBorder border(Color c) => OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c));

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      obscureText: obscure,
      enabled: enabled,
      autofocus: autofocus,
      autocorrect: autocorrect,
      enableSuggestions: false,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType ?? (multi ? TextInputType.multiline : null),
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      style: style.copyWith(color: enabled ? C.fg : C.muted),
      cursorWidth: 1.2,
      decoration: InputDecoration(
        isDense: true,
        isCollapsed: !multi,
        filled: true,
        fillColor: C.field,
        hoverColor: Colors.transparent,
        hintText: hint,
        hintStyle: style.copyWith(color: C.dim),
        hintMaxLines: multi ? 4 : 1,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: multi ? 10 : (height - size * 1.35) / 2),
        enabledBorder: border(dashed ? C.w(.16) : C.lineStrong),
        disabledBorder: border(C.line),
        focusedBorder: border(C.w(.28)),
        border: border(C.lineStrong),
      ),
    );
    return multi ? field : SizedBox(height: height, child: field);
  }
}

/// Label above a control, with an optional hint below.
class Field extends StatelessWidget {
  const Field(this.label, {super.key, required this.child, this.hint, this.hintTone, this.trailing});
  final String label;
  final Widget child;
  final String? hint;
  final Tone? hintTone;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(child: Text(label, style: T.sans(12, color: C.muted))),
            ?trailing,
          ]),
          const SizedBox(height: 5),
          child,
          if (hint != null) ...[
            const SizedBox(height: 5),
            Text(hint!, style: T.sans(11, color: hintTone?.color ?? C.dim, height: 1.45)),
          ],
        ],
      );
}

class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, this.onChanged, this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final big = Bp.isCompact(context);
    final w = big ? 40.0 : 30.0, h = big ? 23.0 : 17.0, knob = h - 4;
    return Semantics(
      toggled: value,
      label: label,
      enabled: onChanged != null,
      child: MouseRegion(
        cursor: onChanged == null ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Opacity(
            opacity: onChanged == null ? .45 : 1,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: big ? 6 : 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: w,
                height: h,
                decoration: BoxDecoration(
                  color: value ? C.fg : C.w(.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: C.lineStrong),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 160),
                  alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: knob,
                    height: knob,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(color: value ? C.bg : C.muted, shape: BoxShape.circle),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Title and description on the left, a switch on the right.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.desc, required this.value, this.onChanged, this.busy = false});
  final String title;
  final String? desc;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: T.body),
            if (desc != null) ...[const SizedBox(height: 2), Text(desc!, style: T.hint)],
          ]),
        ),
        const SizedBox(width: 12),
        if (busy) const Padding(padding: EdgeInsets.only(right: 8), child: Spinner(size: 11)),
        AppSwitch(value: value, onChanged: busy ? null : onChanged, label: title),
      ]);
}

/// Recessed segmented control.
class Seg<V extends Object> extends StatelessWidget {
  const Seg({super.key, required this.value, required this.options, required this.onChanged, this.mono = false, this.small = false, this.expand = false, this.labels});
  final V? value;
  final List<V> options;
  final ValueChanged<V>? onChanged;
  final bool mono;
  final bool small;
  final bool expand;
  final String Function(V)? labels;

  @override
  Widget build(BuildContext context) {
    final height = (small ? 24.0 : 26.0) + touchPad(context);
    final items = [
      for (final o in options)
        _Segment(
          label: labels?.call(o) ?? '$o',
          selected: o == value,
          height: height,
          mono: mono,
          small: small,
          onTap: onChanged == null ? null : () => onChanged!(o),
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: C.w(.05), borderRadius: BorderRadius.circular(8)),
      child: expand
          ? Row(children: [for (final i in items) Expanded(child: i)])
          : Wrap(spacing: 2, runSpacing: 2, children: items),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({required this.label, required this.selected, required this.height, required this.mono, required this.small, this.onTap});
  final String label;
  final bool selected;
  final double height;
  final bool mono;
  final bool small;
  final VoidCallback? onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected || _hover ? C.fg : C.muted;
    final size = widget.small ? 11.0 : 12.0;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected ? C.elev2 : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: widget.selected ? C.lineStrong : Colors.transparent),
            ),
            // Sized to the label. `alignment` on the container would instead
            // stretch every segment to the full width available.
            child: Center(
              widthFactor: 1,
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: widget.mono ? T.mono(size - .5, color: color) : T.sans(size, color: color, weight: FontWeight.w500)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dropdown styled like an input.
class AppSelect<V> extends StatelessWidget {
  const AppSelect({super.key, required this.value, required this.options, required this.onChanged, this.labels, this.enabled = true, this.hint});
  final V? value;
  final List<V> options;
  final ValueChanged<V>? onChanged;
  final String Function(V)? labels;
  final bool enabled;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final height = 30.0 + touchPad(context);
    final has = options.contains(value);
    return Container(
      height: height,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(7), border: Border.all(color: C.lineStrong)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<V>(
          value: has ? value : null,
          isExpanded: true,
          isDense: true,
          hint: Text(hint ?? '', style: T.mono(11.5, color: C.dim), maxLines: 1, overflow: TextOverflow.ellipsis),
          icon: const Icon(LucideIcons.chevronDown, size: 13, color: C.muted),
          dropdownColor: C.card,
          borderRadius: BorderRadius.circular(10),
          style: T.mono(11.5),
          onChanged: enabled && onChanged != null ? (v) { if (v != null) onChanged!(v); } : null,
          items: [
            for (final o in options)
              DropdownMenuItem(value: o, child: Text(labels?.call(o) ?? '$o', maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

class RadioDot extends StatelessWidget {
  const RadioDot(this.on, {super.key});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 15,
        height: 15,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: on ? C.fg : C.w(.2))),
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(shape: BoxShape.circle, color: on ? C.fg : Colors.transparent),
        ),
      );
}

class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: value,
        label: label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!value),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: touchPad(context) / 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: value ? C.fg : Colors.transparent,
                    borderRadius: BorderRadius.circular(4.5),
                    border: Border.all(color: C.w(.2)),
                  ),
                  child: value ? const Icon(LucideIcons.check, size: 11, color: C.bg) : null,
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(label, style: T.sans(12, color: C.soft))),
              ]),
            ),
          ),
        ),
      );
}

/// `− n +` numeric stepper.
class NumberStepper extends StatelessWidget {
  const NumberStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.max = 50});
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context) {
    final box = 26 + touchPad(context);
    Widget b(String label, String semantic, int next) => Semantics(
          button: true,
          label: semantic,
          child: InkWell(
            onTap: () => onChanged(next.clamp(min, max)),
            borderRadius: BorderRadius.circular(6),
            hoverColor: C.w(.08),
            child: SizedBox(width: box, height: box, child: Center(child: Text(label, style: T.sans(14)))),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: C.w(.05), borderRadius: BorderRadius.circular(8)),
      child: Material(
        type: MaterialType.transparency,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          b('−', 'Decrease', value - 1),
          SizedBox(width: 32, child: Text('$value', textAlign: TextAlign.center, style: T.mono(13))),
          b('+', 'Increase', value + 1),
        ]),
      ),
    );
  }
}

/// Keeps a [TextEditingController] in step with a value that arrives later
/// (from the server) without fighting the user while they type.
class SyncedController {
  SyncedController([String initial = '']) : controller = TextEditingController(text: initial), _synced = initial;
  final TextEditingController controller;
  String _synced;

  String get text => controller.text;

  /// True when the user has changed the field since the last sync.
  bool get dirty => controller.text != _synced;

  /// Adopts [value] from the server unless the user has unsaved edits.
  void sync(String value) {
    if (value == _synced) return;
    final untouched = controller.text == _synced;
    _synced = value;
    if (untouched) controller.text = value;
  }

  void dispose() => controller.dispose();
}

final digitsOnly = [FilteringTextInputFormatter.digitsOnly];
