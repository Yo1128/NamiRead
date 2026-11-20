import 'dart:convert';

import 'package:flutter/material.dart';

import 'library.dart';
import 'reader.dart';
import 'source_client.dart';
import 'source_download_actions.dart';
import 'source_model.dart';

class SourceBrowser extends StatefulWidget {
  const SourceBrowser(this.library, {super.key});
  final Library library;
  @override
  State<SourceBrowser> createState() => _SourceBrowserState();
}

class _SourceBrowserState extends State<SourceBrowser> {
  final query = TextEditingController();
  SourceClient client = SourceClient();
  String? selected, error;
  List<Data> results = [];
  bool busy = false, searched = false;
  int page = 0;
  bool hasMore = false;
  String lastTerm = '';
  List<Data> get active =>
      configuredSources(widget.library.settings)
          .where((s) => s['enabled'] != false)
          .toList();

  @override
  void dispose() {
    query.dispose();
    client.close();
    super.dispose();
  }

  void reset() {
    client.close();
    client = SourceClient();
    results = [];
    error = null;
    searched = false;
    busy = false;
    hasMore = false;
    page = 0;
  }

  Future<void> search({bool more = false}) async {
    if (more && (busy || !hasMore)) return;
    final term = more ? lastTerm : query.text.trim(), sources = active;
    if (term.isEmpty || sources.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final source = sources.firstWhere(
      (s) => s['bookSourceUrl'] == selected,
      orElse: () => sources.first,
    );
    setState(() {
      if (!more) reset();
      error = null;
      lastTerm = term;
      selected = source['bookSourceUrl'];
      busy = true;
      searched = true;
    });
    final job = client;
    try {
      final next = page + 1;
      final books = await job.search(source, term, pageNumber: next);
      if (mounted && job == client) {
        final seen = results.map((row) => row['url']).toSet();
        final fresh = books.where((row) => seen.add(row['url'])).toList();
        setState(() {
          results = [...results, ...fresh];
          page = next;
          hasMore =
              fresh.isNotEmpty &&
              (source['searchUrl'] as String).contains('{{page}}');
        });
      }
    } catch (e) {
      if (mounted && job == client) setState(() => error = sourceError(e));
    } finally {
      if (mounted && job == client) setState(() => busy = false);
    }
  }

  Future<void> manage() async {
    final before = jsonEncode(configuredSources(widget.library.settings));
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => SourceManager(widget.library)),
    );
    if (mounted &&
        before != jsonEncode(configuredSources(widget.library.settings))) {
      setState(reset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = active;
    final source =
        sources.where((s) => s['bookSourceUrl'] == selected).firstOrNull ??
        sources.firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: [
          IconButton(
            tooltip: '管理书源',
            onPressed: manage,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  if (source != null) ...[
                    DropdownButton<String>(
                      isExpanded: true,
                      value: source['bookSourceUrl'],
                      items: [
                        for (final s in sources)
                          DropdownMenuItem(
                            value: s['bookSourceUrl'] as String,
                            child: Text(
                              s['bookSourceName'],
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (s) => setState(() {
                        reset();
                        selected = s;
                      }),
                    ),
                    TextField(
                      controller: query,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => search(),
                      decoration: InputDecoration(
                        hintText: '搜索书名或关键词',
                        suffixIcon: IconButton(
                          tooltip: '搜索书源',
                          onPressed: search,
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                  ],
                  if (busy) const LinearProgressIndicator(minHeight: 2),
                  if (sources.isEmpty)
                    Expanded(
                      child: Center(
                        child: TextButton(
                          onPressed: manage,
                          child: const Text('管理并启用书源'),
                        ),
                      ),
                    )
                  else if (error != null && results.isEmpty)
                    Expanded(child: _Failure(error!, search))
                  else if (searched && !busy && results.isEmpty)
                    const Expanded(child: Center(child: Text('没有找到匹配的书籍')))
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: results.length + (hasMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == results.length) {
                            if (error != null) {
                              return _Failure(error!, () => search(more: true));
                            }
                            return TextButton(
                              onPressed: busy ? null : () => search(more: true),
                              child: const Text('更多结果'),
                            );
                          }
                          final book = results[i],
                              author = book['author'] as String;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(book['title']),
                            subtitle: author.isEmpty ? null : Text(author),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => SourceCatalog(
                                  widget.library,
                                  source!,
                                  book,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure(this.error, this.retry);
  final String error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, textAlign: TextAlign.center),
          TextButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class SourceCatalog extends StatefulWidget {
  const SourceCatalog(this.library, this.source, this.result, {super.key});
  final Library library;
  final Data source, result;
  @override
  State<SourceCatalog> createState() => _SourceCatalogState();
}

class _SourceCatalogState extends State<SourceCatalog> {
  final client = SourceClient();
  List<Data> chapters = [];
  String? error;
  Book? book;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => error = null);
    final existing = widget.library.books
        .where(
          (b) =>
              b.meta['bookSourceUrl'] == widget.source['bookSourceUrl'] &&
              b.meta['bookUrl'] == widget.result['url'],
        )
        .firstOrNull;
    try {
      final rows = existing == null
          ? await client.catalog(widget.source, widget.result)
          : existing.chapters.cast<Data>();
      if (mounted) {
        setState(() {
          book = existing;
          chapters = rows;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = sourceError(e));
    }
  }

  Future<void> open({
    int? index,
    bool read = false,
    bool download = false,
  }) async {
    if (saving) return;
    final library = widget.library;
    setState(() => saving = true);
    try {
      final saved =
          book ??
          await client.shelve(library, widget.source, widget.result, chapters);
      if (download) library.downloadFor(saved).start();
      if (!mounted) return;
      setState(() => book = saved);
      if (read) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Reader(
              widget.library,
              saved,
              startChapter: index,
              returnLabel: '返回目录',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(sourceError(e))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('目录')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.result['title'],
                  style: Theme.of(context).textTheme.headlineSmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if ((widget.result['author'] ?? '').isNotEmpty)
                      widget.result['author'],
                    widget.source['bookSourceName'],
                    if (chapters.isNotEmpty) '${chapters.length} 章',
                  ].join(' · '),
                ),
                if (chapters.isNotEmpty)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () => open(read: book != null),
                        icon: Icon(
                          book == null
                              ? Icons.library_add_outlined
                              : Icons.menu_book_outlined,
                        ),
                        label: Text(book == null ? '加入书架' : '继续阅读'),
                      ),
                      if (book != null)
                        SourceDownloadActions(widget.library, book!)
                      else
                        TextButton.icon(
                          onPressed: saving ? null : () => open(download: true),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('下载全书'),
                        ),
                    ],
                  ),
                if (error != null)
                  Expanded(child: _Failure(error!, load))
                else if (chapters.isEmpty)
                  const Expanded(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: chapters.length,
                      itemBuilder: (_, i) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(chapters[i]['title']),
                        onTap: saving ? null : () => open(index: i, read: true),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SourceManager extends StatefulWidget {
  const SourceManager(this.library, {super.key});
  final Library library;
  @override
  State<SourceManager> createState() => _SourceManagerState();
}

class _SourceManagerState extends State<SourceManager> {
  bool saving = false;
  List<Data> get sources => configuredSources(widget.library.settings);
  Future<void> store(List<Data> items, {String? notice}) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      if (items.length > 256 ||
          utf8.encode(jsonEncode(items)).length > maxSourceBytes) {
        throw const FormatException('书源总配置超过上限（256 个或 1 MiB）');
      }
      await widget.library.replaceBookSources(items);
      if (mounted && notice != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(sourceError(e))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> edit([Data? old]) async {
    final imported =
        await Navigator.push<({List<Data> sources, List<String> skipped})>(
          context,
          MaterialPageRoute(builder: (_) => SourceEditor(old)),
        );
    if (!mounted || imported == null) return;
    final merged = {for (final s in sources) s['bookSourceUrl'] as String: s};
    if (old != null) merged.remove(old['bookSourceUrl']);
    for (final s in imported.sources) {
      merged[s['bookSourceUrl']] = s;
    }
    final skipped = imported.skipped;
    await store(
      merged.values.toList(),
      notice: skipped.isEmpty
          ? null
          : '已导入 ${imported.sources.length} 项，跳过 ${skipped.length} 项。\n${skipped.first}',
    );
  }

  Future<void> remove(Data source) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除「${source['bookSourceName']}」？'),
        content: const Text('已缓存的章节仍可阅读。未缓存章节需要重新导入这个书源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (mounted && yes == true) {
      await store(
        sources
            .where((s) => s['bookSourceUrl'] != source['bookSourceUrl'])
            .toList(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = sources;
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理书源'),
        actions: [
          IconButton(
            tooltip: '导入书源',
            onPressed: saving ? null : () => edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: items.isEmpty
                ? Center(
                    child: TextButton(
                      onPressed: () => edit(),
                      child: const Text('导入第一个书源'),
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final s = items[i];
                      return ListTile(
                        title: Text(s['bookSourceName']),
                        subtitle: Text(webAddress(s['bookSourceUrl']).host),
                        onTap: saving ? null : () => edit(s),
                        leading: Switch(
                          value: s['enabled'] != false,
                          onChanged: saving
                              ? null
                              : (v) => store(
                                  [...items]..[i] = {...s, 'enabled': v},
                                ),
                        ),
                        trailing: IconButton(
                          tooltip: '移除书源',
                          onPressed: saving ? null : () => remove(s),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class SourceEditor extends StatefulWidget {
  const SourceEditor(this.source, {super.key});
  final Data? source;
  @override
  State<SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<SourceEditor> {
  late final field = TextEditingController(
    text: widget.source == null
        ? ''
        : const JsonEncoder.withIndent('  ').convert(widget.source),
  );
  final client = SourceClient();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    field.dispose();
    client.close();
    super.dispose();
  }

  Future<void> submit({bool file = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var text = field.text.trim();
      if (file) {
        final uri = await platform.invokeMethod<String>('backupDocument');
        if (uri == null || !mounted) return;
        text = (await platform.invokeMethod<String>('readSourceFile', {
          'uri': uri,
        }))!;
      } else if (text.startsWith('https://') || text.startsWith('http://')) {
        text = (await client.fetch(
          webAddress(text),
          limit: maxSourceBytes,
        )).body;
      }
      final skipped = <String>[];
      final sources = decodeSources(text, onInvalid: skipped.add);
      if (mounted) Navigator.pop(context, (sources: sources, skipped: skipped));
    } catch (e) {
      if (mounted) setState(() => error = sourceError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.source == null ? '导入书源' : '编辑书源')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: field,
                    enabled: !busy,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '书源 JSON 或链接',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (error != null)
                  Text(error!, maxLines: 3, overflow: TextOverflow.ellipsis),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  children: [
                    TextButton.icon(
                      onPressed: busy ? null : () => submit(file: true),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择 JSON 文件'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => submit(),
                      child: Text(widget.source == null ? '导入' : '保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
