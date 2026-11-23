import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'backup.dart';
import 'import_sheet.dart' show friendly;
import 'library.dart';

class BackupSheet extends StatefulWidget {
  const BackupSheet(this.library, {super.key});
  final Library library;
  @override
  State<BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<BackupSheet> {
  String status = '';
  bool busy = false;
  void report(String value) {
    if (mounted) setState(() => status = value);
  }

  Future<void> transfer(bool exporting) async {
    if (busy) return;
    final lib = widget.library;
    setState(() {
      busy = true;
      status = exporting ? '正在准备备份…' : '正在选择备份…';
    });
    Directory? work;
    try {
      work = await lib.staging.createTemp('backup-');
      final file = File(p.join(work.path, 'library.nrb'));
      if (exporting) {
        await exportBackup(lib, file, report);
        report('请选择备份保存位置');
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-');
      final uri = await platform.invokeMethod<String>('backupDocument', {
        if (exporting) 'name': 'NamiRead-$stamp.nrb',
      });
      if (uri == null) {
        report('已取消');
        return;
      }
      report(exporting ? '正在写入所选位置…' : '正在读取备份…');
      await platform.invokeMethod('transferBackup', {
        'uri': uri,
        'file': file.path,
        'export': exporting,
      });
      if (exporting) {
        report('备份已保存，共 ${lib.shelfBooks.length} 本书');
        return;
      }
      await platform.invokeMethod('beginImport');
      final backup = await stageBackup(lib, file, report);
      if (!mounted) return;
      final accept = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('用备份替换当前书架？'),
          content: Text(
            '当前书架有 ${lib.shelfBooks.length} 本书。备份含 ${backup.books} 本书、${backup.positions} 条进度和 ${backup.marks} 个书签。确认后将一并替换书籍、记录和设置。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('保留当前书架'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认恢复'),
            ),
          ],
        ),
      );
      if (accept != true) {
        report('已保留当前书架');
        return;
      }
      report('正在切换书架…');
      await lib.replaceFromStage();
      report('已恢复 ${backup.books} 本书和 ${backup.marks} 个书签');
    } catch (error) {
      report('操作未完成：${friendly(error)}');
    } finally {
      try {
        if (work != null && await work.exists()) {
          await work.delete(recursive: true);
        }
        if (!exporting && await lib.restoreStage.exists()) {
          await lib.restoreStage.delete(recursive: true);
        }
      } on FileSystemException {
        // Uncommitted work is also cleaned up on startup.
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '备份与恢复',
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
              child: Text('保存原书、书源、已缓存章节、进度、书签和设置，可在重装或换机后恢复。'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('导出备份'),
              subtitle: const Text('选择应用外的保存位置'),
              onTap: busy ? null : () => transfer(true),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restore),
              title: const Text('从备份恢复'),
              subtitle: const Text('校验通过后，确认替换当前书架'),
              onTap: busy ? null : () => transfer(false),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(status)),
              ),
          ],
        ),
      ),
    ),
  );
}
