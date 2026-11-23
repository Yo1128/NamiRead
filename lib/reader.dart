import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'chapter_index.dart';
import 'library.dart';
import 'hub_library.dart';
import 'reader_panes.dart';
import 'source_client.dart';

class Reader extends StatefulWidget {
  const Reader(
    this.library,
    this.book, {
    this.startChapter,
    this.hub,
    this.openingShelf,
    this.returnLabel = '返回书架',
    super.key,
  });
  final HubLibrary? hub;
  final int? startChapter;
  final ui.Image? openingShelf;
  final String returnLabel;
  final Library library;
  final Book book;
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const double topBar = 57, bottomBar = 48;
  late final toolsAnimation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 155),
        reverseDuration: const Duration(milliseconds: 130),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) setState(() {});
      });
  late final toolsProgress = toolsAnimation.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  late final topOffset = Tween(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(toolsProgress);
  late final bottomOffset = Tween(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(toolsProgress);
  String? panelKind;
  Data? panelPoint, removedMark;
  int removedAt = 0, panelRequest = 0;
  bool returnPanelFocus = false;
  final panelContentKey = GlobalKey();

  late final panelAnimation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
        reverseDuration: const Duration(milliseconds: 150),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed &&
            mounted &&
            panelKind != null) {
          finishClosingPanel();
        }
      });
  final panelTriggers = <String, FocusNode>{
    for (final kind in ['目录', '书签', '排版']) kind: FocusNode(),
  };
  Timer? loadingTimer;
  late ui.Image? openingShelf = widget.openingShelf;
  bool openingRevealed = false;
  bool showLoading = false;
  late final WebViewController web;
  late final Widget readingView;
  final sourceClient = SourceClient();
  Book get book => widget.book;
  Library get lib => widget.library;
  int chapter = 0, token = 0;
  int page = 1, lastVisiblePage = 1, pageCount = 1;
  bool landscapeTablet = false;
  String get pageRange =>
      page == lastVisiblePage ? '$page' : '$page–$lastVisiblePage';
  bool quiet = true,
      ready = false,
      leaving = false,
      allowPop = false,
      shell = false,
      started = false;
  String? error;
  Data? initial;
  TextScaler? systemScale;
  bool reduceMotion = false;
  final trail = <({int chapter, Data point})>[];
  Color get paper => [
    const Color(0xfffafafa),
    const Color(0xffe5e5e1),
    const Color(0xff181818),
  ][lib.settings['tone'] as int];
  Color get ink => lib.settings['tone'] == 2
      ? const Color(0xffe4e4df)
      : const Color(0xff171717);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    delayLoadingIndicator();
    final old = lib.saved(book);
    if (widget.startChapter != null) {
      chapter = widget.startChapter!.clamp(0, book.chapters.length - 1);
    } else if (old != null) {
      final index = book.chapterAt(old['resource']);
      if (index >= 0) {
        chapter = index;
        if (old['revision'] == book.id && old['version'] == locatorVersion) {
          initial = old;
        }
      }
      if (initial == null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => message('记录与当前版本不匹配，已回到章节开头'),
        );
      }
    }
    web = WebViewController();
    readingView = web.platform is AndroidWebViewController
        ? WebViewWidget.fromPlatformCreationParams(
            params: AndroidWebViewWidgetCreationParams(
              controller: web.platform,
              displayWithHybridComposition: true,
            ),
          )
        : WebViewWidget(controller: web);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scale = MediaQuery.textScalerOf(context);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final window = MediaQuery.sizeOf(context);
    final landscape =
        window.shortestSide >= 600 &&
        window.width >= 720 &&
        window.width > window.height;
    final changed =
        systemScale != scale ||
        reduceMotion != disableAnimations ||
        landscapeTablet != landscape;
    landscapeTablet = landscape;
    systemScale = scale;
    reduceMotion = disableAnimations;
    if (reduceMotion && toolsAnimation.isAnimating) {
      toolsAnimation.value = quiet ? 0 : 1;
    }
    if (reduceMotion && panelAnimation.isAnimating) {
      panelAnimation.value = panelAnimation.isForwardOrCompleted ? 1 : 0;
    }
    if (!started) {
      started = true;
      setup();
    } else if (changed && shell) {
      unawaited(applyStyles());
    }
  }

  Future<void> setup() async {
    try {
      await web.setBackgroundColor(paper);
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.enableZoom(false);
      final controller = web.platform;
      if (controller is AndroidWebViewController) {
        // Flutter applies the system text scaler to the CSS size exactly once.
        await controller.setTextZoom(100);
      }
      await web.addJavaScriptChannel(
        'Nami',
        onMessageReceived: (msg) {
          handle(msg.message);
        },
      );
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (r) =>
              r.url ==
                  'file:///android_asset/flutter_assets/assets/reader/page.html'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) async {
            if (!mounted || shell) return;
            shell = true;
            await showChapter(chapter, initial);
          },
        ),
      );
      await web.loadFlutterAsset('assets/reader/page.html');
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '阅读组件未能打开：$e';
          openingRevealed = true;
        });
      }
    }
  }

  void message(String text) {
    if (mounted) {
      final gutter = ((MediaQuery.sizeOf(context).width - 400) / 2)
          .clamp(16.0, double.infinity)
          .toDouble();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            gutter,
            0,
            gutter,
            quiet ? 12 : bottomBar + 12,
          ),
        ),
      );
    }
  }

  Data get prefs => {
    for (final key in ['tone', 'serif', 'leading', 'margin', 'width'])
      key: lib.settings[key],
    'spread': landscapeTablet && lib.settings['landscapeSpread'] == true,
    'reduceMotion': reduceMotion,
    'toolsVisible': !quiet,
    'toolsTop': topBar,
    'toolsBottom': bottomBar,
    'size': MediaQuery.textScalerOf(context)
        .scale((lib.settings['size'] as num).toDouble()),
  };
  Future<void> applyStyles() =>
      web.runJavaScript('window.reader.style(${jsonEncode(prefs)})');

  void toggleTools() {
    if (!quiet) closePanel(restoreFocus: false);
    setState(() => quiet = !quiet);
    if (reduceMotion) {
      toolsAnimation.value = quiet ? 0 : 1;
    } else if (quiet) {
      toolsAnimation.reverse();
    } else {
      toolsAnimation.forward();
    }
    if (shell) unawaited(web.runJavaScript('window.reader.tools(${!quiet})'));
  }

  void delayLoadingIndicator() {
    if (openingShelf != null &&
        (showLoading || loadingTimer?.isActive == true)) {
      return;
    }
    loadingTimer?.cancel();
    showLoading = false;
    loadingTimer = Timer(
      Duration(milliseconds: openingShelf == null ? 180 : 550),
      () {
        if (mounted && !ready && error == null) {
          setState(() => showLoading = true);
        }
      },
    );
  }

  Future<void> showChapter(int idx, Data? point, {int turn = 0}) async {
    if (idx < 0 || idx >= book.chapters.length || !mounted) return;
    final seq = ++token;
    delayLoadingIndicator();
    setState(() {
      chapter = idx;
      initial = point;
      ready = false;
      error = null;
    });
    try {
      final html = book.isHubBook
          ? await widget.hub!.chapter(book, idx)
          : book.isSourceBook
          ? await sourceClient.chapter(lib, book, idx)
          : await book.chapterFile(idx).readAsString();
      if (!mounted || seq != token) return;
      final head = {
        'token': seq,
        'index': idx,
        'title': book.chapters[idx]['title'],
        'last': idx == book.chapters.length - 1,
        'turn': turn,
        'sections': [
          for (final entry in book.toc)
            if ((entry['resource'] as String).startsWith(
              "${book.chapters[idx]['resource']}#",
            ))
              (entry['resource'] as String).substring(
                (book.chapters[idx]['resource'] as String).length + 1,
              ),
        ],
      };
      await web.runJavaScript(
        'void window.reader.show(${jsonEncode(head)},${jsonEncode(html)},${jsonEncode(prefs)},${jsonEncode(point)})',
      );
    } catch (e) {
      if (mounted && seq == token) {
        setState(() {
          error = book.isHubBook
              ? hubMessage(e)
              : book.isSourceBook
              ? sourceError(e)
              : '此章节无法打开：$e';
          openingRevealed = true;
        });
      }
    }
  }

  Future<Data?> capture() async {
    if (!ready || !mounted) return null;
    final seq = token;
    try {
      dynamic raw = await web.runJavaScriptReturningResult(
        'window.reader.capture()',
      );
      if (raw is String) raw = jsonDecode(raw);
      if (raw is String) raw = jsonDecode(raw);
      if (!mounted || seq != token || raw['token'] != seq) return null;
      return raw['point'] == null ? null : Data.from(raw['point']);
    } catch (_) {
      return null;
    }
  }

  Future<void> flush() async {
    final seq = token, idx = chapter;
    final point = await capture();
    if (mounted && seq == token && point != null) {
      await lib.remember(book, idx, point);
    }
  }

  Future<void> handle(String messageText) async {
    if (!mounted || leaving) return;
    final data = jsonDecode(messageText);
    if (data['token'] != token) return;
    if (data['page'] is int &&
        data['lastPage'] is int &&
        data['pages'] is int &&
        (page != data['page'] ||
            lastVisiblePage != data['lastPage'] ||
            pageCount != data['pages'])) {
      page = data['page'] as int;
      lastVisiblePage = data['lastPage'] as int;
      pageCount = data['pages'] as int;
      if (!quiet || !toolsAnimation.isDismissed) setState(() {});
    }
    if (panelKind == '目录' &&
        data['point'] is Map &&
        panelPoint?['section'] != data['point']['section']) {
      setState(() => panelPoint = Data.from(data['point']));
    }
    switch (data['type']) {
      case 'ready':
        loadingTimer?.cancel();
        setState(() {
          ready = true;
          openingRevealed = true;
        });
        if (data['ok'] == false) message('原文位置已失效，已回到章节开头');
        await lib.remember(book, chapter, Data.from(data['point']));
      case 'save':
        if (ready) await lib.remember(book, chapter, Data.from(data['point']));
      case 'chrome':
        toggleTools();
      case 'next':
        if (chapter + 1 < book.chapters.length) {
          trail.clear();
          await showChapter(chapter + 1, null);
        } else {
          await leave();
        }
      case 'prev':
        trail.clear();
        await showChapter(chapter - 1, null);
      case 'turnChapter':
        final direction = data['direction'];
        if (!ready || direction is! int || direction.abs() != 1) return;
        final next = chapter + direction;
        if (next < 0 || next >= book.chapters.length) return;
        trail.clear();
        await showChapter(
          next,
          direction < 0 ? {'end': true} : null,
          turn: direction,
        );
      case 'link':
        await jump(data['target'], recordReturn: true);
    }
  }

  Future<void> jump(String target, {bool recordReturn = false}) async {
    final parts = target.split('#'), idx = book.chapterAt(parts.first);
    if (idx < 0) {
      message('该链接未指向本书可读章节');
      return;
    }
    if (recordReturn) {
      final from = chapter, seq = token;
      final point = await capture();
      if (!mounted || token != seq || leaving) return;
      if (point != null) trail.add((chapter: from, point: point));
    } else {
      trail.clear();
    }
    await showChapter(
      idx,
      parts.length > 1 && parts.last.isNotEmpty
          ? {'fragment': parts.sublist(1).join('#')}
          : null,
    );
  }

  Future<void> back() async {
    if (panelKind != null) {
      closePanel();
      return;
    }
    if (trail.isNotEmpty) {
      final last = trail.removeLast();
      await showChapter(last.chapter, last.point);
      return;
    }
    await leave();
  }

  Future<void> leave() async {
    if (leaving) return;
    leaving = true;
    await flush();
    await lib.finishWrites();
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(flush());
  }

  @override
  void dispose() {
    openingShelf?.dispose();
    sourceClient.close();
    loadingTimer?.cancel();
    toolsAnimation.dispose();
    panelAnimation.dispose();
    for (final node in panelTriggers.values) {
      node.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    token++;
    super.dispose();
  }

  Future<void> bookmark() async {
    final seq = token;
    final snap = await capture();
    if (snap == null || seq != token || leaving) return;
    final list = lib.marks(book);
    if (list.any(
      (m) =>
          m['resource'] == book.chapters[chapter]['resource'] &&
          m['top'] == snap['top'] &&
          m['image'] == snap['image'] &&
          (m['imageOffset'] ?? 0) == (snap['imageOffset'] ?? 0) &&
          m['node'] == snap['node'] &&
          m['ch'] == snap['ch'],
    )) {
      message('这里已有书签');
      return;
    }
    list.add({
      ...snap,
      'version': locatorVersion,
      'revision': book.id,
      'resource': book.chapters[chapter]['resource'],
    });
    if (mounted && panelKind == '书签') setState(() {});
    await lib.persist();
    message(lib.storageError ?? '已添加书签');
  }

  Future<void> panel(String kind) async {
    final request = ++panelRequest;
    final point = kind == '目录' ? await capture() : null;
    if (!mounted || leaving || quiet || request != panelRequest) return;
    returnPanelFocus = false;
    setState(() {
      panelKind = kind;
      panelPoint = point;
      removedMark = null;
    });
    if (reduceMotion) {
      panelAnimation.value = 1;
    } else {
      panelAnimation.forward();
    }
  }

  void closePanel({bool restoreFocus = true}) {
    ++panelRequest;
    final kind = panelKind;
    if (kind == null) return;
    returnPanelFocus = restoreFocus;
    if (reduceMotion || panelAnimation.isDismissed) {
      panelAnimation.value = 0;
      if (panelKind != null) finishClosingPanel();
    } else {
      panelAnimation.reverse();
    }
  }

  void finishClosingPanel() {
    final trigger = returnPanelFocus ? panelTriggers[panelKind] : null;
    setState(() => panelKind = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !quiet && panelKind == null) trigger?.requestFocus();
    });
  }

  Widget panelContent(
    String kind,
    double readingWidth, {
    required bool docked,
  }) {
    Future<void> update(String key, Object value) async {
      lib.settings[key] = value;
      setState(() {});
      unawaited(lib.persist());
      if (key == 'tone') await web.setBackgroundColor(paper);
      if (mounted && !leaving) await applyStyles();
    }

    Widget step(String label, String key, double lo, double hi, double delta) {
      final v = (lib.settings[key] as num).toDouble().clamp(lo, hi);
      return Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            tooltip: '减小$label',
            onPressed: v <= lo
                ? null
                : () => update(
                    key,
                    double.parse((v - delta).clamp(lo, hi).toStringAsFixed(1)),
                  ),
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 48,
            child: Text(
              key == 'leading' ? v.toStringAsFixed(1) : v.round().toString(),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: '增大$label',
            onPressed: v >= hi
                ? null
                : () => update(
                    key,
                    double.parse((v + delta).clamp(lo, hi).toStringAsFixed(1)),
                  ),
            icon: const Icon(Icons.add),
          ),
        ],
      );
    }

    final width = readingWidth - 2 * (lib.settings['margin'] as num);
    final widgets = <Widget>[];
    if (kind == '书签') {
      final marks = lib.marks(book);
      if (marks.isEmpty) {
        widgets.add(const ListTile(title: Text('还没有书签')));
      }
      if (removedMark != null) {
        widgets.add(
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                marks.insert(removedAt.clamp(0, marks.length), removedMark!);
                removedMark = null;
                lib.persist();
                setState(() {});
              },
              icon: const Icon(Icons.undo),
              label: const Text('撤销删除'),
            ),
          ),
        );
      }
      for (final mark in marks.reversed) {
        final idx = book.chapterAt(mark['resource']);
        final valid =
            idx >= 0 &&
            mark['version'] == locatorVersion &&
            mark['revision'] == book.id;
        widgets.add(
          ListTile(
            title: Text(idx >= 0 ? book.chapters[idx]['title'] : '原章节不可用'),
            subtitle: Text(
              mark['top'] == true
                  ? '章节开头'
                  : mark['image'] != null
                  ? '章节插图'
                  : mark['context'] ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '删除书签',
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                removedMark = Data.from(mark);
                removedAt = marks.indexOf(mark);
                marks.remove(mark);
                lib.persist();
                setState(() {});
              },
            ),
            onTap: idx < 0
                ? null
                : () {
                    closePanel();
                    trail.clear();
                    if (!valid) message('书签与当前版本不匹配，已回到章节开头');
                    showChapter(idx, valid ? Data.from(mark) : null);
                  },
          ),
        );
      }
    } else if (kind == '排版') {
      Widget choices(
        String label,
        List<String> labels,
        int selected,
        ValueChanged<int> pick,
      ) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(label),
            Wrap(
              children: [
                for (int i = 0; i < labels.length; i++)
                  Semantics(
                    selected: selected == i,
                    child: TextButton(
                      onPressed: () => pick(i),
                      style: TextButton.styleFrom(
                        foregroundColor: selected == i ? paper : ink,
                        backgroundColor: selected == i ? ink : paper,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(labels[i]),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
      if (landscapeTablet) {
        widgets.add(
          choices(
            '横屏布局',
            ['单页', '双页'],
            lib.settings['landscapeSpread'] == true ? 1 : 0,
            (i) => update('landscapeSpread', i == 1),
          ),
        );
      }
      widgets.add(
        choices(
          '纸面',
          ['白昼', '浅灰', '夜间'],
          lib.settings['tone'],
          (i) => update('tone', i),
        ),
      );
      widgets.addAll([
        choices(
          '正文字体',
          ['MiSans', '衬线'],
          lib.settings['serif'] == true ? 1 : 0,
          (i) => update('serif', i == 1),
        ),
        step('字号', 'size', 15, 30, 1),
        step('行距', 'leading', 1.4, 2.5, .1),
        step('页边距', 'margin', 12, 44, 4),
        if (width > 380)
          step('最大行宽', 'width', 380, width.clamp(380, 860).toDouble(), 40),
      ]);
    }
    final theme = ThemeData(
      useMaterial3: true,
      fontFamily: 'MiSans',
      colorScheme: ColorScheme.fromSeed(
        seedColor: ink,
        brightness: lib.settings['tone'] == 2
            ? Brightness.dark
            : Brightness.light,
      ).copyWith(primary: ink, surface: paper, onSurface: ink),
    );
    return Theme(
      key: panelContentKey,
      data: theme,
      child: Material(
        color: paper,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, docked ? 14 : 6, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      kind == '排版' ? '阅读排版' : kind,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: closePanel,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: kind == '目录'
                    ? ChapterIndex(
                        entries: book.toc,
                        resource: book.chapters[chapter]['resource'],
                        section: panelPoint?['section'],
                        onSelect: (target) {
                          closePanel();
                          jump(target);
                        },
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: widgets.length,
                        itemBuilder: (_, i) => widgets[i],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      buildPage(context),
      if (openingShelf != null)
        BlockSemantics(
          child: AbsorbPointer(
            child: AnimatedOpacity(
              opacity: openingRevealed ? 0 : 1,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              onEnd: () {
                if (openingRevealed && openingShelf != null) {
                  openingShelf!.dispose();
                  setState(() => openingShelf = null);
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: openingShelf, fit: BoxFit.cover),
                  if (showLoading && !openingRevealed)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          semanticsLabel: '正在打开《${book.title}》',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget buildPage(BuildContext context) {
    Widget toolbar({required bool top, required Widget child}) => Positioned(
      left: 0,
      right: 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      height: top ? topBar : bottomBar,
      child: IgnorePointer(
        ignoring: quiet,
        child: ExcludeFocus(
          excluding: quiet,
          child: ExcludeSemantics(
            excluding: quiet,
            child: SlideTransition(
              position: top ? topOffset : bottomOffset,
              child: ColoredBox(color: paper, child: child),
            ),
          ),
        ),
      ),
    );
    final navStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: lib.settings['tone'] == 2
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarColor: paper,
      systemNavigationBarIconBrightness: lib.settings['tone'] == 2
          ? Brightness.light
          : Brightness.dark,
    );
    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (popped, result) {
        if (!popped) back();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: openingShelf != null && !openingRevealed
            ? const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                systemNavigationBarColor: Color(0xfffafafa),
                systemNavigationBarIconBrightness: Brightness.dark,
              )
            : navStyle,
        child: Scaffold(
          backgroundColor: paper,
          body: SafeArea(
            child: ReaderPanes(
              animation: panelAnimation,
              paper: paper,
              ink: ink,
              onClose: closePanel,
              panel: panelKind == null
                  ? null
                  : (width, docked) =>
                        panelContent(panelKind!, width, docked: docked),
              reader: (readingWidth) {
                final compactTools =
                    readingWidth <
                    100 + MediaQuery.textScalerOf(context).scale(14) * 15;
                return ClipRect(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ExcludeSemantics(
                          excluding: !ready,
                          child: readingView,
                        ),
                      ),
                      if (openingShelf == null &&
                          !ready &&
                          error == null &&
                          showLoading)
                        Positioned(
                          top: quiet ? 0 : topBar,
                          left: 0,
                          right: 0,
                          child: const LinearProgressIndicator(minHeight: 2),
                        ),
                      if (error != null)
                        Positioned.fill(
                          child: ColoredBox(
                            color: paper,
                            child: Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      error!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: ink),
                                    ),
                                    TextButton(
                                      onPressed: () => shell
                                          ? showChapter(chapter, initial)
                                          : setup(),
                                      child: Text(
                                        '重试',
                                        style: TextStyle(color: ink),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (!toolsAnimation.isDismissed || !quiet)
                        toolbar(
                          top: true,
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: trail.isEmpty
                                    ? widget.returnLabel
                                    : '返回原文',
                                onPressed: back,
                                icon: Icon(Icons.arrow_back, color: ink),
                              ),
                              Expanded(
                                child: Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ink,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '添加当前位置书签',
                                onPressed: ready ? bookmark : null,
                                icon: Icon(
                                  Icons.bookmark_add_outlined,
                                  color: ink,
                                ),
                              ),
                              IconButton(
                                tooltip: '收起阅读工具',
                                onPressed: toggleTools,
                                icon: Icon(Icons.fullscreen, color: ink),
                              ),
                            ],
                          ),
                        ),
                      if (!toolsAnimation.isDismissed || !quiet)
                        toolbar(
                          top: false,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: ink.withValues(alpha: .15),
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Semantics(
                                    label:
                                        '第 ${chapter + 1} 章，共 ${book.chapters.length} 章',
                                    value: page == lastVisiblePage
                                        ? '第 $page 页，共 $pageCount 页'
                                        : '第 $page 至 $lastVisiblePage 页，共 $pageCount 页',
                                    onIncrease: ready
                                        ? () => web.runJavaScript(
                                            'reader.turn(1)',
                                          )
                                        : null,
                                    onDecrease: ready
                                        ? () => web.runJavaScript(
                                            'reader.turn(-1)',
                                          )
                                        : null,
                                    child: ExcludeSemantics(
                                      child: Text(
                                        ready
                                            ? '$pageRange / $pageCount 页'
                                            : '第 ${chapter + 1} 章',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: ink,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                for (final x in [
                                  ('目录', Icons.format_list_bulleted),
                                  ('书签', Icons.bookmark_outline),
                                  ('排版', Icons.text_fields),
                                ])
                                  if (compactTools)
                                    IconButton(
                                      focusNode: panelTriggers[x.$1],
                                      tooltip: x.$1,
                                      onPressed: ready
                                          ? () => panel(x.$1)
                                          : null,
                                      icon: Icon(x.$2, color: ink),
                                    )
                                  else
                                    TextButton.icon(
                                      focusNode: panelTriggers[x.$1],
                                      style: TextButton.styleFrom(
                                        foregroundColor: ink,
                                        minimumSize: const Size(48, 48),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                        ),
                                      ),
                                      onPressed: ready
                                          ? () => panel(x.$1)
                                          : null,
                                      icon: Icon(x.$2, size: 18),
                                      label: Text(x.$1),
                                    ),
                              ],
                            ),
                          ),
                        ),
                    ],
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
