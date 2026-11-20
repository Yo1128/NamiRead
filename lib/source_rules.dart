import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:json_path/json_path.dart';
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

import 'library.dart';
import 'source_selectors.dart';
import 'source_script.dart';

class _ContentHtml {
  const _ContentHtml(this.html);
  final String html;
}

/// Raw markup stays in the parser. Only strings and JSON values leave its isolate.
class SourceRules {
  SourceRules(this.baseUrl, this.key);
  final String baseUrl, key;
  SourceScript? _js;
  void dispose() => _js?.dispose();

  List<dynamic> select(
    dynamic input,
    dynamic rule, {
    bool elementsOnly = false,
  }) => _select(input, rule, elementsOnly: elementsOnly);

  List<dynamic> _select(
    dynamic input,
    dynamic rule, {
    bool field = false,
    bool content = false,
    bool elementsOnly = false,
  }) {
    if (rule is List) {
      var values = <dynamic>[input];
      for (var i = 0; i < rule.length; i++) {
        final last = i == rule.length - 1;
        values = [
          for (final value in values)
            ..._select(
              value,
              rule[i],
              field: field,
              content: last && content,
              elementsOnly: last && elementsOnly,
            ),
        ];
        if (values.length > 12000) throw const FormatException('规则返回的条目过多');
      }
      return values;
    }
    if (rule is! String || rule.trim().isEmpty) return [];
    final expr = rule.trim(), lower = expr.toLowerCase();
    // JS and explicit regex are their own languages: their operators and
    // literal strings must never be tokenized as source-rule syntax.
    if (lower.startsWith('@js:') ||
        lower.startsWith('<js>') && lower.endsWith('</js>')) {
      final script = lower.startsWith('@js:')
          ? expr.substring(4)
          : expr.substring(4, expr.length - 5);
      return (_js ??= SourceScript(textOf)).run(
        input is XmlNode ? markup(input) : input,
        script.trim(),
        baseUrl,
        key,
      );
    }
    if (lower.startsWith('@regex:')) {
      final pattern = RegExp(expr.substring(7), multiLine: true, dotAll: true);
      return [
        for (final m in pattern.allMatches(markup(input)).take(12001))
          m.group(m.groupCount > 0 ? 1 : 0) ?? '',
      ];
    }

    // An inline script consumes the preceding selection. Leave its source
    // intact, including any "||", "&&" or "##" in the script itself.
    for (final marker in ['@js:', '<js>']) {
      final prefix = splitSourceRule(expr, marker).first;
      if (prefix.length < expr.length) {
        return _select(
          input,
          [prefix, expr.substring(prefix.length)],
          field: field,
          content: content,
          elementsOnly: elementsOnly,
        );
      }
    }
    if (lower.startsWith('@xpath:')) {
      return _xpath(input, expr.substring(7).trim());
    }
    final replace = splitSourceRule(expr, '##');
    if (replace.length > 1) {
      if (replace.length > 3) throw const FormatException('不支持的正则替换格式');
      final values = _select(
        input,
        replace.first,
        field: field,
        content: content,
        elementsOnly: elementsOnly,
      );
      final regex = RegExp(replace[1]);
      final replacement = replace.length == 3 ? replace[2] : '';
      return [
        for (final value in values)
          if (value is _ContentHtml)
            _ContentHtml(replaceSourceMatches(value.html, regex, replacement))
          else
            replaceSourceMatches(textOf(value), regex, replacement),
      ];
    }

    for (final op in ['||', '&&', '%%']) {
      final parts = splitSourceRule(expr, op);
      if (parts.length == 1) continue;
      final groups = <List<dynamic>>[];
      for (final part in parts) {
        final values = _select(
          input,
          part,
          field: field,
          content: content,
          elementsOnly: elementsOnly,
        );
        if (op == '||') {
          if (values.any((v) => v is! String || v.trim().isNotEmpty)) {
            return values;
          }
        } else {
          groups.add(values);
        }
      }
      if (op == '%%' && groups.isNotEmpty) {
        return [
          for (var i = 0; i < groups.first.length; i++)
            for (final group in groups)
              if (i < group.length) group[i],
        ];
      }
      return groups.expand((g) => g).toList();
    }

    if (expr.contains(r'{$.') || expr.contains('{{')) {
      final placeholders = RegExp(r'\{\{([\s\S]+?)\}\}|\{(\$\.[^{}]+)\}');
      if (placeholders.hasMatch(expr)) {
        return [
          expr.replaceAllMapped(placeholders, (match) {
            final code = (match[1] ?? match[2]!).trim();
            final rule =
                code.startsWith('@') ||
                    code.startsWith(r'$') ||
                    code.startsWith('/')
                ? code
                : '@js:$code';
            return _select(input, rule, field: true).map(textOf).join('\n');
          }),
        ];
      }
    }
    if (expr.startsWith('/') || expr.startsWith('./')) {
      return _xpath(input, expr);
    }
    final json =
        lower.startsWith('@json:') ||
        lower.startsWith('@jsonpath:') ||
        expr.startsWith(r'$');
    if (json ||
        input is Map &&
            RegExp(r'^[\w-]+(?:\.[\w-]+|\[(?:\*|-?\d+)\])*$').hasMatch(expr)) {
      final path = expr.startsWith('@')
          ? expr.substring(expr.indexOf(':') + 1).trim()
          : json
          ? expr
          : r'$.' + expr;
      if (input is dom.Node ||
          input is String && input.trimLeft().startsWith('<')) {
        return [];
      }
      final data = input is String ? jsonDecode(input) : input;
      return [
        for (final match in JsonPath(path).read(data))
          if (match.value is List)
            ...(match.value as List)
          else if (match.value != null)
            match.value,
      ];
    }
    return _css(
      input,
      expr,
      field: field,
      content: content,
      elementsOnly: elementsOnly,
    );
  }

  List<dynamic> _xpath(dynamic input, String path) {
    final root = input is XmlNode ? input : _xml(input);
    return [
      for (final item in root.xpathEvaluate(path))
        if (item is XPathNode) item.node else item.stringValue,
    ];
  }

  List<dynamic> _css(
    dynamic input,
    String expr, {
    required bool field,
    required bool content,
    required bool elementsOnly,
  }) {
    final parts = splitSourceRule(
      expr.toLowerCase().startsWith('@css:') ? expr.substring(5).trim() : expr,
      '@',
    );
    final start = parts.first.isEmpty ? 1 : 0;
    final element = input is dom.Element
        ? input
        : input is XmlElement
        ? html.parseFragment(input.toXmlString()).children.firstOrNull
        : null;
    final last = parts.last.trim();
    const terminals = {
      'href',
      'src',
      'text',
      'html',
      'all',
      'ownText',
      'textNodes',
      'content',
      'data-src',
      'title',
      'value',
      'alt',
      'id',
      'class',
    };
    final hasSuffix =
        parts.length > 1 &&
        RegExp(r'^[\w:-]+$').hasMatch(last) &&
        (!elementsOnly ||
            parts.first.isEmpty ||
            terminals.contains(last) ||
            last.startsWith('data-'));
    final bareAttribute =
        field &&
        element != null &&
        (element.attributes.containsKey(last) ||
            const {
              'href',
              'src',
              'text',
              'html',
              'all',
              'ownText',
              'textNodes',
              'content',
              'data-src',
            }.contains(last));
    final attr = hasSuffix || bareAttribute ? last : null;
    final end = parts.length - (attr == null ? 0 : 1);
    List<dom.Node> roots = [element ?? html.parse(markup(input))];
    for (var i = start; i < end; i++) {
      roots = [
        for (final root in roots) ...sourceElements(root, parts[i].trim()),
      ];
      if (roots.length > 12000) throw const FormatException('规则返回的条目过多');
    }
    final result = <dynamic>[];
    for (final e in roots.whereType<dom.Element>()) {
      switch (attr) {
        case null:
          result.add(e);
        case 'text':
          result.add(textOf(e));
        case 'ownText' || 'textNodes':
          final texts = e.nodes
              .whereType<dom.Text>()
              .map((n) => n.data.trim())
              .where((s) => s.isNotEmpty);
          result.add(texts.join(attr == 'ownText' ? ' ' : '\n'));
        case 'html' || 'all':
          final value = attr == 'all' ? e.outerHtml : e.innerHtml;
          result.add(content ? _ContentHtml(value) : value);
        default:
          if (e.attributes[attr] != null) result.add(e.attributes[attr]!);
      }
    }
    return result;
  }

  static String markup(dynamic input) => switch (input) {
    dom.Element e => e.outerHtml,
    dom.Document d => d.outerHtml,
    XmlNode n => n.toXmlString(),
    String s => s,
    _ => jsonEncode(input),
  };

  static String textOf(dynamic value) {
    if (value is XmlAttribute) return value.value;
    if (value is XmlText) return value.value;
    if (value is XmlNode) {
      return textOf(html.parseFragment(value.toXmlString()));
    }
    if (value is! dom.Node) return value?.toString() ?? '';
    final output = StringBuffer();
    void visit(dom.Node node) {
      if (node is dom.Text) {
        output.write(node.data);
        return;
      }
      final tag = node is dom.Element ? node.localName : null;
      if (const {'script', 'style', 'noscript', 'template'}.contains(tag)) {
        return;
      }
      final block = const {
        'p',
        'div',
        'br',
        'li',
        'section',
        'h1',
        'h2',
        'h3',
        'article',
        'blockquote',
        'tr',
      }.contains(tag);
      if (block) output.writeln();
      for (final child in node.nodes) {
        visit(child);
      }
      if (block) output.writeln();
    }

    visit(value);
    return const LineSplitter()
        .convert(output.toString())
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
  }

  static XmlNode _xml(dynamic input) {
    if (input is String && input.trimLeft().startsWith('<?xml')) {
      return XmlDocument.parse(input);
    }
    final document = input is dom.Element
        ? input
        : html.parse(markup(input)).documentElement;
    if (document == null) throw const FormatException('网页没有文档根节点');
    XmlElement convert(dom.Element e) => XmlElement(
      XmlName.parts(e.localName!),
      [
        for (final a in e.attributes.entries)
          XmlAttribute(XmlName.qualified(a.key.toString()), a.value),
      ],
      [
        for (final n in e.nodes)
          if (n is dom.Text)
            XmlText(n.data)
          else if (n is dom.Element)
            convert(n),
      ],
    );
    return XmlDocument([convert(document)]);
  }

  String field(dynamic input, dynamic rule, {bool content = false}) =>
      _select(input, rule, field: true, content: content)
          .map(
            (v) => v is _ContentHtml
                ? textOf(html.parseFragment(v.html))
                : textOf(v),
          )
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join('\n');
}

/// Bound the whole rule job as well as individual JS evaluations. In particular
/// user regular expressions and XPath queries never run on Flutter's UI isolate.
Future<Data> parseSourcePage(Data request) async {
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _parseInWorker,
      (port.sendPort, request),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final result = await port.first.timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw const FormatException('书源解析超时，请检查规则'),
    );
    if (result is Map && result['data'] is Map) {
      return Data.from(result['data']);
    }
    throw FormatException(
      result is Map ? result['error'].toString() : '书源解析中断',
    );
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _parseInWorker((SendPort, Data) args) {
  final (port, q) = args;
  final evaluator = SourceRules(q['url'], q['key'] ?? '');
  var activeField = '';
  try {
    final rules = q['rules'] as Map, body = q['body'] as String;
    final kind = q['kind'];
    dynamic rule(String name) {
      activeField = name;
      return rules[name];
    }

    final rows = <Data>[];
    if (kind == 'search' || kind == 'toc') {
      final search = kind == 'search';
      final items = evaluator.select(
        body,
        rule(search ? 'bookList' : 'chapterList'),
        elementsOnly: true,
      );
      if (items.length > 10000) throw const FormatException('单页条目超过 10000 项');
      for (final item in items) {
        final title = evaluator.field(
          item,
          rule(search ? 'name' : 'chapterName'),
        );
        final url = evaluator.field(
          item,
          rule(search ? 'bookUrl' : 'chapterUrl'),
        );
        if (title.isEmpty || url.isEmpty) continue;
        rows.add({
          'title': title,
          'url': url,
          if (search) 'author': evaluator.field(item, rule('author')),
        });
      }
    }
    port.send({
      'data': {
        'rows': rows,
        if (kind == 'detail') 'url': evaluator.field(body, rule('tocUrl')),
        if (kind == 'content')
          'text': evaluator.field(body, rule('content'), content: true),
        if (kind == 'toc' || kind == 'content')
          'next': evaluator.field(
            body,
            rule(kind == 'toc' ? 'nextTocUrl' : 'nextContentUrl'),
          ),
      },
    });
  } catch (e) {
    port.send({'error': '$activeField 解析失败：$e'});
  } finally {
    evaluator.dispose();
  }
}
