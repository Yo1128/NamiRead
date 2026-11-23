import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'library.dart';

const escape = HtmlEscape();
final headingPattern = RegExp(
  r'^(第[〇零一二两三四五六七八九十百千万0-9０-９]+[章回节卷部篇].{0,60}|序章|序言|楔子|后记|尾声|Chapter\s+\d+.{0,55})$',
  caseSensitive: false,
);

Future<Data> parseBook(Data input) async {
  final dir = Directory(input['dir']), name = input['name'] as String;
  final meta = <String, dynamic>{
    'schema': 1,
    'id': input['id'],
    'sourceName': name,
    'sourceUri': input['uri'],
    'added': DateTime.now().millisecondsSinceEpoch,
    'title': p.basenameWithoutExtension(name),
    'author': '作者未知',
    'cover': false,
  };
  switch (p.extension(name).toLowerCase()) {
    case '.txt':
      meta['format'] = 'TXT';
      meta['encoding'] = input['encoding'];
      await _txt(dir, meta);
    case '.epub':
      meta['format'] = 'EPUB';
      try {
        await _epub(dir, meta);
      } on ArchivePasswordException {
        throw const FormatException('该 EPUB 需要密码，请选择无加密版本');
      } on ArchiveException {
        throw const FormatException('EPUB 压缩包不完整或已损坏，请重新选择完整文件');
      }
    default:
      throw const FormatException('请选择 TXT 或 EPUB 文件');
  }
  return meta;
}

Future<void> _txt(Directory dir, Data meta) async {
  final chapters = <Data>[], decoded = File(p.join(dir.path, 'decoded.txt'));
  var title = '正文', count = 0;
  IOSink? writer;
  Future<void> finish() async {
    if (writer == null) return;
    await writer!.flush();
    await writer!.close();
    writer = null;
    chapters.add({'title': title, 'resource': 'txt:${chapters.length}'});
    count = 0;
  }

  await for (final raw
      in decoded
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final line = raw.trim().replaceFirst(RegExp('^\uFEFF'), '');
    if (line.isEmpty) continue;
    if (headingPattern.hasMatch(line)) {
      await finish();
      title = line;
      continue;
    }
    var start = 0;
    while (start < line.length) {
      var end = (start + 8000).clamp(0, line.length);
      if (end < line.length &&
          line.codeUnitAt(end - 1) >= 0xd800 &&
          line.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      if (count >= 180000) {
        await finish();
        if (!title.endsWith('（续）')) title = '$title（续）';
      }
      writer ??= File(p.join(dir.path, 'chapter-${chapters.length}.html'))
          .openWrite();
      writer!.write('<p>${escape.convert(line.substring(start, end))}</p>');
      count += end - start;
      start = end;
    }
  }
  await finish();
  if (chapters.isEmpty) throw const FormatException('TXT 没有可阅读的正文');
  meta['chapters'] = chapters;
  meta['toc'] = chapters;
  await decoded.delete();
}

Iterable<XmlElement> epubElements(XmlNode node, String tag) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == tag);
String epubTarget(String source, String ref) {
  final uri = Uri.tryParse(ref);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.path.startsWith('/')) {
    return '';
  }
  final path = uri.path.isEmpty
      ? source
      : p.posix.normalize(
          p.posix.join(p.posix.dirname(source), Uri.decodeComponent(uri.path)),
        );
  if (path.startsWith('../') || path.contains('\\') || path.startsWith('/')) {
    return '';
  }
  return uri.hasFragment ? '$path#${Uri.decodeComponent(uri.fragment)}' : path;
}

Future<void> _epub(Directory dir, Data meta) async {
  final stream = InputFileStream(p.join(dir.path, 'original'));
  try {
    final archive = ZipDecoder().decodeStream(stream, throwOnError: true);
    final entries = <String, ArchiveFile>{};
    var total = 0;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').contains('..') ||
          f.isSymbolicLink) {
        throw const FormatException('EPUB 包含无效资源路径');
      }
      total += f.size;
      if (total > (192 << 20) ||
          f.size > (24 << 20) ||
          entries.length > 12000) {
        throw const FormatException('EPUB 资源超过本版读取上限');
      }
      entries[name] = f;
    }
    String read(String path) {
      final f = entries[path];
      if (f == null) throw FormatException('缺少书内资源：$path');
      return utf8.decode(f.content).replaceFirst(RegExp('^\uFEFF'), '');
    }

    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final root = epubElements(
      container,
      'rootfile',
    ).firstOrNull?.getAttribute('full-path');
    if (root == null) throw const FormatException('EPUB 未提供内容清单');
    final package = XmlDocument.parse(read(root));
    if (epubElements(package, 'meta').any(
      (e) =>
          e.getAttribute('property') == 'rendition:layout' &&
          e.innerText.trim() == 'pre-paginated',
    )) {
      throw const FormatException('暂不支持固定版式 EPUB');
    }
    final title = epubElements(package, 'title').firstOrNull?.innerText.trim();
    final author = epubElements(
      package,
      'creator',
    ).firstOrNull?.innerText.trim();
    if (title?.isNotEmpty == true) meta['title'] = title;
    if (author?.isNotEmpty == true) meta['author'] = author;
    final items = {
      for (final item in epubElements(package, 'item'))
        item.getAttribute('id'): item,
    };
    String pathOf(XmlElement item) =>
        epubTarget(root, item.getAttribute('href') ?? '');
    final types = {
      for (final item in items.values)
        pathOf(item): item.getAttribute('media-type'),
    };
    final coverId = epubElements(package, 'meta')
        .where((e) => e.getAttribute('name') == 'cover')
        .firstOrNull
        ?.getAttribute('content');
    final cover =
        items.values
            .where(
              (e) => (e.getAttribute('properties') ?? '')
                  .split(' ')
                  .contains('cover-image'),
            )
            .firstOrNull ??
        (coverId == null ? null : items[coverId]);
    const acceptedImages = {
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    };
    if (cover != null &&
        acceptedImages.contains(types[pathOf(cover)]) &&
        entries.containsKey(pathOf(cover))) {
      await File(p.join(dir.path, 'cover.img'))
          .writeAsBytes(entries[pathOf(cover)]!.content);
      meta['cover'] = true;
    }
    final toc = <Data>[];
    final nav = items.values
        .where(
          (e) =>
              (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
        )
        .firstOrNull;
    if (nav != null) {
      final path = pathOf(nav),
          doc = html.parse(read(path)),
          navs = doc.querySelectorAll('nav');
      final node =
          navs
              .where(
                (e) =>
                    e.attributes['epub:type'] == 'toc' ||
                    e.attributes['role'] == 'doc-toc',
              )
              .firstOrNull ??
          navs.firstOrNull;
      for (final a in node?.querySelectorAll('a[href]') ?? <dom.Element>[]) {
        toc.add({
          'title': a.text.trim(),
          'resource': epubTarget(path, a.attributes['href']!),
        });
      }
    } else {
      final ncx = items.values
          .where(
            (e) => e.getAttribute('media-type') == 'application/x-dtbncx+xml',
          )
          .firstOrNull;
      if (ncx != null) {
        final path = pathOf(ncx);
        for (final point in epubElements(
          XmlDocument.parse(read(path)),
          'navPoint',
        )) {
          final src = epubElements(
            point,
            'content',
          ).firstOrNull?.getAttribute('src');
          if (src != null) {
            toc.add({
              'title':
                  epubElements(point, 'text').firstOrNull?.innerText ?? '章节',
              'resource': epubTarget(path, src),
            });
          }
        }
      }
    }
    final chapters = <Data>[];
    for (final ref in epubElements(package, 'itemref')) {
      final item = items[ref.getAttribute('idref')];
      if (item == null) throw const FormatException('EPUB 正文顺序引用了缺失资源');
      final path = pathOf(item), doc = html.parse(read(path)), body = doc.body;
      if (body == null) continue;
      final heading = body.querySelector('h1,h2,h3')?.text.trim();
      final name =
          toc
              .where((x) => (x['resource'] as String).split('#').first == path)
              .firstOrNull?['title'] ??
          heading ??
          doc.querySelector('title')?.text.trim();
      var imageBudget = 0;
      final fragment = epubMarkup(body, path, (key) {
        final file = entries[key], mime = types[key];
        if (file == null || !acceptedImages.contains(mime)) return null;
        imageBudget += file.size;
        if (imageBudget > (20 << 20)) throw const FormatException('单章插图超过读取上限');
        return 'data:$mime;base64,${base64Encode(file.content)}';
      });
      if (fragment.trim().isEmpty) continue;
      await File(p.join(dir.path, 'chapter-${chapters.length}.html'))
          .writeAsString(fragment);
      chapters.add({
        'resource': path,
        'title': name == null || name.isEmpty
            ? '第 ${chapters.length + 1} 章'
            : name,
      });
    }
    if (chapters.isEmpty) throw const FormatException('EPUB 未找到可阅读章节');
    final resources = chapters.map((c) => c['resource']).toSet();
    toc.removeWhere(
      (t) => !resources.contains((t['resource'] as String).split('#').first),
    );
    meta['chapters'] = chapters;
    meta['toc'] = toc.isEmpty ? chapters : toc;
  } finally {
    await stream.close();
  }
}

String epubMarkup(
  dom.Element body,
  String path,
  String? Function(String) image,
) {
  String clean(dom.Node n) {
    if (n is dom.Text) return escape.convert(n.data);
    if (n is! dom.Element) return '';
    final tag = n.localName ?? '';
    if ({
      'script',
      'style',
      'object',
      'iframe',
      'form',
      'video',
      'audio',
      'canvas',
      'noscript',
      'link',
      'meta',
    }.contains(tag)) {
      return '';
    }
    final id = n.id.isEmpty ? '' : ' id="${escape.convert(n.id)}"';
    if (tag == 'img' || tag == 'image') {
      final key = epubTarget(
        path,
        n.attributes['src'] ??
            n.attributes['href'] ??
            n.attributes['xlink:href'] ??
            '',
      );
      final src = image(key);
      if (src == null) return '';
      return '<img$id alt="${escape.convert(n.attributes['alt'] ?? '插图')}" src="$src">';
    }
    final children = n.nodes.map(clean).join();
    if (tag == 'a') {
      final target = epubTarget(path, n.attributes['href'] ?? '');
      return '<a$id data-target="${escape.convert(target)}" href="#">$children</a>';
    }
    if (tag == 'br' || tag == 'hr') return '<$tag>';
    const allowed = {
      'p',
      'div',
      'section',
      'article',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'em',
      'strong',
      'b',
      'i',
      'blockquote',
      'ol',
      'ul',
      'li',
      'sup',
      'sub',
      'ruby',
      'rt',
      'rp',
      'figure',
      'figcaption',
      'aside',
      'span',
      'pre',
      'code',
      'table',
      'tr',
      'td',
      'th',
      'dl',
      'dt',
      'dd',
    };
    final safe = allowed.contains(tag) ? tag : 'span';
    return '<$safe$id>$children</$safe>';
  }

  return body.nodes.map(clean).join();
}
