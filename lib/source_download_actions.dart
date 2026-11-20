import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'library.dart';
import 'source_client.dart';
import 'source_download.dart';

class SourceDownloadActions extends StatefulWidget {
  const SourceDownloadActions(this.library, this.book, {super.key});
  final Library library;
  final Book book;

  @override
  State<SourceDownloadActions> createState() => _SourceDownloadActionsState();
}

class _SourceDownloadActionsState extends State<SourceDownloadActions> {
  bool exporting = false;

  Future<void> export() async {
    if (exporting) return;
    setState(() => exporting = true);
    Directory? stage;
    try {
      final book = widget.book;
      stage = await widget.library.staging.createTemp('txt-');
      final file = File(p.join(stage.path, 'book.txt'));
      await writeSourceTxt(book, file);
      if (!mounted) return;
      final clean = book.title
          .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
          .trim();
      final stem = clean.isEmpty
          ? '书籍'
          : String.fromCharCodes(clean.runes.take(60));
      final uri = await platform.invokeMethod<String>('backupDocument', {
        'name': '$stem.txt',
        'mime': 'text/plain',
      });
      if (uri == null) return;
      await platform.invokeMethod('writeDocument', {
        'uri': uri,
        'file': file.path,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('TXT 已保存到所选位置')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('TXT 导出失败：${sourceError(e)}')));
      }
    } finally {
      try {
        if (stage != null && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } on FileSystemException {
        // The library clears uncommitted staging directories at next launch.
      }
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.library.downloadFor(widget.book);
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final count = '${job.saved}/${job.total} 章';
        if (job.complete) {
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('已离线 · ${job.total} 章'),
              TextButton.icon(
                onPressed: exporting ? null : export,
                icon: const Icon(Icons.save_alt),
                label: Text(exporting ? '正在导出…' : '另存为 TXT'),
              ),
            ],
          );
        }
        final label = job.running
            ? '暂停 · $count'
            : job.error != null
            ? '重试下载 · $count'
            : job.saved > 0
            ? '继续下载 · $count'
            : '下载全书';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              onPressed: job.running ? job.pause : job.start,
              icon: Icon(job.running ? Icons.pause : Icons.download_outlined),
              label: Text(label),
            ),
            if (job.error != null)
              Text(job.error!, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
