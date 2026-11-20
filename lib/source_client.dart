import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'library.dart';
import 'source_model.dart';
import 'source_rules.dart';

typedef SourcePage = ({Uri url, String body});

class SourceResponseError extends HttpException {
  SourceResponseError(Uri url, this.status)
    : super('${url.host} 返回 HTTP $status', uri: url);
  final int status;
}

String sourceError(Object error) => switch (error) {
  SocketException() => '无法连接书源，请检查网络或书源地址',
  HandshakeException() => '无法验证书源的安全连接',
  TimeoutException() => '书源响应超时，请稍后重试',
  HttpException() => error.message,
  FormatException() => error.message,
  FileSystemException() => '读写书源文件失败，请检查存储空间',
  PlatformException() => error.message ?? '系统未能读取书源文件',
  _ => '书源处理失败：$error',
};

class SourceClient {
  final _requests = <HttpClient>{};
  bool _closed = false;
  void close() {
    _closed = true;
    for (final client in _requests) {
      client.close(force: true);
    }
  }

  Future<SourcePage> fetch(
    Uri address, {
    Data? source,
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
    int limit = maxChapterBytes,
  }) async {
    if (_closed) throw const HttpException('请求已取消');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'NamiRead/0.5 (Android reader)';
    _requests.add(client);
    Future<SourcePage> request() async {
      var uri = address;
      for (var n = 0; n < 6; n++) {
        final req = await client.openUrl(method, uri);
        req.followRedirects = false;
        final raw = source?['header'];
        final fields = raw is String && raw.trim().isNotEmpty
            ? jsonDecode(raw)
            : raw;
        final combined = {if (fields is Map) ...fields, ...headers};
        for (final entry in combined.entries) {
          final name = entry.key.toString().toLowerCase();
          if (const {
            'host',
            'connection',
            'content-length',
            'transfer-encoding',
          }.contains(name)) {
            continue;
          }
          if (uri.origin !=
                  (source == null
                      ? address.origin
                      : webAddress(source['bookSourceUrl']).origin) &&
              !const {
                'accept',
                'user-agent',
                'accept-language',
                'content-type',
              }.contains(name)) {
            continue;
          }
          req.headers.set(name, entry.value.toString());
        }
        if (method == 'POST') {
          if (req.headers.contentType == null) {
            req.headers.set(
              'content-type',
              'application/x-www-form-urlencoded; charset=utf-8',
            );
          }
          req.add(utf8.encode(body ?? ''));
        }
        final response = await req.close();
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final next = response.headers.value('location');
          if (next == null) throw const FormatException('书源重定向缺少地址');
          final target = webAddress(next, uri);
          if (uri.scheme == 'https' && target.scheme != 'https') {
            throw const FormatException('书源重定向到了非加密地址');
          }
          if (target.origin != uri.origin &&
              method == 'POST' &&
              [307, 308].contains(response.statusCode)) {
            throw const FormatException('书源跨站重定向不能转发请求正文');
          }
          if ([301, 302, 303].contains(response.statusCode)) {
            method = 'GET';
            body = null;
          }
          // Redirect bodies are never used; cancel without buffering them.
          await response.listen((_) {}).cancel();
          uri = target;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw SourceResponseError(uri, response.statusCode);
        }
        if (response.contentLength > limit) {
          throw const FormatException('书源响应超过大小上限');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('书源响应超过大小上限');
          }
          bytes.add(chunk);
        }
        final data = bytes.takeBytes();
        final head = latin1.decode(data.take(1024).toList()).toLowerCase();
        final charset =
            (response.headers.contentType?.charset ??
                    RegExp(r'''charset\s*=\s*["']?([a-z0-9_-]+)''')
                        .firstMatch(head)
                        ?.group(1) ??
                    'utf-8')
                .toLowerCase();
        String text;
        if ([
          'gbk',
          'gb2312',
          'gb18030',
          'big5',
          'utf-16',
          'utf-16le',
          'utf-16be',
        ].contains(charset)) {
          text = (await platform.invokeMethod<String>('sourceDecode', {
            'bytes': data,
            'charset': charset,
          }))!;
        } else if (charset == 'iso-8859-1') {
          text = latin1.decode(data);
        } else {
          text = utf8.decode(data);
        }
        return (url: uri, body: text.replaceFirst('\uFEFF', ''));
      }
      throw const FormatException('书源重定向次数过多');
    }

    try {
      return await request().timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
      _requests.remove(client);
    }
  }

  Future<Data> _parse(SourcePage page, Data source, String kind, String key) =>
      parseSourcePage({
        'url': page.url.toString(),
        'key': key,
        'kind': kind,
        'body': page.body,
        'rules':
            source[{
              'search': 'ruleSearch',
              'detail': 'ruleBookInfo',
              'toc': 'ruleToc',
              'content': 'ruleContent',
            }[kind]],
      });

  Future<List<Data>> search(
    Data source,
    String key, {
    int pageNumber = 1,
  }) async {
    final template = (source['searchUrl'] as String)
        .replaceAll('{{key}}', Uri.encodeQueryComponent(key))
        .replaceAll('{{page}}', pageNumber.toString());
    final split = RegExp(r',\s*(?=\{)').firstMatch(template);
    final opts = split == null
        ? <String, dynamic>{}
        : jsonDecode(template.substring(split.end)) as Map;
    final method = (opts['method'] ?? 'GET').toString().toUpperCase();
    if (!{'GET', 'POST'}.contains(method)) {
      throw const FormatException('搜索支持 GET 和 POST');
    }
    final page = await fetch(
      webAddress(
        split == null ? template : template.substring(0, split.start),
        webAddress(source['bookSourceUrl']),
      ),
      source: source,
      method: method,
      body: opts['body']?.toString(),
      headers: Map<String, String>.from(opts['headers'] ?? {}),
    );
    final result = await _parse(page, source, 'search', key);
    return _resolveRows(result, page.url);
  }

  List<Data> _resolveRows(Data result, Uri base) {
    final rows = <Data>[];
    for (final row in result['rows']) {
      try {
        rows.add({
          ...Data.from(row),
          'url': webAddress(row['url'], base).toString(),
        });
      } on FormatException {
        continue;
      }
    }
    return rows;
  }

  Stream<({SourcePage page, Data parsed})> _pages(
    Data source,
    Uri start,
    String kind,
  ) async* {
    var url = start;
    final visited = <String>{};
    while (visited.add(url.toString())) {
      if (visited.length > 50) throw const FormatException('书源分页超过 50 页');
      final page = await fetch(url, source: source);
      final parsed = await _parse(page, source, kind, '');
      yield (page: page, parsed: parsed);
      final next = (parsed['next'] as String?)?.trim() ?? '';
      if (next.isEmpty) break;
      url = webAddress(next, page.url);
    }
  }

  Future<List<Data>> catalog(Data source, Data result) async {
    var uri = webAddress(result['url']);
    final info = source['ruleBookInfo'];
    final rule = info is Map ? info['tocUrl'] : null;
    if ((rule is String && rule.trim().isNotEmpty) ||
        (rule is List && rule.isNotEmpty)) {
      final detail = await fetch(uri, source: source);
      final match = await _parse(detail, source, 'detail', '');
      if ((match['url'] as String).isEmpty) {
        throw const FormatException('详情规则没有找到目录地址');
      }
      uri = webAddress(match['url'], detail.url);
    }
    final chapters = <Data>[], seen = <String>{};
    await for (final part in _pages(source, uri, 'toc')) {
      for (final row in _resolveRows(part.parsed, part.page.url)) {
        if (seen.add(row['url'])) chapters.add(row);
      }
      if (chapters.length > 10000) {
        throw const FormatException('本书目录超过 10000 章');
      }
    }
    if (chapters.isEmpty) throw const FormatException('未解析到章节，请检查目录规则');
    return chapters;
  }

  Future<Book> shelve(
    Library lib,
    Data source,
    Data result,
    List<Data> chapters,
  ) async {
    Book? existing() => lib.books
        .where(
          (b) =>
              b.meta['bookSourceUrl'] == source['bookSourceUrl'] &&
              b.meta['bookUrl'] == result['url'],
        )
        .firstOrNull;
    final saved = existing();
    if (saved != null) return saved;
    final catalog = {
      'source': source['bookSourceUrl'],
      'bookUrl': result['url'],
      'title': result['title'],
      'author': result['author'],
      'chapters': chapters,
    };
    final bytes = utf8.encode(jsonEncode(catalog));
    if (bytes.length > maxChapterBytes) throw const FormatException('书源目录过大');
    final id = sha256.convert(bytes).toString(),
        stage = await lib.staging.createTemp('source-');
    try {
      await File(p.join(stage.path, 'original'))
          .writeAsBytes(bytes, flush: true);
      try {
        return await lib.commit(stage, sourceBookMeta(catalog, id));
      } on FormatException {
        final book = existing();
        if (book != null) return book;
        rethrow;
      }
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  Future<String> chapter(Library lib, Book book, int index) async {
    final text = await chapterText(lib, book, index);
    return const LineSplitter()
        .convert(text)
        .where((p) => p.trim().isNotEmpty)
        .map((p) => '<p>${const HtmlEscape().convert(p)}</p>')
        .join();
  }

  Future<String> chapterText(Library lib, Book book, int index) async {
    final cache = book.cachedText(index);
    String text;
    if (await cache.exists()) {
      text = await cache.readAsString();
    } else {
      final source = configuredSources(lib.settings)
          .where(
            (s) =>
                s['bookSourceUrl'] == book.meta['bookSourceUrl'] &&
                s['enabled'] != false,
          )
          .firstOrNull;
      if (source == null) {
        throw const FormatException('此章尚未缓存，请在书源管理中启用或重新导入原书源');
      }
      final buffer = StringBuffer();
      var bytes = 0;
      await for (final part in _pages(
        source,
        webAddress(book.chapters[index]['url']),
        'content',
      )) {
        final content = part.parsed['text'] as String;
        bytes += utf8.encode(content).length + 1;
        if (bytes > maxChapterBytes) {
          throw const FormatException('章节正文超过 4 MiB');
        }
        buffer.writeln(content);
      }
      text = buffer.toString().trim();
      if (text.isEmpty) throw const FormatException('未解析到正文，请检查正文规则');
      if (_closed) throw const HttpException('请求已取消');
      text = await lib.cacheSourceText(book, index, text);
    }
    return text;
  }
}
