import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'library.dart';
import 'book_import.dart';

String friendly(Object e) {
  if (e is PlatformException) return e.message ?? '系统操作失败';
  if (e is FormatException) return e.message;
  if (e is FileSystemException) {
    return '无法读写文件：${e.osError?.message ?? e.message}';
  }
  return '文件损坏或结构暂不支持：$e';
}

class ImportSheet extends StatefulWidget {
  const ImportSheet(this.library, {super.key});
  final Library library;
  @override
  State<ImportSheet> createState() => _ImportSheetState();
}

class _ImportItem {
  _ImportItem(this.name, this.uri);
  final String name;
  final String? uri;
  String result = '';
  bool failed = false;
}

class _ImportSheetState extends State<ImportSheet> {
  bool busy = false, cancelled = false;
  String status = '';
  int total = 0, completed = 0;
  final results = <_ImportItem>[];

  Future<void> start({bool samples = false, _ImportItem? retry}) async {
    if (busy) return;
    String? selectionError;
    setState(() {
      busy = true;
      cancelled = false;
      total = completed = 0;
      status = retry != null || samples ? '准备导入…' : '选择文件…';
    });
    try {
      final List<_ImportItem> items;
      if (retry != null) {
        items = [retry];
      } else if (samples) {
        items = [_ImportItem('潮汐手记.txt', null), _ImportItem('街角建筑.epub', null)];
      } else {
        final selection = await platform.invokeListMethod('pick') ?? [];
        items = [
          for (final item in selection) _ImportItem(item['name'], item['uri']),
        ];
      }
      if (!mounted || items.isEmpty || cancelled) return;
      await platform.invokeMethod<void>('beginImport');
      if (!mounted || cancelled) return;
      if (retry == null) {
        results
          ..clear()
          ..addAll(items);
      }
      total = items.length;
      for (final item in items) {
        if (!mounted || cancelled) break;
        setState(() {
          item.failed = false;
          item.result = '';
          status = '正在导入 ${completed + 1} / $total\n${item.name}';
        });
        try {
          item.result = await importOne(item);
        } catch (error) {
          item.failed = !cancelled;
          item.result = cancelled ? '已取消' : friendly(error);
        }
        completed++;
      }
      if (cancelled) {
        for (final item in items.where((item) => item.result.isEmpty)) {
          item.result = '已取消';
        }
      }
    } catch (error) {
      selectionError = friendly(error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          status = cancelled ? '已取消后续导入' : selectionError ?? '';
        });
      }
    }
  }

  Future<String> importOne(_ImportItem item) async {
    final name = item.name, samples = item.uri == null;
    if (!{'.txt', '.epub'}.contains(p.extension(name).toLowerCase())) {
      throw const FormatException('请选择 TXT 或 EPUB 文件');
    }
    final stage = await widget.library.staging.createTemp('book-');
    try {
      if (cancelled || !mounted) return '已取消';
      String id;
      if (samples) {
        final bytes = await rootBundle.load('assets/samples/$name');
        final data = bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        await File(p.join(stage.path, 'original'))
            .writeAsBytes(data, flush: true);
        id = sha256.convert(data).toString();
      } else {
        id = (await platform.invokeMethod<String>('copy', {
          'uri': item.uri,
          'dir': stage.path,
        }))!;
      }
      if (!mounted || cancelled) return '已取消';
      final existing = widget.library.books
          .where((b) => b.id == id)
          .firstOrNull;
      if (existing != null) return '已在书架 · 《${existing.title}》';
      String? encoding;
      if (name.toLowerCase().endsWith('.txt')) {
        if (samples) {
          encoding = 'UTF-8';
          await platform.invokeMethod('decode', {
            'dir': stage.path,
            'encoding': encoding,
          });
        } else {
          encoding = await showDialog<String>(
            context: context,
            builder: (_) => EncodingPreview(stage, name),
          );
          if (encoding == null) return '已跳过';
        }
      }
      if (!mounted || cancelled) return '已取消';
      final meta = await prepareBook(
        stage,
        name: name,
        id: id,
        uri: item.uri,
        encoding: encoding,
      );
      if (!mounted || cancelled) return '已取消';
      await widget.library.commit(stage, meta);
      return '已导入《${meta['title']}》';
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  void cancel() {
    if (cancelled) return;
    setState(() {
      cancelled = true;
      status = '正在取消…';
    });
    platform.invokeMethod<void>('cancel');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && busy) cancel();
    },
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '导入书籍',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('可多选 TXT 或 EPUB。导入后，移动原文件也能继续阅读。'),
            ),
            if (busy) ...[
              LinearProgressIndicator(
                value: total > 1 ? completed / total : null,
              ),
              const SizedBox(height: 8),
              Text(status, maxLines: 3, overflow: TextOverflow.ellipsis),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: cancelled ? null : cancel,
                  child: const Text('取消导入'),
                ),
              ),
            ] else ...[
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => start(),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('选择文件'),
                  ),
                  TextButton(
                    onPressed: () => start(samples: true),
                    child: const Text('添加随附样书'),
                  ),
                ],
              ),
              if (status.isNotEmpty) Text(status),
            ],
            for (final item in results.where((item) => item.result.isNotEmpty))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(item.result),
                trailing: item.failed && !busy
                    ? TextButton(
                        onPressed: () => start(retry: item),
                        child: const Text('重试'),
                      )
                    : null,
              ),
          ],
        ),
      ),
    ),
  );
}

class EncodingPreview extends StatefulWidget {
  const EncodingPreview(this.dir, this.name, {super.key});
  final Directory dir;
  final String name;
  @override
  State<EncodingPreview> createState() => _EncodingPreviewState();
}

class _EncodingPreviewState extends State<EncodingPreview> {
  String encoding = 'UTF-8', preview = '', error = '';
  bool loading = true;
  @override
  void initState() {
    super.initState();
    decode();
  }

  Future<void> decode() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      preview =
          await platform.invokeMethod<String>('decode', {
            'dir': widget.dir.path,
            'encoding': encoding,
          }) ??
          '';
      if (preview.trim().isEmpty) error = '没有可阅读的正文';
    } catch (e) {
      error = friendly(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('确认文字编码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.name),
          DropdownButton<String>(
            value: encoding,
            isExpanded: true,
            items: [
              'UTF-8',
              'GB18030',
              'Big5',
              'UTF-16LE',
              'UTF-16BE',
            ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: loading
                ? null
                : (v) {
                    encoding = v!;
                    decode();
                  },
          ),
          if (loading)
            const LinearProgressIndicator()
          else
            Text(
              error.isNotEmpty ? error : preview,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('跳过'),
      ),
      FilledButton(
        onPressed: loading || error.isNotEmpty
            ? null
            : () => Navigator.pop(context, encoding),
        child: const Text('确认导入'),
      ),
    ],
  );
}
