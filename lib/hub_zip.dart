import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Offset and length identify an exact slice of one immutable resource version.
typedef HubBytes = Future<Uint8List> Function(int offset, int length);

class _Member {
  const _Member(this.offset, this.method, this.packed, this.size, this.crc);
  final int offset, method, packed, size, crc;
}

class HubZip {
  HubZip._(this._members, this._directoryOffset);
  final Map<String, _Member> _members;
  final int _directoryOffset;
  int? sizeOf(String name) => _members[name]?.size;

  static Future<HubZip> open(int size, HubBytes read) async {
    const invalid = FormatException('EPUB 目录不完整或不支持在线读取。');
    if (size < 22) throw invalid;
    var tail = await read(size - 22, 22);
    var data = ByteData.sublistView(tail);
    var i = 0;
    if (data.getUint32(0, Endian.little) != 0x06054b50 ||
        data.getUint16(20, Endian.little) != 0) {
      final length = math.min(65557, size);
      tail = await read(size - length, length);
      data = ByteData.sublistView(tail);
      for (i = length - 22; i >= 0; i--) {
        if (data.getUint32(i, Endian.little) == 0x06054b50 &&
            i + 22 + data.getUint16(i + 20, Endian.little) == length) {
          break;
        }
      }
      if (i < 0) throw invalid;
    }
    int word(int offset) => data.getUint16(offset, Endian.little);
    int dword(int offset) => data.getUint32(offset, Endian.little);
    final count = word(i + 10), bytes = dword(i + 12), offset = dword(i + 16);
    if (word(i + 4) != 0 ||
        word(i + 6) != 0 ||
        word(i + 8) != count ||
        count == 0 ||
        count > 12000 ||
        bytes > 4 << 20 ||
        offset + bytes > size - tail.length + i) {
      throw invalid;
    }
    final directory = await read(offset, bytes);
    data = ByteData.sublistView(directory);
    final members = <String, _Member>{};
    var pos = 0, total = 0;
    for (var entry = 0; entry < count; entry++) {
      if (pos + 46 > bytes || dword(pos) != 0x02014b50) throw invalid;
      final length = word(pos + 28),
          extra = word(pos + 30),
          comment = word(pos + 32);
      final end = pos + 46 + length + extra + comment;
      if (end > bytes || word(pos + 34) != 0) throw invalid;
      final name = utf8.decode(directory.sublist(pos + 46, pos + 46 + length));
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').contains('..') ||
          ((dword(pos + 38) >> 16) & 0xf000) == 0xa000 ||
          members.containsKey(name)) {
        throw invalid;
      }
      if (word(pos + 8) & 1 != 0) throw const FormatException('暂不支持加密 EPUB。');
      final member = _Member(
        dword(pos + 42),
        word(pos + 10),
        dword(pos + 20),
        dword(pos + 24),
        dword(pos + 16),
      );
      total += member.size;
      if (member.size > 24 << 20 ||
          member.packed > 25 << 20 ||
          total > 192 << 20 ||
          member.offset + 30 + member.packed > offset) {
        throw invalid;
      }
      members[name] = member;
      pos = end;
    }
    return HubZip._(members, offset);
  }

  Future<Uint8List> member(String name, HubBytes read) async {
    final entry = _members[name];
    if (entry == null) throw FormatException('EPUB 缺少资源：$name');
    final data = ByteData.sublistView(await read(entry.offset, 30));
    if (data.getUint32(0, Endian.little) != 0x04034b50 ||
        data.getUint16(8, Endian.little) != entry.method ||
        data.getUint16(6, Endian.little) & 1 != 0) {
      throw const FormatException('EPUB 资源头无效。');
    }
    final offset =
        entry.offset +
        30 +
        data.getUint16(26, Endian.little) +
        data.getUint16(28, Endian.little);
    if (offset + entry.packed > _directoryOffset) {
      throw const FormatException('EPUB 资源范围无效。');
    }
    final compressed = await read(offset, entry.packed);
    Uint8List bytes;
    if (entry.method == 0) {
      bytes = compressed;
    } else if (entry.method == 8) {
      final chunks = Stream.fromIterable([
        for (var i = 0; i < compressed.length; i += 2048)
          Uint8List.sublistView(
            compressed,
            i,
            math.min(i + 2048, compressed.length),
          ),
      ]);
      final output = BytesBuilder(copy: false);
      await for (final part in ZLibDecoder(raw: true).bind(chunks)) {
        if (output.length + part.length > entry.size) {
          throw const FormatException('EPUB 解压长度无效。');
        }
        output.add(part);
      }
      bytes = output.takeBytes();
    } else {
      throw const FormatException('此 EPUB 压缩方式暂不支持在线阅读。');
    }
    if (bytes.length != entry.size || getCrc32(bytes) != entry.crc) {
      throw const FormatException('EPUB 章节校验失败。');
    }
    return bytes;
  }
}
