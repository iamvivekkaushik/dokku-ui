String formatBytes(num? n, {int digits = 1}) {
  if (n == null || n.isNaN || n.isInfinite) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var i = 0;
  var v = n.toDouble();
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : digits)} ${units[i]}';
}

String formatDuration(num? seconds) {
  if (seconds == null) return '—';
  final s = seconds.floor();
  final d = s ~/ 86400, h = (s % 86400) ~/ 3600, m = (s % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h.toString().padLeft(2, '0')}h';
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  return '${m}m';
}

String formatMs(int ms) => ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)}s';

/// Relative time. Accepts a DateTime, epoch seconds/milliseconds, or an ISO string.
String ago(Object? input, {DateTime? now}) {
  final t = toDateTime(input);
  if (t == null) return input == null || input == '' ? '—' : '$input';
  final s = (now ?? DateTime.now()).difference(t).inSeconds;
  if (s < 0) {
    final f = -s;
    if (f < 3600) return 'in ${(f / 60).round()}m';
    if (f < 86400) return 'in ${(f / 3600).round()}h';
    return 'in ${(f / 86400).round()}d';
  }
  if (s < 45) return 'just now';
  if (s < 3600) return '${(s / 60).round()}m ago';
  if (s < 86400) return '${(s / 3600).round()}h ago';
  if (s < 172800) return 'yesterday';
  return '${(s / 86400).round()}d ago';
}

DateTime? toDateTime(Object? input) {
  if (input == null || input == '') return null;
  if (input is DateTime) return input;
  if (input is num) {
    final ms = input < 1e12 ? (input * 1000).round() : input.round();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  final s = '$input'.trim();
  final n = num.tryParse(s);
  if (n != null) return toDateTime(n);
  return DateTime.tryParse(s) ?? _parseOpenSslDate(s);
}

const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
final _openSsl = RegExp(r'^([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})(?:\s+GMT)?$');

/// `Dec  9 06:24:00 2026 GMT`, the format Dokku prints certificate dates in.
DateTime? _parseOpenSslDate(String s) {
  final m = _openSsl.firstMatch(s);
  if (m == null) return null;
  final month = _months.indexOf(m[1]!.toLowerCase());
  if (month < 0) return null;
  return DateTime.utc(int.parse(m[6]!), month + 1, int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
}

int? daysUntil(Object? input, {DateTime? now}) {
  final t = toDateTime(input);
  if (t == null) return null;
  return (t.difference(now ?? DateTime.now()).inHours / 24).floor();
}

String clock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

/// The day of [input] as `2026-09-29`, or [fallback] when it is not a date.
String dateOnly(Object? input, {String fallback = '—'}) {
  final t = toDateTime(input);
  if (t == null) return fallback;
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// The first of [values] that has text in it, or [fallback].
String firstFilled(List<String?> values, String fallback) =>
    values.firstWhere((v) => v != null && v.isNotEmpty, orElse: () => fallback)!;
