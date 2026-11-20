import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'library.dart';
import 'backup_sheet.dart';
import 'import_sheet.dart';
import 'reader.dart';
import 'source_browser.dart';
import 'source_download_actions.dart';
import 'motion.dart';
import 'shelf_spotlight.dart';

const ink = Color(0xff171717), paper = Color(0xfffafafa);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'MiSans',
    ], await rootBundle.loadString('assets/fonts/MiSans-License.txt'));
  });
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: paper,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const NamiRead());
}

class NamiRead extends StatefulWidget {
  const NamiRead({super.key});
  @override
  State<NamiRead> createState() => _NamiReadState();
}

class _NamiReadState extends State<NamiRead> with WidgetsBindingObserver {
  bool? compactDisplay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateOrientation();
  }

  @override
  void didChangeMetrics() => updateOrientation();

  void updateOrientation() {
    final display = View.of(context).display;
    if (display.size.isEmpty) return;
    // The physical display stays tablet-sized in split screen and letterbox mode.
    final compact = display.size.shortestSide / display.devicePixelRatio < 600;
    if (compactDisplay == compact) return;
    compactDisplay = compact;
    SystemChrome.setPreferredOrientations(
      compact ? [DeviceOrientation.portraitUp] : [],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  late Future<Library> opening = Library.open();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NamiRead',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'MiSans',
      scaffoldBackgroundColor: paper,
      colorScheme: const ColorScheme.light(
        primary: ink,
        onPrimary: paper,
        surface: paper,
        onSurface: ink,
        secondary: Color(0xff555555),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
    ),
    home: FutureBuilder<Library>(
      future: opening,
      builder: (ctx, snap) {
        if (snap.hasData) return Shelf(snap.data!);
        return Scaffold(
          body: Center(
            child: snap.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '书架暂时无法打开\n${friendly(snap.error!)}',
                        textAlign: TextAlign.center,
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => opening = Library.open()),
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        );
      },
    ),
  );
}

class Shelf extends StatefulWidget {
  const Shelf(this.lib, {super.key});
  final Library lib;
  @override
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  bool search = false;
  bool reading = false;
  final shelfBoundary = GlobalKey();
  final searchField = TextEditingController();
  String filter = '全部';
  Library get lib => widget.lib;
  bool get list => lib.settings['shelfList'] != false;
  String get sort => lib.settings['shelfSort'] ?? '最近阅读';
  @override
  void dispose() {
    searchField.dispose();
    super.dispose();
  }

  void preference(String key, Object value) {
    lib.settings[key] = value;
    lib.persist();
  }

  Future<void> details(Book book) async {
    final source = book.meta['sourceName'] ?? book.title;
    final added = DateTime.fromMillisecondsSinceEpoch(book.meta['added'])
        .toLocal();
    final date = MaterialLocalizations.of(context).formatCompactDate(added);
    final remove = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                book.title,
                style: Theme.of(ctx).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '${book.author} · ${book.format} · ${book.chapters.length} 章',
              ),
              const SizedBox(height: 22),
              if (book.isSourceBook)
                SelectableText('书源　${book.meta['bookSourceUrl']}')
              else
                Text('原文件　$source'),
              Text(book.isSourceBook ? '入架于　$date' : '导入于　$date'),
              SelectableText(
                '内容指纹　${book.id.substring(0, book.id.length.clamp(0, 12))}',
              ),
              const SizedBox(height: 16),
              if (book.isSourceBook) SourceDownloadActions(lib, book),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.remove_circle_outline),
                title: const Text('从书架移除'),
                onTap: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (remove != true || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从书架移除这本书？'),
        content: Text(
          book.isSourceBook
              ? '将删除《${book.title}》的目录、已缓存章节、进度和书签。'
              : '《${book.title}》的应用内副本、进度和书签将被删除。手机中的原文件会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    String message;
    try {
      await lib.remove(book);
      message = '已移除《${book.title}》';
    } catch (error) {
      message = lib.books.contains(book)
          ? '移除失败：${friendly(error)}'
          : '已从书架移除，重开应用时将重试清理';
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> openImport() => showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetMotion(context),
    isScrollControlled: true,
    enableDrag: false,
    builder: (_) => ImportSheet(lib),
  );

  Future<void> read(Book book) async {
    if (reading) return;
    final reduced = MediaQuery.disableAnimationsOf(context);
    setState(() => reading = true);
    try {
      // Freeze the painted shelf while the native reader lays out its first page.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final boundary =
          shelfBoundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final density = MediaQuery.devicePixelRatioOf(context);
      // Bound the one-shot texture on very large displays. Reader releases it on reveal.
      final openingShelf = boundary.toImageSync(
        pixelRatio: density.clamp(0.0, 3200 / boundary.size.longestSide),
      );
      await Navigator.push(
        context,
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: reduced
              ? Duration.zero
              : const Duration(milliseconds: 145),
          pageBuilder: (_, _, _) =>
              Reader(lib, book, openingShelf: openingShelf),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(
            opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> options() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 540),
      builder: (ctx) {
        Widget group(String name, List<String> values, String selected) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: secondary),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final value in values)
                      Semantics(
                        selected: selected == value,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: value == selected
                                ? ink
                                : Colors.transparent,
                            foregroundColor: value == selected ? paper : ink,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          onPressed: () => Navigator.pop(ctx, value),
                          child: Text(value),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lib.books.isNotEmpty) ...[
                  group('筛选', ['全部', '在读', '未读'], filter),
                  group('排序', ['最近阅读', '最近导入', '书名'], sort),
                  group('视图', ['列表', '封面'], list ? '列表' : '封面'),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.library_books_outlined),
                    title: const Text('管理书籍'),
                    onTap: () => Navigator.pop(ctx, '管理书籍'),
                  ),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.travel_explore),
                  title: const Text('书源'),
                  onTap: () => Navigator.pop(ctx, '书源'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('备份与恢复'),
                  onTap: () => Navigator.pop(ctx, '备份与恢复'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case '书源':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => SourceBrowser(lib)),
        );
      case '备份与恢复':
        await showModalBottomSheet<void>(
          context: context,
          sheetAnimationStyle: sheetMotion(context),
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          enableDrag: false,
          constraints: const BoxConstraints(maxWidth: 540),
          builder: (_) => BackupSheet(lib),
        );
      case '管理书籍':
        setState(() => managing = true);
      case '全部' || '在读' || '未读':
        setState(() => filter = action);
      case '列表' || '封面':
        preference('shelfList', action == '列表');
      default:
        preference('shelfSort', action);
    }
  }

  bool managing = false;
  static const secondary = TextStyle(
    fontSize: 13,
    height: 1.5,
    color: Color(0xff606060),
  );

  Widget cover(Book b, double width, {required Widget fallback}) {
    final file = b.cover;
    return file == null
        ? fallback
        : Image.file(
            file,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          );
  }

  Widget bookRow(Book book) {
    final position = lib.saved(book);
    final chapter = book.chapterAt(position?['resource']);
    final percent = shelfPercent(book, position);
    final author = book.author.trim();
    final hasCover = book.cover != null;
    final meta = [
      if (hasCover)
        bookCredit(book)
      else if (author.isNotEmpty && author != '作者未知')
        author,
      '${book.chapters.length} 章',
    ].join(' · ');
    final formatMark = ColoredBox(
      color: const Color(0xffe9e9e6),
      child: Center(
        child: Text(
          book.format,
          maxLines: 1,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xff555555),
            fontSize: 11,
            letterSpacing: .25,
          ),
        ),
      ),
    );
    return InkWell(
      onTap: () => managing ? details(book) : read(book),
      onLongPress: () => details(book),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 58,
              child: cover(book, 44, fallback: formatMark),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondary,
                  ),
                  if (chapter >= 0)
                    Text(
                      book.chapters[chapter]['title'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (managing)
              const Icon(Icons.chevron_right, size: 20)
            else
              Text(percent == null ? '未读' : '$percent%', style: secondary),
          ],
        ),
      ),
    );
  }

  Widget jacket(Book b, double width) {
    final percent = shelfPercent(b, lib.saved(b));
    final title = Text(
      b.title,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 21,
        height: 1.28,
        fontWeight: FontWeight.w600,
      ),
    );
    final typeCover = ColoredBox(
      color: const Color(0xffeaeae7),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Align(alignment: Alignment.bottomLeft, child: title),
      ),
    );
    return InkWell(
      onTap: () => read(b),
      onLongPress: () => details(b),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: cover(b, width, fallback: typeCover)),
          const SizedBox(height: 6),
          if (b.cover != null)
            Text(
              b.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          Text(
            bookCredit(b),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: secondary,
          ),
          Text(
            percent == null
                ? '${b.chapters.length} 章 · 未读'
                : '${b.chapters.length} 章 · 已读 $percent%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: secondary,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: shelfBoundary, child: buildShelf());

  Widget buildShelf() => AnimatedBuilder(
    // A page save should not sort books and lay out covers behind the reader.
    animation: reading ? kAlwaysDismissedAnimation : lib,
    builder: (_, _) {
      final rows = lib.matching(
        managing ? '' : searchField.text,
        managing ? '全部' : filter,
        sort,
      );
      final featured = !search && !managing && filter == '全部' && sort == '最近阅读'
          ? lib.recent ?? rows.firstOrNull
          : null;
      if (featured != null) rows.removeWhere((book) => book.id == featured.id);
      final scale = MediaQuery.textScalerOf(context);
      final largeType = scale.scale(14) >= 20;
      final showList = list || largeType || managing;
      final heading = managing
          ? '管理书籍'
          : filter == '全部'
          ? '书架'
          : filter;
      void closeMode() => setState(() {
        managing = false;
        search = false;
        searchField.clear();
      });

      return PopScope(
        canPop: !managing && !search,
        onPopInvokedWithResult: (popped, _) {
          if (!popped) closeMode();
        },
        child: Scaffold(
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final width = bounds.maxWidth;
                final gutter = width >= 600
                    ? 30.0
                    : width < 355
                    ? 18.0
                    : 22.0;
                final split =
                    featured != null &&
                    rows.isNotEmpty &&
                    width >= 900 &&
                    bounds.maxHeight >= 480 &&
                    ShelfSpotlight.expandedHeight(
                          context,
                          featured,
                          width * .38 - 2 * gutter,
                        ) <
                        bounds.maxHeight - 90;
                final available = width
                    .clamp(0.0, split ? 1440.0 : 900.0)
                    .toDouble();
                final featureWidth = split
                    ? (available * .38).clamp(310.0, 510.0).toDouble()
                    : 0.0;
                final bodyWidth = available - featureWidth;
                final columns = ((bodyWidth - 2 * gutter + 16) / 170)
                    .floor()
                    .clamp(2, 5);
                final jacketWidth =
                    (bodyWidth - 2 * gutter - 16 * (columns - 1)) / columns;
                final banner = split ? null : featured;
                final withArt = banner?.cover != null;
                Widget spotlight(Book book, {bool standalone = false}) =>
                    ShelfSpotlight(
                      book: book,
                      position: lib.saved(book),
                      gutter: gutter,
                      standalone: standalone,
                      onRead: () => read(book),
                      onDetails: () => details(book),
                    );
                final shelf = CustomScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      primary: !split,
                      automaticallyImplyLeading: false,
                      centerTitle: false,
                      titleSpacing: gutter,
                      actionsPadding: EdgeInsets.only(right: gutter - 12),
                      title: search
                          ? TextField(
                              autofocus: true,
                              controller: searchField,
                              decoration: const InputDecoration(
                                hintText: '搜索书名或作者',
                                border: InputBorder.none,
                              ),
                              onChanged: (_) => setState(() {}),
                            )
                          : split
                          ? Row(
                              children: [
                                const Flexible(
                                  child: Text(
                                    '其他藏书',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text('${rows.length} 本', style: secondary),
                              ],
                            )
                          : Text(
                              heading,
                              style: TextStyle(
                                fontSize: banner == null ? 25 : 21,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                      foregroundColor: withArt ? Colors.white : ink,
                      backgroundColor: withArt
                          ? ink
                          : banner == null
                          ? paper
                          : const Color(0xffefefec),
                      surfaceTintColor: Colors.transparent,
                      scrolledUnderElevation: 0,
                      systemOverlayStyle:
                          (withArt
                                  ? SystemUiOverlayStyle.light
                                  : SystemUiOverlayStyle.dark)
                              .copyWith(statusBarColor: Colors.transparent),
                      actions: [
                        if (managing || search)
                          IconButton(
                            tooltip: managing ? '完成' : '关闭搜索',
                            onPressed: closeMode,
                            icon: Icon(managing ? Icons.check : Icons.close),
                          )
                        else ...[
                          if (lib.books.isNotEmpty) ...[
                            IconButton(
                              tooltip: '搜索',
                              onPressed: () => setState(() => search = true),
                              icon: const Icon(Icons.search),
                            ),
                            IconButton(
                              tooltip: '导入书籍',
                              onPressed: openImport,
                              icon: const Icon(Icons.add),
                            ),
                          ],
                          IconButton(
                            tooltip: '书架选项',
                            onPressed: options,
                            icon: const Icon(Icons.more_horiz),
                          ),
                        ],
                      ],
                      expandedHeight: banner == null
                          ? null
                          : ShelfSpotlight.expandedHeight(
                              context,
                              banner,
                              available - 2 * gutter,
                            ),
                      flexibleSpace: banner == null
                          ? null
                          : FlexibleSpaceBar(
                              collapseMode:
                                  MediaQuery.disableAnimationsOf(context)
                                  ? CollapseMode.pin
                                  : CollapseMode.parallax,
                              background: spotlight(banner),
                            ),
                    ),
                    if (lib.storageError != null)
                      SliverToBoxAdapter(
                        child: TextButton(
                          onPressed: lib.persist,
                          child: Text('${lib.storageError} · 重试'),
                        ),
                      ),
                    if (lib.books.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '书架还是空的',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: openImport,
                                child: const Text('导入第一本书'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.isEmpty &&
                        featured == null &&
                        lib.books.isNotEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                searchField.text.trim().isEmpty
                                    ? '没有$filter书籍'
                                    : '没有匹配的书籍',
                              ),
                              TextButton(
                                onPressed: () => setState(() {
                                  searchField.clear();
                                  filter = '全部';
                                }),
                                child: const Text('显示全部藏书'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.isNotEmpty) ...[
                      if (!split)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 6),
                          sliver: SliverToBoxAdapter(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    featured != null
                                        ? '其他藏书'
                                        : search
                                        ? '搜索结果'
                                        : '藏书',
                                    style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text('${rows.length} 本', style: secondary),
                              ],
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          split ? 8 : 2,
                          gutter,
                          24,
                        ),
                        sliver: showList
                            ? SliverList.builder(
                                itemCount: rows.length,
                                itemBuilder: (_, i) => bookRow(rows[i]),
                              )
                            : SliverGrid.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 16,
                                      mainAxisSpacing: 18,
                                      childAspectRatio: .64,
                                    ),
                                itemCount: rows.length,
                                itemBuilder: (_, i) =>
                                    jacket(rows[i], jacketWidth),
                              ),
                      ),
                    ],
                  ],
                );
                return Center(
                  child: SizedBox(
                    width: available,
                    child: split
                        ? SafeArea(
                            bottom: false,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: featureWidth,
                                  child: spotlight(featured, standalone: true),
                                ),
                                Expanded(child: shelf),
                              ],
                            ),
                          )
                        : shelf,
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
