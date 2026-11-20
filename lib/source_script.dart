import 'dart:convert';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:html/dom.dart' as dom;

/// Opaque handles keep the original page and its parent links inside Dart.
/// Scripts may inspect only nodes in the current parser job.
class SourceScript {
  SourceScript(this.textOf) {
    _runtime.onMessage('sourceNode', _readNode);
    _runtime.evaluateJson(_installDom);
  }

  final String Function(dynamic) textOf;
  final _runtime = QuickJsRuntime2(
    timeout: 650,
    memoryLimit: 32 << 20,
    autoExecutePendingJobs: false,
  );
  final _nodes = <dom.Element>[];
  final _ids = Map<dom.Element, int>.identity();
  int _id(dom.Element node) => _ids.putIfAbsent(node, () {
    _nodes.add(node);
    return _nodes.length - 1;
  });

  dynamic _readNode(dynamic request) {
    final args = request as List;
    final node = _nodes[args[0] as int];
    final arg = args.length > 2 ? args[2] as String : '';
    return switch (args[1]) {
      'parent' => node.parent == null ? null : _id(node.parent!),
      'select' => node.querySelectorAll(arg).map(_id).toList(),
      'children' => node.children.map(_id).toList(),
      'text' => textOf(node).replaceAll(RegExp(r'\s+'), ' ').trim(),
      'ownText' =>
        node.nodes
            .whereType<dom.Text>()
            .map((n) => n.data.trim())
            .where((s) => s.isNotEmpty)
            .join(' '),
      'attr' => node.attributes[arg] ?? '',
      'html' => node.innerHtml,
      'outerHtml' => node.outerHtml,
      'tagName' => node.localName,
      _ => throw FormatException('未知的节点操作 ${args[1]}'),
    };
  }

  List<dynamic> run(dynamic input, String script, String baseUrl, String key) {
    final node = input is dom.Element ? _id(input) : null;
    final value = input is dom.Element ? input.outerHtml : input;
    final body = RegExp(r'^return\b').hasMatch(script)
        ? script
        : 'return eval(${jsonEncode(script)})';
    final values = _runtime.evaluateJson(
      'runSourceRule((result,baseUrl,key)=>{"use strict";$body},'
      'JSON.parse(${jsonEncode(jsonEncode(value))}),$node,'
      '${jsonEncode(baseUrl)},${jsonEncode(key)})',
    ) as List;
    return [
      for (final entry in values)
        if (entry[0] == 'node') _nodes[entry[1] as int] else entry[1],
    ];
  }

  void dispose() => _runtime.dispose();
}

const _installDom = r'''
const runSourceRule = (() => {
  const handles = new WeakMap();
  let currentId, currentHtml;
  function idOf(value) {
    if (handles.has(value)) return handles.get(value);
    if (currentId !== null && String(value) === currentHtml) return currentId;
    throw new TypeError("This value is not a source element");
  }
  const read = (node, op, arg) => sendMessage("sourceNode", [idOf(node), op, arg]);
  function wrap(id) {
    if (id == null) return null;
    const node = Object.create(methods);
    handles.set(node, id);
    return node;
  }
  class Elements extends Array {
    first() { return this[0] ?? null; }
    last() { return this[this.length - 1] ?? null; }
    get(i) { return this[i]; }
    size() { return this.length; }
    text() { return this.map(e => e.text()).join(" "); }
    attr(key) { return this.first()?.attr(key) ?? ""; }
    html() { return this.map(e => e.html()).join("\n"); }
    select(css) { return this.flatMap(e => e.select(css)); }
  }
  const methods = {
    parentNode() { return wrap(read(this, "parent", "")); },
    parent() { return this.parentNode(); },
    select(css) { return Elements.from(read(this, "select", css), wrap); },
    selectFirst(css) { return this.select(css).first(); },
    children() { return Elements.from(read(this, "children", ""), wrap); },
    text() { return read(this, "text", ""); },
    ownText() { return read(this, "ownText", ""); },
    html() { return read(this, "html", ""); },
    outerHtml() { return read(this, "outerHtml", ""); },
    tagName() { return read(this, "tagName", ""); },
    attr(name) { return read(this, "attr", name); }
  };
  // Keep the initial HTML value a primitive for existing string-based scripts.
  for (const [name, fn] of Object.entries(methods)) {
    Object.defineProperty(String.prototype, name, {value: fn, configurable: true});
  }
  Object.defineProperty(methods, "toString", {value: methods.outerHtml});
  return (fn, value, id, baseUrl, key) => {
    currentId = id;
    currentHtml = value;
    try {
      const result = fn(value, baseUrl, key);
      return (Array.isArray(result) ? Array.from(result) : [result])
        .filter(v => v != null)
        .map(v => handles.has(v) ? ["node", handles.get(v)] : ["value", v]);
    } finally {
      currentId = null;
      currentHtml = null;
    }
  };
})();
''';
