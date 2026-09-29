import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/command.dart';
import '../../../core/parse.dart';
import '../../../data/models.dart';
import '../../../data/platform.dart';
import '../../../state/queries.dart';
import '../../actions.dart';
import '../../widgets/kit.dart';

/// Variables Dokku sets itself. Hidden unless asked for, and left alone by "Replace all".
const _systemKeys = {
  'DOKKU_APP_TYPE',
  'DOKKU_PROXY_PORT',
  'DOKKU_PROXY_SSL_PORT',
  'GIT_REV',
  'DOKKU_APP_RESTORE',
  'DOKKU_DOCKERFILE_START_CMD',
};

const _masked = '••••••••••••••••';
const _keyWidth = 240.0;

/// Below this the key, value and actions no longer fit side by side.
const _stackBelow = 600.0;

final _validKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _notKeyChar = RegExp(r'[^A-Za-z0-9_]');
final _lineBreak = RegExp(r'\r?\n');

enum _Format { env, json, shell }

class _KeyFormatter extends TextInputFormatter {
  const _KeyFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.replaceAll(_notKeyChar, '_').toUpperCase());
}

class _Var {
  const _Var(this.key, this.value, {required this.isNew, required this.edited});
  final String key;
  final String value;
  final bool isNew;
  final bool edited;

  bool get secret => isSecretKey(key);
  bool get staged => isNew || edited;
}

typedef _Import = ({List<MapEntry<String, String>> vars, bool replace});

String _count(int n) => n == 1 ? '1 variable' : '$n variables';

Map<String, String> _parseConfig(ExecResult r) {
  final text = r.stdout.trim();
  if (text.isEmpty) return {};
  try {
    return {for (final e in (jsonDecode(text) as Map<String, dynamic>).entries) e.key: '${e.value}'};
  } on Object {
    // Showing an empty list here would invite saving over variables that exist.
    throw const FormatException('Dokku returned a variable list that could not be read.');
  }
}

class EnvTab extends ConsumerStatefulWidget {
  const EnvTab({super.key, required this.host, required this.app});
  final Host host;
  final String app;

  @override
  ConsumerState<EnvTab> createState() => _EnvTabState();
}

class _EnvTabState extends ConsumerState<EnvTab> with Busy {
  final _newKey = TextEditingController();
  final _newValue = TextEditingController();

  /// Values added or changed here and not saved yet.
  final _pending = <String, String>{};

  /// Keys to unset on the next save.
  final _removed = <String>[];
  final _revealed = <String>{};

  /// What the server has, as of the last build.
  Map<String, String> _server = const {};

  var _revealAll = false;
  var _keysOnly = false;
  var _showSystem = false;
  var _restart = true;
  var _format = _Format.env;
  String? _problem;

  List<String> get _exportArgs => ['config:export', '--format', 'json', widget.app];

  /// Staged values that differ from what the server has.
  Map<String, String> get _toSet => {
        for (final e in _pending.entries)
          if (_server[e.key] != e.value) e.key: e.value,
      };

  /// Staged removals of variables the server still has.
  List<String> get _toUnset => [for (final k in _removed) if (_server.containsKey(k)) k];

  @override
  void dispose() {
    _newKey.dispose();
    _newValue.dispose();
    super.dispose();
  }

  /// When variables are also removed, that command restarts the app, so that
  /// one save is one restart.
  List<String> _setArgs(Map<String, String> vars, {required bool restart}) => [
        'config:set',
        '--encoded',
        if (!restart) '--no-restart',
        widget.app,
        // Encoded so that line breaks, quotes and shell characters arrive intact.
        for (final e in vars.entries) '${e.key}=${base64.encode(utf8.encode(e.value))}',
      ];

  List<String> _unsetArgs(List<String> keys) => ['config:unset', if (!_restart) '--no-restart', widget.app, ...keys];

  void _stage(String key, String value) {
    _removed.remove(key);
    if (_server[key] == value) {
      _pending.remove(key);
    } else {
      _pending[key] = value;
    }
  }

  void _add() {
    final key = _newKey.text.trim();
    if (!_validKey.hasMatch(key)) return;
    setState(() => _stage(key, _newValue.text));
    _newKey.clear();
    _newValue.clear();
  }

  void _delete(String key) => setState(() {
        _pending.remove(key);
        // A variable that was only staged has nothing to unset on the server.
        if (_server.containsKey(key) && !_removed.contains(key)) _removed.add(key);
      });

  void _toggleReveal(_Var v, Iterable<_Var> rows) => setState(() {
        if (_revealAll) {
          // Hiding one row while everything is shown keeps the others shown.
          _revealAll = false;
          _revealed
            ..clear()
            ..addAll([for (final r in rows) if (r.secret && r.key != v.key) r.key]);
        } else if (!_revealed.remove(v.key)) {
          _revealed.add(v.key);
        }
      });

  Future<void> _edit(_Var v) async {
    final value = await showAppDialog<String>(context, (_) => _EditValueDialog(v.key, v.value));
    if (value != null && mounted) setState(() => _stage(v.key, value));
  }

  Future<void> _import() async {
    setState(() => _problem = null);
    try {
      final file = await pickTextFile();
      if (file == null || !mounted) return;
      final choice = await showAppDialog<_Import>(context, (_) => _ImportDialog(file.name, file.text));
      if (choice == null || !mounted) return;
      setState(() {
        if (choice.replace) {
          final kept = {for (final v in choice.vars) v.key};
          _pending.clear();
          _removed
            ..clear()
            ..addAll(_server.keys.where((k) => !_systemKeys.contains(k) && !kept.contains(k)));
        }
        for (final v in choice.vars) {
          _stage(v.key, v.value);
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'Could not read that file. ${e is FormatException ? e.message : e}');
    }
  }

  Future<void> _export(List<_Var> rows) async {
    setState(() => _problem = null);
    final vars = {for (final r in rows) r.key: r.value};
    final text = switch (_format) {
      _Format.json => const JsonEncoder.withIndent('  ').convert(vars),
      _Format.env => [for (final e in vars.entries) '${e.key}=${envQuote(e.value)}\n'].join(),
      _Format.shell => [for (final e in vars.entries) 'export ${e.key}=${envQuote(e.value)}\n'].join(),
    };
    try {
      await saveTextFile('${widget.app}.${_format == _Format.json ? 'json' : 'env'}', text);
    } on Object catch (e) {
      if (mounted) setState(() => _problem = 'Could not save the file. $e');
    }
  }

  Future<void> _save() => busy('save', () async {
        final host = widget.host;
        final set = _toSet, unset = _toUnset;
        final restartOnSet = _restart && unset.isEmpty;
        final restarts = _restart;
        // Both commands run even if this tab is closed meanwhile: the second one restarts the app.
        final run = DokkuRunner(ref, host);
        final setArgs = _setArgs(set, restart: restartOnSet), unsetArgs = _unsetArgs(unset);
        setState(() => _problem = null);
        if (set.isNotEmpty) {
          final r = await run(setArgs, title: 'Set ${_count(set.length)}');
          if (!r.ok) return;
        }
        var unsetDone = unset.isEmpty;
        if (!unsetDone) {
          final r = await run(unsetArgs, title: 'Unset ${_count(unset.length)}');
          unsetDone = r.ok;
          if (!unsetDone && set.isNotEmpty && restarts && mounted) {
            setState(() => _problem = 'The new values were saved, but the app was not restarted because removing '
                'variables failed. Save again, or restart the app, to apply them.');
          }
        }
        if (!mounted) return;
        // Wait for the list to be read again, so saved rows do not flash back to their old values.
        try {
          await ref.read(dokkuProvider(DokkuQuery(host.id, _exportArgs)).future).timeout(const Duration(seconds: 15));
        } on Object {
          // The card reports a failed lookup itself.
        }
        if (!mounted) return;
        setState(() {
          // Anything staged while the commands ran stays staged.
          _pending.removeWhere((k, v) => set[k] == v);
          if (unsetDone) _removed.removeWhere(unset.contains);
        });
      });

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final env = ref.dokku(widget.host, _exportArgs, _parseConfig);
    final server = _server = env.data ?? const {};
    final merged = {...server, ..._pending};
    final toSet = _toSet, toUnset = _toUnset;
    final rows = [
      for (final k in merged.keys.toList()..sort())
        if (!_removed.contains(k) && (_showSystem || !_systemKeys.contains(k)))
          _Var(k, merged[k]!, isNew: !server.containsKey(k), edited: server.containsKey(k) && toSet.containsKey(k)),
    ];
    final dirty = toSet.isNotEmpty || toUnset.isNotEmpty;
    final newKey = _newKey.text.trim();
    final keyOk = _validKey.hasMatch(newKey);
    final flag = _restart ? '' : '--no-restart ';
    final command = dirty
        ? [
            if (toSet.isNotEmpty) '\$ ${displayCommand(_setArgs(toSet, restart: _restart && toUnset.isEmpty))}',
            if (toUnset.isNotEmpty) '\$ ${displayCommand(_unsetArgs(toUnset))}',
          ].join('\n')
        : '\$ dokku config:set --encoded $flag$app KEY=<base64>\n\$ dokku config:unset $flag$app KEY';

    bool shown(_Var v) => !v.secret || _revealAll || _revealed.contains(v.key);

    return LayoutBuilder(builder: (context, box) {
      final stacked = box.maxWidth < _stackBelow;
      final iconBox = 26 + touchPad(context);

      Widget keyCell(_Var v) => Row(children: [
            if (v.secret) ...[const Icon(LucideIcons.lock, size: 11, color: C.muted), const SizedBox(width: 8)],
            Flexible(child: Text(v.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12))),
            if (v.staged) ...[
              const SizedBox(width: 8),
              Pill(v.isNew ? 'new' : 'edited', tone: Tone.info, dot: false),
            ],
          ]);

      Widget valueCell(_Var v) {
        // A hidden value is never put on screen, not even off to the side.
        final text = !shown(v)
            ? Text(_masked, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: T.mono(12, color: C.dim, spacing: 1.2))
            : v.value.isEmpty
                ? Text('empty', style: T.mono(12, color: C.dim).copyWith(fontStyle: FontStyle.italic))
                : Text(v.value.replaceAll(_lineBreak, ' ↵ '), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.mono(12));
        return Tooltip(
          message: 'Edit value',
          child: Semantics(
            button: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _edit(v),
                child: Padding(padding: EdgeInsets.symmetric(vertical: 4 + touchPad(context) / 2), child: text),
              ),
            ),
          ),
        );
      }

      List<Widget> actions(_Var v) => [
            if (v.secret && !_keysOnly)
              IconBtn(shown(v) ? LucideIcons.eyeOff : LucideIcons.eye,
                  tooltip: shown(v) ? 'Hide value' : 'Reveal value', onPressed: () => _toggleReveal(v, rows)),
            CopyBtn(v.value),
            IconBtn(LucideIcons.x, tooltip: 'Delete variable', danger: true, onPressed: () => _delete(v.key)),
          ];

      Widget row(_Var v) => PanelRow(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            tint: v.staged ? Tone.info.color.withValues(alpha: .06) : null,
            child: stacked
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [Expanded(child: keyCell(v)), const SizedBox(width: 8), ...actions(v)]),
                    if (!_keysOnly) valueCell(v),
                  ])
                : Row(children: [
                    SizedBox(width: _keyWidth, child: keyCell(v)),
                    const SizedBox(width: 12),
                    Expanded(child: _keysOnly ? const SizedBox.shrink() : valueCell(v)),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: iconBox * 3,
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions(v)),
                    ),
                  ]),
          );

      final keyInput = AppInput(
        controller: _newKey,
        hint: 'NEW_KEY',
        inputFormatters: const [_KeyFormatter()],
        textInputAction: TextInputAction.next,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _add(),
      );
      final valueInput = AppInput(controller: _newValue, hint: 'value', onSubmitted: (_) => _add());
      final add = Btn('Add variable', onPressed: keyOk ? _add : null);

      return Panel.column(children: [
        PanelHead(
          env.hasData ? 'Config vars · ${rows.length}' : 'Config vars',
          trailing: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Btn('Import .env', onPressed: env.hasData ? _import : null),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Btn('Export', onPressed: env.hasData ? () => _export(rows) : null),
              const SizedBox(width: 4),
              Seg<_Format>(
                value: _format,
                options: _Format.values,
                labels: (f) => f.name,
                small: true,
                mono: true,
                onChanged: (f) => setState(() => _format = f),
              ),
            ]),
            Btn(_revealAll ? 'Hide values' : 'Reveal all',
                onPressed: () => setState(() {
                      _revealAll = !_revealAll;
                      _revealed.clear();
                    })),
            Btn(_keysOnly ? 'Show values' : 'Keys only', selected: _keysOnly, onPressed: () => setState(() => _keysOnly = !_keysOnly)),
            Btn('System',
                selected: _showSystem,
                tooltip: 'Shows the variables Dokku sets itself, such as GIT_REV.',
                onPressed: () => setState(() => _showSystem = !_showSystem)),
          ]),
        ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: AlertBox(
              tone: Tone.bad,
              text: _problem!,
              action: IconBtn(LucideIcons.x, tooltip: 'Dismiss', onPressed: () => setState(() => _problem = null)),
            ),
          ),
        if (rows.isNotEmpty)
          THead(stacked
              ? [th('key and value')]
              : [th('key', width: _keyWidth), const SizedBox(width: 12), th('value'), SizedBox(width: iconBox * 3 + 12)]),
        if (env.loading) const LoadingRows(),
        if (env.error != null) EmptyBox('Could not read the config vars. ${env.errorText}'),
        if (env.hasData && rows.isEmpty)
          EmptyBox(toUnset.isEmpty
              ? 'No config vars set. Add one below or import a .env file.'
              : 'Every variable is marked for removal. Save changes to unset them, or undo.'),
        for (final v in rows) row(v),
        if (toUnset.isNotEmpty)
          PanelRow(
            tint: Tone.bad.color.withValues(alpha: .06),
            child: Row(children: [
              Expanded(child: Text('will unset: ${toUnset.join(' ')}', style: T.mono(11, color: Tone.bad.color, height: 1.5))),
              const SizedBox(width: 12),
              Btn('Undo', variant: BtnVariant.ghost, onPressed: () => setState(_removed.clear)),
            ]),
          ),
        if (env.hasData)
          PanelRow(
            tint: C.w(.02),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (stacked) ...[
                keyInput,
                const SizedBox(height: 8),
                valueInput,
                const SizedBox(height: 8),
                add,
              ] else
                Row(children: [
                  SizedBox(width: _keyWidth, child: keyInput),
                  const SizedBox(width: 12),
                  Expanded(child: valueInput),
                  const SizedBox(width: 12),
                  add,
                ]),
              if (newKey.isNotEmpty && !keyOk) ...[
                const SizedBox(height: 6),
                Text('A key starts with a letter or an underscore.', style: T.sans(11.5, color: Tone.bad.color)),
              ],
            ]),
          ),
        PanelRow(
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                AppSwitch(value: _restart, label: 'Restart app on save', onChanged: (v) => setState(() => _restart = v)),
                const SizedBox(width: 8),
                Text('Restart app on save', style: T.body),
              ]),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (dirty)
                  Btn('Discard',
                      size: BtnSize.md,
                      onPressed: isBusy('save')
                          ? null
                          : () => setState(() {
                                _pending.clear();
                                _removed.clear();
                              })),
                Btn('Save changes',
                    variant: BtnVariant.primary, size: BtnSize.md, loading: isBusy('save'), onPressed: dirty ? _save : null),
              ]),
            ],
          ),
        ),
        CmdFooter(command),
      ]);
    });
  }
}

class _EditValueDialog extends StatefulWidget {
  const _EditValueDialog(this.name, this.value);
  final String name;
  final String value;

  @override
  State<_EditValueDialog> createState() => _EditValueDialogState();
}

class _EditValueDialogState extends State<_EditValueDialog> {
  late final _value = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
        title: widget.name,
        subtitle: 'Nothing is sent until you save changes.',
        width: 560,
        actions: [
          Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
          Btn('Update value',
              size: BtnSize.md, variant: BtnVariant.primary, onPressed: () => Navigator.of(context).pop(_value.text)),
        ],
        children: [
          AppInput(controller: _value, maxLines: 10, minLines: 6, autofocus: true),
          Text('Line breaks, quotes and special characters are kept exactly as typed.', style: T.hint),
        ],
      );
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog(this.fileName, this.text);
  final String fileName;
  final String text;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final _text = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vars = parseEnvFile(_text.text);
    void close(bool replace) => Navigator.of(context).pop<_Import>((vars: vars, replace: replace));
    return AppDialog(
      title: 'Import .env',
      subtitle: widget.fileName,
      width: 560,
      actions: [
        Btn('Cancel', size: BtnSize.md, onPressed: () => Navigator.of(context).pop()),
        Btn('Replace all', size: BtnSize.md, onPressed: vars.isEmpty ? null : () => close(true)),
        Btn('Merge', size: BtnSize.md, variant: BtnVariant.primary, onPressed: vars.isEmpty ? null : () => close(false)),
      ],
      children: [
        AppInput(controller: _text, maxLines: 14, minLines: 8, onChanged: (_) => setState(() {})),
        Text(
          '${_count(vars.length)} found. Merge adds and updates them. Replace all also removes every variable '
          'that is not in the file. Nothing is sent until you save changes.',
          style: T.hint,
        ),
      ],
    );
  }
}
