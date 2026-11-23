import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'source_download.dart';

typedef Data = Map<String, dynamic>;
const platform = MethodChannel('app.nami/books');
const locatorVersion = 1;

class Book {
  Book(this.dir, this.meta);
  final Directory dir;
  final Data meta;
  String get id => meta['id'];
  String get title => meta['title'];
  String get author => meta['author'];
  String get format => meta['format'];
  List get chapters => meta['chapters'];
  List get toc => meta['toc'];
  File? get cover =>
      meta['cover'] == true ? File(p.join(dir.path, 'cover.img')) : null;
  File chapterFile(int index) => File(p.join(dir.path, 'chapter-$index.html'));
  bool get isHubBook => meta['hubItem'] is Map;
  bool get isSourceBook => meta['format'] == '书源';
  File cachedText(int index) => File(p.join(dir.path, 'cached-$index.txt'));
  int chapterAt(String? resource) =>
      chapters.indexWhere((c) => c['resource'] == resource);
}

class Library extends ChangeNotifier {
  Library(this.root);
  final Directory root;
  final List<Book> books = [];
  final Map<String, Book> _hubShelf = {};
  Book? hubReference(String id) => _hubShelf[id];
  Book hubBook(Data meta) =>
      Book(Directory(p.join(root.path, 'hub-reading', meta['id'])), meta);
  List<Book> get shelfBooks {
    final referenced = {
      for (final book in _hubShelf.values) book.meta['hubItem']['sha256'],
    };
    return [
      ..._hubShelf.values,
      ...books.where((b) => !referenced.contains(b.id)),
    ];
  }

  Future<void> saveHubReference(Book book) => _changeShelf(() async {
    if (_hubShelf.containsKey(book.id)) return;
    _hubShelf[book.id] = book;
    try {
      await _writeSnapshot();
    } catch (_) {
      _hubShelf.remove(book.id);
      rethrow;
    }
  });

  Iterable<Book> get hubShelf => _hubShelf.values;
  bool canRemoveHubCopy(Book local) =>
      local.meta['hubDownload'] == true &&
      ((local.meta['hubOrigins'] as Map?)?.length ?? 0) <= 1 &&
      hubShelf
              .where((ref) => ref.meta['hubItem']['sha256'] == local.id)
              .length <=
          1;
  int generation = 0;
  Book? findBook(String digest) =>
      books.where((b) => b.id == digest).firstOrNull;

  Book? hubEdition(String origin) {
    Book? latest;
    var newest = 0;
    for (final book in books) {
      final order = book.meta['hubOrigins']?[origin] as int? ?? 0;
      if (order > newest) {
        latest = book;
        newest = order;
      }
    }
    return latest;
  }

  Map<String, int> _associate(Data meta, String origin) {
    final previous = hubEdition(origin);
    return {
      ...Map<String, int>.from(meta['hubOrigins'] ?? {}),
      origin: (previous?.meta['hubOrigins']?[origin] as int? ?? 0) + 1,
    };
  }

  Future<Book?> reuseHubBook(String digest, String origin, int expected) =>
      _changeShelf(() async {
        checkGeneration(expected);
        final book = findBook(digest);
        if (book == null || hubEdition(origin) == book) return book;
        final links = _associate(book.meta, origin);
        await _updateBookMeta(book, {'hubOrigins': links});
        return book;
      });

  Future<Book?> reuseLocalBook(String digest, int expected) =>
      _changeShelf(() async {
        checkGeneration(expected);
        final book = findBook(digest);
        if (book != null && book.meta['hubDownload'] == true) {
          await _updateBookMeta(book, {'hubDownload': false});
          notifyListeners();
        }
        return book;
      });

  Future<void> _updateBookMeta(Book book, Data updates) async {
    final file = File(p.join(book.dir.path, 'book.json'));
    final next = File('${file.path}.next');
    await next.writeAsString(
      jsonEncode({...book.meta, ...updates}),
      flush: true,
    );
    await next.rename(file.path);
    book.meta.addAll(updates);
  }

  void checkGeneration(int expected) {
    if (expected != generation) throw const FormatException('书架已更换，请重新添加');
  }

  final _downloads = <Book, SourceDownload>{};
  SourceDownload downloadFor(Book book) =>
      _downloads.putIfAbsent(book, () => SourceDownload(this, book));

  void _clearDownloads() {
    for (final job in _downloads.values) {
      job.dispose();
    }
    _downloads.clear();
  }

  @override
  void dispose() {
    _clearDownloads();
    super.dispose();
  }

  Data positions = {}, settings = {...defaultSettings};
  static const defaultSettings = {
    'landscapeSpread': false,
    'size': 19.0,
    'leading': 1.9,
    'margin': 24.0,
    'tone': 0,
    'width': 620.0,
  };
  Data bookmarks = {};
  Future<void> _writes = Future.value();
  Future<void> _shelfChanges = Future.value();
  String? storageError;
  Directory get shelf => Directory(p.join(root.path, 'books'));
  Directory get staging => Directory(p.join(root.path, 'incoming'));
  Directory get removed => Directory(p.join(root.path, 'removed'));
  Directory get restoreStage => Directory('${root.path}.restoring');
  Directory get _previous => Directory('${root.path}.previous');
  static Future<Library> open() async {
    final path = await platform.invokeMethod<String>('root');
    final library = Library(Directory(path!));
    await library.load();
    return library;
  }

  Future<void> load() async {
    if (!await root.exists() && await _previous.exists()) {
      await _previous.rename(root.path);
    }
    await _loadData();
    for (final dir in [_previous, restoreStage]) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // A valid active library remains usable if obsolete files are busy.
      }
    }
  }

  Future<void> _loadData() async {
    generation++;
    _clearDownloads();
    _hubShelf.clear();
    positions = {};
    bookmarks = {};
    settings = {...defaultSettings};
    await shelf.create(recursive: true);
    await staging.create(recursive: true);
    // Only this app's private, uncommitted import directories live here.
    await for (final item in staging.list(followLinks: false)) {
      await item.delete(recursive: true);
    }
    final state = File(p.join(root.path, 'state.json'));
    if (await state.exists()) {
      final data = jsonDecode(await state.readAsString());
      for (final meta in (data['hubShelf'] as List? ?? const [])) {
        final book = hubBook(Data.from(meta));
        _hubShelf[book.id] = book;
      }
      positions = data['positions'] ?? {};
      bookmarks = data['marks'] ?? {};
      settings.addAll(Data.from(data['settings'] ?? {}));
    }
    await removed.create(recursive: true);
    await for (final dir in removed.list(followLinks: false)) {
      if (dir is Directory) await _clearRemoved(dir);
    }
    books.clear();
    await for (final dir in shelf.list(followLinks: false)) {
      if (dir is Directory) {
        final file = File(p.join(dir.path, 'book.json'));
        if (await file.exists()) {
          books.add(Book(dir, jsonDecode(await file.readAsString())));
        }
      }
    }
    books.sort((a, b) => (b.meta['added'] as int).compareTo(a.meta['added']));
  }

  Future<T> _changeShelf<T>(Future<T> Function() action) {
    final next = _shelfChanges.then((_) => action());
    _shelfChanges = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> replaceFromStage() => _changeShelf(() async {
    await finishWrites();
    if (await _previous.exists()) await _previous.delete(recursive: true);
    await root.rename(_previous.path);
    try {
      await restoreStage.rename(root.path);
      await _loadData();
    } catch (_) {
      if (await root.exists()) await root.rename(restoreStage.path);
      await _previous.rename(root.path);
      await _loadData();
      rethrow;
    } finally {
      notifyListeners();
    }
    // Both directories at startup mean the new library has been committed.
    try {
      await _previous.delete(recursive: true);
    } on FileSystemException {
      // load() retries cleanup on the next launch.
    }
  });

  Future<Book> commit(
    Directory stage,
    Data meta, {
    String? hubOrigin,
    int? expectedGeneration,
  }) => _changeShelf(() async {
    if (expectedGeneration != null) checkGeneration(expectedGeneration);
    if (hubOrigin != null) meta['hubOrigins'] = _associate(meta, hubOrigin);
    if (meta['format'] == '书源' &&
        books.any(
          (b) =>
              b.meta['bookUrl'] == meta['bookUrl'] &&
              b.meta['bookSourceUrl'] == meta['bookSourceUrl'],
        )) {
      throw const FormatException('该书源书籍已在书架');
    }
    final pending = Directory(p.join(removed.path, meta['id']));
    if (await pending.exists()) await _clearRemoved(pending);
    final dest = Directory(p.join(shelf.path, meta['id']));
    if (await dest.exists()) throw const FormatException('同一内容已在书架中');
    await File(p.join(stage.path, 'book.json'))
        .writeAsString(jsonEncode(meta), flush: true);
    final dir = await stage.rename(dest.path);
    final book = Book(dir, meta);
    books.insert(0, book);
    notifyListeners();
    return book;
  });

  Future<String> cacheSourceText(Book book, int index, String text) =>
      _changeShelf(() async {
        if (!books.contains(book)) throw const FormatException('书籍已从书架移除');
        final file = book.cachedText(index);
        if (await file.exists()) return file.readAsString();
        final temp = File('${file.path}.next');
        await temp.writeAsString(text, flush: true);
        await temp.rename(file.path);
        _downloads[book]?.recordChapter(index);
        return text;
      });

  Future<void> replaceBookSources(List<Data> sources) => _changeShelf(() async {
    final old = settings['bookSources'];
    settings['bookSources'] = sources;
    try {
      await _writeSnapshot();
    } catch (_) {
      if (old == null) {
        settings.remove('bookSources');
      } else {
        settings['bookSources'] = old;
      }
      notifyListeners();
      rethrow;
    }
  });

  Future<void> _clearRemoved(Directory dir) async {
    final id = p.basename(dir.path);
    positions.remove(id);
    bookmarks.remove(id);
    await _writeSnapshot();
    await dir.delete(recursive: true);
  }

  Future<void> remove(Book book) => _changeShelf(() async {
    if (book.isHubBook) {
      final copy = findBook(book.meta['hubItem']['sha256']);
      if (copy != null && canRemoveHubCopy(copy)) {
        await _removeLocal(copy);
      }
      _hubShelf.remove(book.id);
      positions.remove(book.id);
      bookmarks.remove(book.id);
      await _writeSnapshot();
      return;
    }
    await _removeLocal(book);
  });

  Future<void> _removeLocal(Book book) async {
    if (!books.contains(book)) return;
    // The rename is the commit point. A restart completes interrupted cleanup.
    final dir = await book.dir.rename(p.join(removed.path, book.id));
    books.remove(book);
    _downloads.remove(book)?.dispose();
    await _clearRemoved(dir);
  }

  Future<void> _writeSnapshot() {
    final snapshot = jsonEncode({
      'schema': 1,
      'hubShelf': [for (final book in _hubShelf.values) book.meta],
      'positions': positions,
      'settings': settings,
      'marks': bookmarks,
    });
    final write = _writes.then((_) async {
      final temp = File(p.join(root.path, 'state.next'));
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(p.join(root.path, 'state.json'));
    });
    _writes = write.then(
      (_) {
        storageError = null;
      },
      onError: (Object error, StackTrace stack) {
        storageError = '阅读记录保存失败，请检查设备空间并重试';
        notifyListeners();
      },
    );
    notifyListeners();
    return write;
  }

  Future<void> persist() {
    _writeSnapshot();
    return _writes;
  }

  Future<void> remember(Book b, int chapter, Data point) {
    if (!books.contains(b) && !b.isHubBook) return Future.value();
    positions[b.id] = {
      ...point,
      'resource': b.chapters[chapter]['resource'],
      'revision': b.id,
      'version': locatorVersion,
      'when': DateTime.now().millisecondsSinceEpoch,
    };
    return persist();
  }

  Book? get recent {
    final read = shelfBooks.where((b) => positions[b.id] != null).toList()
      ..sort(
        (a, b) => (positions[b.id]['when'] as int).compareTo(
          positions[a.id]['when'] as int,
        ),
      );
    return read.firstOrNull;
  }

  Data? saved(Book b) => positions[b.id] as Data?;
  List<Book> matching(String query, String filter, String sort) {
    final words = query.toLowerCase().trim().split(RegExp(r'\s+'));
    final result = shelfBooks.where((book) {
      final text = '${book.title} ${book.author}'.toLowerCase();
      return words.every(text.contains) &&
          (filter == '全部' || (filter == '在读') == (saved(book) != null));
    }).toList();
    result.sort((a, b) {
      if (sort == '最近阅读') {
        final byRead = ((saved(b)?['when'] ?? 0) as int).compareTo(
          (saved(a)?['when'] ?? 0) as int,
        );
        if (byRead != 0) return byRead;
      } else if (sort == '书名') {
        final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        if (byTitle != 0) return byTitle;
      }
      final byDate = (b.meta['added'] as int).compareTo(a.meta['added']);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
    return result;
  }

  List marks(Book b) => bookmarks.putIfAbsent(b.id, () => []);
  Future<void> finishWrites() => _writes;
}
