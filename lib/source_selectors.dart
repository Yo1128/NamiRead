import 'package:html/dom.dart' as dom;

/// Rule separators are literal inside CSS attributes, pseudo-classes,
/// JSONPath filters, quoted strings and escaped identifiers.
List<String> splitSourceRule(String expression, String separator) {
  if (!expression.contains(separator)) return [expression];
  final pieces = <String>[];
  var start = 0, depth = 0, quote = '';
  for (var i = 0; i < expression.length; i++) {
    final c = expression[i];
    if (c == r'\') {
      i++;
    } else if (quote.isNotEmpty) {
      if (c == quote) quote = '';
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c) && depth > 0) {
      depth--;
    } else if (depth == 0 && expression.startsWith(separator, i)) {
      pieces.add(expression.substring(start, i));
      i += separator.length - 1;
      start = i + 1;
    }
  }
  return [...pieces, expression.substring(start)];
}

final _oldIndex = RegExp(r'([.!])(-?\d+(?::-?\d+)*)$');
final _bracketIndex = RegExp(r'\[(!?)([\d\s,:-]+)\]$');

List<dom.Element> sourceElements(dom.Node root, String step) {
  final bracket = _bracketIndex.firstMatch(step);
  final index = bracket ?? _oldIndex.firstMatch(step);
  final path = index == null ? step : step.substring(0, index.start);
  List<dom.Element> elements;
  if (path == 'children' || path.isEmpty) {
    elements = root.children;
  } else {
    final css = path.startsWith('class.')
        ? '.${path.substring(6)}'
        : path.startsWith('id.')
        ? '#${path.substring(3)}'
        : path.startsWith('tag.')
        ? path.substring(4)
        : path;
    elements = root is dom.Element
        ? root.querySelectorAll(css)
        : (root as dom.Document).querySelectorAll(css);
  }
  if (index == null || elements.isEmpty) return elements;
  final indexes = <int>{}, length = elements.length;
  int offset(int n) => n < 0 ? length + n : n;
  for (final item in index[2]!.split(bracket == null ? ':' : ',')) {
    final range = item.trim().split(':');
    if (range.length == 1) {
      final n = offset(int.parse(range[0]));
      if (n >= 0 && n < length) indexes.add(n);
      continue;
    }
    if (range.length > 3) throw FormatException('无效的元素索引 $item');
    final first = range[0].trim().isEmpty
        ? 0
        : offset(int.parse(range[0].trim()));
    final last = range[1].trim().isEmpty
        ? length - 1
        : offset(int.parse(range[1].trim()));
    if ((first < 0 && last < 0) || (first >= length && last >= length)) {
      continue;
    }
    final start = first.clamp(0, length - 1), end = last.clamp(0, length - 1);
    final stride = range.length == 3 ? int.parse(range[2].trim()) : 1;
    if (stride <= 0) throw FormatException('索引步长需要正数：$item');
    for (
      var n = start;
      start <= end ? n <= end : n >= end;
      n += start <= end ? stride : -stride
    ) {
      indexes.add(n);
    }
  }
  if (index[1] == '!') {
    return [
      for (var i = 0; i < length; i++)
        if (!indexes.contains(i)) elements[i],
    ];
  }
  return [for (final i in indexes) elements[i]];
}

String replaceSourceMatches(String text, RegExp pattern, String replacement) {
  final references = RegExp(r'\\(.)|\$(\d+)');
  return text.replaceAllMapped(
    pattern,
    (match) => replacement.replaceAllMapped(references, (ref) {
      if (ref[1] != null) return ref[1]!;
      final group = int.parse(ref[2]!);
      if (group > match.groupCount) throw FormatException('正则替换没有分组 \$$group');
      return match[group] ?? '';
    }),
  );
}
