import 'dart:convert';
import 'dart:typed_data';

/// Minimal ustar writer. `dokku certs:add <app>` reads a tarball containing
/// server.crt and server.key from stdin when invoked over SSH.
final _entryName = RegExp(r'^[A-Za-z0-9._-]{1,99}$');

Uint8List _header(String name, int size, int mtime) {
  final h = Uint8List(512);
  void field(String value, int offset) {
    final bytes = ascii.encode(value);
    h.setRange(offset, offset + bytes.length, bytes);
  }

  String octal(int n, int length) => '${n.toRadixString(8).padLeft(length - 1, '0')}\u0000';
  field(name, 0);
  field(octal(420, 8), 100); // mode 0644
  field(octal(0, 8), 108);
  field(octal(0, 8), 116);
  field(octal(size, 12), 124);
  field(octal(mtime, 12), 136);
  field('        ', 148);
  field('0', 156);
  field('ustar\u0000', 257);
  field('00', 263);
  final sum = h.fold<int>(0, (a, b) => a + b);
  field('${sum.toRadixString(8).padLeft(6, '0')}\u0000 ', 148);
  return h;
}

Uint8List makeTar(Map<String, String> files, {DateTime? now}) {
  final mtime = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final out = BytesBuilder();
  for (final e in files.entries) {
    if (!_entryName.hasMatch(e.key)) throw ArgumentError('invalid tar entry name: ${e.key}');
    final body = utf8.encode(e.value);
    out.add(_header(e.key, body.length, mtime));
    out.add(body);
    out.add(Uint8List((512 - body.length % 512) % 512));
  }
  out.add(Uint8List(1024));
  return out.toBytes();
}
