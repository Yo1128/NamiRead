import 'dart:convert';

import 'library.dart';

const maxSourceBytes = 1 << 20;
const maxChapterBytes = 4 << 20;

Uri webAddress(String value, [Uri? base]) {
  final uri = base == null
      ? Uri.tryParse(value.trim())
      : base.resolve(value.trim());
  if (uri == null ||
      !{'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('书源地址需要有效的 HTTP 或 HTTPS 链接');
  }
  return uri;
}

const wikiSource = <String, dynamic>{
  'bookSourceName': '中文维基文库',
  'bookSourceUrl': 'https://zh.wikisource.org',
  'enabled': true,
  'searchUrl': '/w/api.php?action=query&list=search&srnamespace=0&srlimit=30&format=json&srsearch={{key}}',
  'ruleSearch': {
    'bookList': r'$.query.search[*]',
    'name': r'$.title',
    'bookUrl': '@js:"/w/api.php?action=parse&format=json&prop=links%7Ctext&pageid="+result.pageid',
  },
  'ruleToc': {
    'chapterList': '''@js:const p=JSON.parse(result).parse;
const api="/w/api.php?action=parse&format=json&prop=text&";
const children=new Map(), prefix=p.title+"/";
for (const link of p.links || []) {
  const title=link["*"];
  if (link.ns!==0 || !("exists" in link) || !title.startsWith(prefix)) continue;
  const attr=title.replace(/&/g,"&amp;").replace(/"/g,"&quot;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
  children.set(attr,{title:title.slice(prefix.length),url:api+"page="+encodeURIComponent(title)});
}
const chapters=[];
for (const match of p.text["*"].matchAll(/<a [^>]*?title="([^"]+)"/gi)) {
  if (children.has(match[1])) {
    chapters.push(children.get(match[1]));
    children.delete(match[1]);
  }
}
chapters.length ? chapters : [{title:p.title,url:api+"pageid="+p.pageid}]''',
    'chapterName': r'$.title',
    'chapterUrl': r'$.url',
  },
  'ruleContent': {
    'content': [r'$.parse.text["*"]', '@css:.mw-parser-output@text'],
  },
};

void validateSource(dynamic raw) {
  if (raw is! Data) throw const FormatException('书源应为 JSON 对象');
  for (final field in ['bookSourceName', 'bookSourceUrl', 'searchUrl']) {
    if (raw[field] is! String || (raw[field] as String).trim().isEmpty) {
      throw FormatException('书源缺少 $field');
    }
  }
  webAddress(raw['bookSourceUrl']);
  if (raw['enabled'] != null && raw['enabled'] is! bool) {
    throw const FormatException('enabled 需要布尔值');
  }
  final header = raw['header'];
  if (header != null && header != '') {
    final fields = header is String ? jsonDecode(header) : header;
    if (fields is! Map ||
        fields.values.any((v) => v is! String && v is! num && v is! bool)) {
      throw const FormatException('header 需要包含请求头的 JSON 对象');
    }
  }
  void rule(dynamic value, String field) {
    if (value is String && value.trim().isNotEmpty) return;
    if (value is List &&
        value.isNotEmpty &&
        value.every((s) => s is String && s.trim().isNotEmpty)) {
      return;
    }
    throw FormatException('书源规则 $field 需要字符串或规则数组');
  }

  const requiredFields = {
    'ruleSearch': ['bookList', 'name', 'bookUrl'],
    'ruleToc': ['chapterList', 'chapterName', 'chapterUrl'],
    'ruleContent': ['content'],
  };
  for (final entry in requiredFields.entries) {
    final rules = raw[entry.key];
    if (rules is! Map) throw FormatException('书源缺少 ${entry.key}');
    for (final field in entry.value) {
      rule(rules[field], '${entry.key}.$field');
    }
  }
}

List<Data> decodeSources(
  String text, {
  void Function(String message)? onInvalid,
}) {
  if (utf8.encode(text).length > maxSourceBytes) {
    throw const FormatException('书源配置超过 1 MiB');
  }
  final raw = jsonDecode(text.trim().replaceFirst('\uFEFF', ''));
  final list = raw is List ? raw : [raw];
  if (list.isEmpty || list.length > 256) {
    throw const FormatException('请一次导入 1 到 256 个书源');
  }
  final sources = <Data>[];
  String? firstError;
  for (final (index, item) in list.indexed) {
    try {
      sources.add(validatedSource(item));
    } on FormatException catch (error) {
      final name = item is Map ? item['bookSourceName'] : null;
      final label = name is String && name.trim().isNotEmpty
          ? '「$name」'
          : '第 ${index + 1} 项';
      final message = '$label：${error.message}';
      if (onInvalid == null) throw FormatException(message);
      firstError ??= message;
      onInvalid(message);
    }
  }
  if (sources.isEmpty) throw FormatException(firstError!);
  return sources;
}

Data validatedSource(dynamic item) {
  validateSource(item);
  return Data.from(item);
}

List<Data> configuredSources(Data settings) {
  if (!settings.containsKey('bookSources')) return [Data.from(wikiSource)];
  final seen = <String>{};
  return (settings['bookSources'] as List)
      .map(validatedSource)
      .where((item) => seen.add(item['bookSourceUrl']))
      .toList();
}

Data sourceBookMeta(Data catalog, String id) {
  for (final key in ['title', 'source', 'bookUrl']) {
    if (catalog[key] is! String || (catalog[key] as String).trim().isEmpty) {
      throw FormatException('书源书目缺少 $key');
    }
  }
  webAddress(catalog['source']);
  webAddress(catalog['bookUrl']);
  final rows = catalog['chapters'];
  if (rows is! List || rows.isEmpty || rows.length > 10000) {
    throw const FormatException('书源目录需要 1 到 10000 章');
  }
  final chapters = <Data>[];
  for (final row in rows) {
    if (row is! Map || row['title'] is! String || row['url'] is! String) {
      throw const FormatException('书源目录条目无效');
    }
    chapters.add({
      'title': row['title'],
      'url': webAddress(row['url']).toString(),
      'resource': 'source:${chapters.length}',
    });
  }
  return {
    'schema': 1,
    'id': id,
    'sourceName': '${catalog['title']}.namiweb',
    'title': catalog['title'],
    'author':
        catalog['author'] is String && (catalog['author'] as String).isNotEmpty
        ? catalog['author']
        : '作者未知',
    'added': DateTime.now().millisecondsSinceEpoch,
    'format': '书源',
    'cover': false,
    'bookSourceUrl': catalog['source'],
    'bookUrl': catalog['bookUrl'],
    'chapters': chapters,
    'toc': chapters,
  };
}
