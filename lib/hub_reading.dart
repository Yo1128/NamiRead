import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:nami_hub_client/nami_hub_client.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'hub_zip.dart';
import 'library.dart';
import 'parser.dart';

class HubReading {
  HubReading._(this.meta, this._zip, this._types);
  final Data meta;
  final HubZip? _zip;
  final Map<String, String?> _types;
  static const block = 32768;
  static const imageTypes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  };

  static Future<HubReading> open(
    String hostId,
    HubResource item,
    String id,
    HubBytes read,
  ) async {
    if (item.size == 0 || item.size > 96 << 20) {
      throw const FormatException('请选择非空且不超过 96 MiB 的 TXT 或 EPUB。');
    }
    final isTxt = p.extension(item.name).toLowerCase() == '.txt';
    final chapters = <Data>[], toc = <Data>[];
    final meta = <String, dynamic>{
      'id': id,
      'added': DateTime.now().millisecondsSinceEpoch,
      'title': p.basenameWithoutExtension(item.name),
      'author': '作者未知',
      'format': isTxt ? 'TXT' : 'EPUB',
      'hubId': hostId,
      'sourceName': item.name,
      'hubItem': {
        'resourceId': item.id,
        'contentVersion': item.version,
        'sha256': item.digest,
        'type': 'book',
        'mimeType': item.mimeType,
        'sizeBytes': item.size,
        'displayName': item.name,
      },
      'chapters': chapters,
      'toc': toc,
    };
    if (isTxt) {
      for (var offset = 0; offset < item.size; offset += block) {
        chapters.add({
          'resource': 'byte:$offset',
          'title': offset == 0 ? '正文' : '正文 · 第 ${chapters.length + 1} 段',
        });
      }
      meta['toc'] = chapters;
      return HubReading._(meta, null, {});
    }
    final zip = await HubZip.open(item.size, read);
    Future<String> xml(String path) async =>
        utf8.decode(await zip.member(path, read));
    final container = XmlDocument.parse(await xml('META-INF/container.xml'));
    final opf = epubElements(
      container,
      'rootfile',
    ).firstOrNull?.getAttribute('full-path');
    if (opf == null) throw const FormatException('EPUB 缺少书籍清单。');
    final package = XmlDocument.parse(await xml(opf));
    if (epubElements(package, 'meta').any(
      (e) =>
          e.getAttribute('property') == 'rendition:layout' &&
          e.innerText.trim() == 'pre-paginated',
    )) {
      throw const FormatException('暂不支持固定版式 EPUB。');
    }
    for (final pair in [('title', 'title'), ('creator', 'author')]) {
      final value = epubElements(
        package,
        pair.$1,
      ).firstOrNull?.innerText.trim();
      if (value != null && value.isNotEmpty) meta[pair.$2] = value;
    }
    final items = {
      for (final e in epubElements(package, 'item')) e.getAttribute('id'): e,
    };
    String pathOf(XmlElement e) =>
        epubTarget(opf, e.getAttribute('href') ?? '');
    final types = {
      for (final e in items.values) pathOf(e): e.getAttribute('media-type'),
    };
    final nav = items.values
        .where(
          (e) =>
              (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
        )
        .firstOrNull;
    final ncx = items.values
        .where(
          (e) => e.getAttribute('media-type') == 'application/x-dtbncx+xml',
        )
        .firstOrNull;
    if (nav != null) {
      final path = pathOf(nav), doc = html.parse(await xml(path));
      final navs = doc.querySelectorAll('nav');
      final node =
          navs
              .where(
                (e) =>
                    e.attributes['epub:type'] == 'toc' ||
                    e.attributes['role'] == 'doc-toc',
              )
              .firstOrNull ??
          navs.firstOrNull;
      for (final link in node?.querySelectorAll('a[href]') ?? []) {
        toc.add({
          'title': link.text.trim(),
          'resource': epubTarget(path, link.attributes['href']!),
        });
      }
    } else if (ncx != null) {
      final path = pathOf(ncx), navDoc = XmlDocument.parse(await xml(path));
      for (final entry in epubElements(navDoc, 'navPoint')) {
        final src = epubElements(
          entry,
          'content',
        ).firstOrNull?.getAttribute('src');
        if (src != null) {
          toc.add({
            'title': epubElements(entry, 'text').firstOrNull?.innerText ?? '章节',
            'resource': epubTarget(path, src),
          });
        }
      }
    }
    final titles = <String, String>{};
    for (final e in toc) {
      titles.putIfAbsent(
        (e['resource'] as String).split('#').first,
        () => e['title'],
      );
    }
    for (final ref in epubElements(package, 'itemref')) {
      final e = items[ref.getAttribute('idref')];
      if (e == null || zip.sizeOf(pathOf(e)) == null) {
        throw const FormatException('EPUB 正文索引无效。');
      }
      final path = pathOf(e);
      chapters.add({
        'resource': path,
        'title': titles[path] ?? '第 ${chapters.length + 1} 章',
      });
    }
    if (chapters.isEmpty) throw const FormatException('EPUB 没有可阅读的章节。');
    final paths = {for (final c in chapters) c['resource']};
    toc.removeWhere(
      (t) => !paths.contains((t['resource'] as String).split('#').first),
    );
    if (toc.isEmpty) meta['toc'] = chapters;
    return HubReading._(meta, zip, types);
  }

  Future<String> chapter(int index, HubBytes read) async {
    final zip = _zip;
    if (zip == null) return _text(index, read);
    final path = meta['chapters'][index]['resource'] as String;
    final body = html.parse(utf8.decode(await zip.member(path, read))).body;
    if (body == null) throw const FormatException('章节缺少正文。');
    final images = <String, String>{};
    var budget = 0;
    for (final node in body.querySelectorAll('img,image')) {
      final key = epubTarget(
        path,
        node.attributes['src'] ??
            node.attributes['href'] ??
            node.attributes['xlink:href'] ??
            '',
      );
      final mime = _types[key], size = zip.sizeOf(key);
      if (!imageTypes.contains(mime) ||
          size == null ||
          images.containsKey(key)) {
        continue;
      }
      budget += size;
      if (budget > 20 << 20) throw const FormatException('单章插图超过读取上限。');
      images[key] =
          'data:$mime;base64,${base64Encode(await zip.member(key, read))}';
    }
    return epubMarkup(body, path, (key) => images[key]);
  }

  Future<String> _text(int index, HubBytes read) async {
    final size = meta['hubItem']['sizeBytes'] as int, start = index * block;
    final count = math.min(size - start, block + 1028);
    final bytes = await read(start, count);
    // Both adjacent pages choose exactly the same boundary from the same lookahead.
    int boundary(int nominal) {
      if (nominal + start >= size) return bytes.length;
      for (var i = nominal; i < math.min(nominal + 1024, bytes.length); i++) {
        if (bytes[i] == 10) return i + 1;
      }
      var i = nominal;
      while (i < bytes.length && (bytes[i] & 0xc0) == 0x80) {
        i++;
      }
      return i;
    }

    final first = start == 0 ? 0 : boundary(0), last = boundary(block);
    String text;
    try {
      text = utf8.decode(Uint8List.sublistView(bytes, first, last));
      if (text.contains('\u0000')) throw const FormatException();
    } on FormatException {
      throw const FormatException('这本 TXT 的编码暂不支持在线阅读，可在书目中选择「下载到本机」并指定编码。');
    }
    return const LineSplitter()
        .convert(text)
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          final value = line.trim(),
              tag = headingPattern.hasMatch(value) ? 'h2' : 'p';
          return '<$tag>${escape.convert(value)}</$tag>';
        })
        .join();
  }
}
