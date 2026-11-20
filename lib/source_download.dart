import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'library.dart';
import 'source_client.dart';

class SourceDownload extends ChangeNotifier {
  SourceDownload(this.library, this.book) {
    ready = _inspect();
  }

  final Library library;
  final Book book;
  late final Future<void> ready;
  final _cached = <int>{};
  SourceClient? _client;
  bool _disposed = false, inspected = false;
  String? error;
  int get total => book.chapters.length;
  int get saved => _cached.length;
  bool get running => _client != null;
  bool get complete => total > 0 && saved == total;

  Future<void> _inspect() async {
    try {
      final pattern = RegExp(r'^cached-(\d+)\.txt$');
      await for (final file in book.dir.list(followLinks: false)) {
        if (_disposed) return;
        if (file is! File) continue;
        final match = pattern.firstMatch(p.basename(file.path));
        if (match != null) {
          final index = int.parse(match[1]!);
          if (index < total) _cached.add(index);
        }
      }
      inspected = true;
    } catch (e) {
      error = sourceError(e);
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  void recordChapter(int index) {
    if (!_disposed && _cached.add(index)) notifyListeners();
  }

  Future<void> start() async {
    if (_disposed || running || complete) return;
    final client = SourceClient();
    _client = client;
    error = null;
    notifyListeners();
    int? current;
    String? missing;
    try {
      await ready;
      if (!inspected && _client == client) await _inspect();
      if (!inspected) return;
      for (var i = 0; i < total && _client == client; i++) {
        if (_cached.contains(i)) continue;
        current = i;
        try {
          await client.chapterText(library, book, i);
          // Also covers a copy saved concurrently by the reader.
          recordChapter(i);
        } on SourceResponseError catch (e) {
          if (e.status != 404 && e.status != 410) rethrow;
          missing ??= '《${book.chapters[i]['title']}》：${sourceError(e)}';
        }
      }
      if (_client == client && !complete) error = missing;
    } catch (e) {
      if (_client == client) {
        error = current == null
            ? sourceError(e)
            : '《${book.chapters[current]['title']}》：${sourceError(e)}';
      }
    } finally {
      client.close();
      if (_client == client) {
        _client = null;
        notifyListeners();
      }
    }
  }

  void pause() {
    _client?.close();
    _client = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    super.dispose();
  }
}

/// Assemble a UTF-8 copy in catalog order, streaming one chapter at a time.
Future<void> writeSourceTxt(Book book, File output) async {
  final sink = output.openWrite();
  // A disk error can arrive before addStream or close is awaited.
  sink.done.ignore();
  try {
    sink.writeln(book.title);
    if (book.author.isNotEmpty) sink.writeln(book.author);
    for (var i = 0; i < book.chapters.length; i++) {
      sink.writeln();
      sink.writeln(book.chapters[i]['title']);
      await sink.addStream(book.cachedText(i).openRead());
      sink.writeln();
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}
