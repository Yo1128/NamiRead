import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'book_import.dart';
import 'library.dart';
import 'hub_library.dart';

import 'package:nami_hub_client/nami_hub_client.dart';

import 'source_model.dart';

typedef BackupProgress = void Function(String message);

// Fixed header, length-prefixed UTF-8 manifest, manifest digest, original files.
// Derived HTML is rebuilt by the normal importer on the receiving device.
final _signature = ascii.encode('NamiRead/1\n');
const _maxManifest = 16 << 20;
const _maxBook = 96 << 20;
final _id = RegExp(r'^[0-9a-f]{64}$');

void _require(bool condition, String reason) {
  if (!condition) throw FormatException(reason);
}

bool _number(dynamic n, num min, num max) =>
    n is num && n.isFinite && n >= min && n <= max;

Data _settings(dynamic raw) {
  _require(raw is Data, '备份缺少阅读设置');
  final s = <String, dynamic>{...Library.defaultSettings, ...raw};
  _require(
    _number(s['size'], 15, 30) &&
        _number(s['margin'], 12, 44) &&
        _number(s['leading'], 1.4, 2.5) &&
        _number(s['width'], 380, 860) &&
        s['tone'] is int &&
        _number(s['tone'], 0, 2) &&
        (s['serif'] ?? false) is bool &&
        s['landscapeSpread'] is bool &&
        (s['shelfList'] ?? false) is bool &&
        ['最近阅读', '最近导入', '书名'].contains(s['shelfSort'] ?? '最近阅读'),
    '备份中的排版或书架设置无效',
  );
  if (s.containsKey('bookSources')) {
    _require(
      s['bookSources'] is List &&
          s['bookSources'].length <= 256 &&
          utf8.encode(jsonEncode(s['bookSources'])).length <= maxSourceBytes,
      '备份中的书源配置无效',
    );
    configuredSources(s);
  }
  return s;
}

void _validatePoint(dynamic point, Book book, {required bool progress}) {
  _require(
    point is Data &&
        point['revision'] == book.id &&
        point['version'] == locatorVersion &&
        point['resource'] is String &&
        book.chapterAt(point['resource']) >= 0 &&
        point['top'] is bool &&
        point['node'] is int &&
        point['node'] >= 0 &&
        point['ch'] is int &&
        point['ch'] >= 0 &&
        point['context'] is String &&
        _number(point['fraction'], 0, 1) &&
        (point['section'] == null || point['section'] is String) &&
        (point['image'] == null ||
            (point['image'] is int &&
                point['image'] >= 0 &&
                _number(point['imageOffset'], 0, 1))) &&
        (!progress || point['when'] is int),
    '《${book.title}》的阅读记录无效',
  );
}

void _validateEntries(List entries) {
  final ids = <String>{};
  for (final e in entries) {
    _require(
      e is Data &&
          e['id'] is String &&
          _id.hasMatch(e['id']) &&
          ids.add(e['id']) &&
          e['size'] is int &&
          _number(e['size'], 1, _maxBook) &&
          e['added'] is int &&
          _number(e['added'], 0, 8640000000000000) &&
          e['name'] is String &&
          e['marks'] is List,
      '备份书目无效或有重复条目',
    );
    final ext = p.extension(e['name']).toLowerCase();
    _require(
      ext == '.namiweb' && e['size'] <= maxChapterBytes ||
          ext == '.epub' ||
          ext == '.txt' &&
              [
                'UTF-8',
                'GB18030',
                'Big5',
                'UTF-16LE',
                'UTF-16BE',
              ].contains(e['encoding']),
      '备份书籍的格式或编码不受支持',
    );
    if (e.containsKey('cached')) {
      _require(
        ext == '.namiweb' && e['cached'] is List && e['cached'].length <= 10000,
        '章节缓存清单无效',
      );
      final indices = <int>{};
      for (final c in e['cached']) {
        _require(
          c is Map &&
              c['index'] is int &&
              _number(c['index'], 0, 9999) &&
              indices.add(c['index']) &&
              c['size'] is int &&
              _number(c['size'], 1, maxChapterBytes) &&
              c['digest'] is String &&
              _id.hasMatch(c['digest']),
          '章节缓存条目无效',
        );
      }
    }
  }
}

Future<Uint8List> _read(RandomAccessFile input, int size) async {
  final result = Uint8List(size);
  var offset = 0;
  while (offset < size) {
    final n = await input.readInto(result, offset);
    _require(n > 0, '备份文件不完整');
    offset += n;
  }
  return result;
}

Future<String> _copy(Stream<List<int>> source, RandomAccessFile output) async {
  final digest = await sha256
      .bind(
        source.asyncMap((chunk) async {
          await output.writeFrom(chunk);
          return chunk;
        }),
      )
      .first;
  return digest.toString();
}

Future<void> exportBackup(
  Library lib,
  File destination,
  BackupProgress report,
) async {
  await lib.finishWrites();
  final books = List.of(lib.books);
  final entries = <Data>[];
  for (final book in books) {
    final cached = <Data>[];
    if (book.isSourceBook) {
      await for (final file in book.dir.list(followLinks: false)) {
        final match = RegExp(r'^cached-(\d+)\.txt$')
            .firstMatch(p.basename(file.path));
        if (file is File && match != null) {
          cached.add({
            'index': int.parse(match[1]!),
            'size': await file.length(),
            'digest': (await sha256.bind(file.openRead()).first).toString(),
          });
        }
      }
      cached.sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
    }
    entries.add({
      if (book.isSourceBook) 'cached': cached,
      if (book.meta['hubDownload'] == true &&
          ((book.meta['hubOrigins'] as Map?)?.length ?? 0) <= 1)
        'hubDownload': true,
      'id': book.id,
      'name': book.meta['sourceName'],
      'encoding': book.meta['encoding'],
      'added': book.meta['added'],
      'size': await File(p.join(book.dir.path, 'original')).length(),
      'position': lib.saved(book),
      'marks': lib.bookmarks[book.id] ?? [],
    });
  }
  _validateEntries(entries);
  final manifest = utf8.encode(
    jsonEncode({
      'books': entries,
      'settings': lib.settings,
      if (lib.hubShelf.isNotEmpty)
        'hubShelf': [
          for (final book in lib.hubShelf)
            {
              'meta': book.meta,
              'position': lib.saved(book),
              'marks': lib.marks(book),
            },
        ],
    }),
  );
  _require(manifest.length <= _maxManifest, '阅读记录超过本版 16 MiB 清单上限');
  final length = ByteData(4)..setUint32(0, manifest.length);
  final output = await destination.open(mode: FileMode.write);
  try {
    await output.writeFrom(_signature);
    await output.writeFrom(length.buffer.asUint8List());
    await output.writeFrom(manifest);
    await output.writeFrom(sha256.convert(manifest).bytes);
    for (var i = 0; i < books.length; i++) {
      final book = books[i];
      report('正在备份 ${i + 1} / ${books.length} · ${book.title}');
      final source = File(p.join(book.dir.path, 'original'));
      _require(
        await _copy(source.openRead(), output) == book.id,
        '《${book.title}》的托管原书校验失败',
      );
      for (final c in entries[i]['cached'] ?? []) {
        _require(
          await _copy(book.cachedText(c['index']).openRead(), output) ==
              c['digest'],
          '章节缓存校验失败',
        );
      }
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

class BackupSummary {
  const BackupSummary(this.books, this.positions, this.marks);
  final int books, positions, marks;
}

Future<BackupSummary> stageBackup(
  Library lib,
  File source,
  BackupProgress report,
) async {
  final input = await source.open();
  final stage = Library(lib.restoreStage);
  try {
    final header = await _read(input, _signature.length);
    _require(
      ascii.decode(header, allowInvalid: true) == ascii.decode(_signature),
      '请选择受支持的 NamiRead 备份文件',
    );
    final bytes = ByteData.sublistView(await _read(input, 4)).getUint32(0);
    _require(bytes <= _maxManifest, '备份清单超过本版上限');
    final manifest = await _read(input, bytes);
    _require(
      sha256.convert(manifest).toString() ==
          Digest(await _read(input, 32)).toString(),
      '备份清单校验失败',
    );
    final raw = jsonDecode(utf8.decode(manifest));
    _require(raw is Data && raw['books'] is List, '备份清单无效');
    final entries = raw['books'] as List, settings = _settings(raw['settings']);
    _validateEntries(entries);
    var offset = await input.position();
    final total = entries.fold<int>(
      offset,
      (sum, e) =>
          sum +
          (e['size'] as int) +
          ((e['cached'] as List?) ?? []).fold<int>(
            0,
            (n, c) => n + (c['size'] as int),
          ),
    );
    _require(await input.length() == total, '备份文件长度不符，可能尚未写完或已损坏');
    if (await stage.root.exists()) await stage.root.delete(recursive: true);
    await stage.load();
    stage.settings = settings;
    var markCount = 0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i], size = e['size'] as int;
      report('正在校验并重建 ${i + 1} / ${entries.length} · ${e['name']}');
      final dir = await stage.staging.createTemp('book-');
      final output = await File(p.join(dir.path, 'original'))
          .open(mode: FileMode.write);
      try {
        final digest = await _copy(
          source.openRead(offset, offset + size),
          output,
        );
        _require(digest == e['id'], '《${e['name']}》的原书校验失败');
        await output.flush();
      } finally {
        await output.close();
      }
      offset += size;
      if (p.extension(e['name']).toLowerCase() == '.txt') {
        await platform.invokeMethod('decode', {
          'dir': dir.path,
          'encoding': e['encoding'],
        });
      }
      final meta = p.extension(e['name']).toLowerCase() == '.namiweb'
          ? sourceBookMeta(
              Data.from(
                jsonDecode(
                  await File(p.join(dir.path, 'original')).readAsString(),
                ),
              ),
              e['id'],
            )
          : await prepareBook(
              dir,
              name: e['name'],
              id: e['id'],
              encoding: e['encoding'],
            );
      meta['added'] = e['added'];
      if (e['hubDownload'] == true) meta['hubDownload'] = true;
      final book = await stage.commit(dir, meta);
      for (final c in e['cached'] ?? []) {
        _require(c['index'] < book.chapters.length, '缓存章节不在目录中');
        final end = offset + (c['size'] as int);
        final dest = await book
            .cachedText(c['index'])
            .open(mode: FileMode.write);
        try {
          _require(
            await _copy(source.openRead(offset, end), dest) == c['digest'],
            '章节缓存校验失败',
          );
        } finally {
          await dest.close();
        }
        offset = end;
      }
      final point = e['position'];
      if (point != null) {
        _validatePoint(point, book, progress: true);
        stage.positions[book.id] = point;
      }
      final marks = e['marks'] as List;
      for (final mark in marks) {
        _validatePoint(mark, book, progress: false);
      }
      if (marks.isNotEmpty) stage.bookmarks[book.id] = marks;
      markCount += marks.length;
    }
    final references = raw['hubShelf'] ?? [];
    _require(references is List, '共享书目清单无效');
    for (final record in references) {
      _require(
        record is Data && record['meta'] is Data && record['marks'] is List,
        '共享书目无效',
      );
      final m = record['meta'] as Data;
      _require(
        m['hubId'] is String &&
            m['hubItem'] is Data &&
            m['added'] is int &&
            m['title'] is String &&
            m['author'] is String &&
            m['sourceName'] is String &&
            ['TXT', 'EPUB'].contains(m['format']),
        '共享书目信息无效',
      );
      final item = HubResource.fromJson(m['hubItem']);
      final id = HubLibrary.originKey(
        HubLibrary.originKey(m['hubId'], item.id),
        item.version,
      );
      _require(
        m['id'] == id && stage.hubReference(id) == null && item.type == 'book',
        '共享书目身份无效',
      );
      for (final list in [m['chapters'], m['toc']]) {
        _require(
          list is List &&
              list.isNotEmpty &&
              list.length <= 12000 &&
              list.every(
                (c) =>
                    c is Data &&
                    c['resource'] is String &&
                    c['title'] is String,
              ),
          '共享目录无效',
        );
      }
      final book = stage.hubBook({
        for (final key in [
          'id',
          'added',
          'hubId',
          'hubItem',
          'format',
          'title',
          'author',
          'sourceName',
          'chapters',
          'toc',
        ])
          key: m[key],
      });
      await stage.saveHubReference(book);
      final point = record['position'];
      if (point != null) {
        _validatePoint(point, book, progress: true);
        stage.positions[id] = point;
      }
      final marks = record['marks'] as List;
      for (final mark in marks) {
        _validatePoint(mark, book, progress: false);
      }
      stage.bookmarks[id] = marks;
      markCount += marks.length;
    }
    await stage.persist();
    final error = stage.storageError;
    if (error != null) throw FileSystemException(error);
    return BackupSummary(
      stage.shelfBooks.length,
      stage.positions.length,
      markCount,
    );
  } finally {
    await input.close();
    stage.dispose();
  }
}
