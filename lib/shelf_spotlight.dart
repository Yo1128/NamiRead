import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;

import 'library.dart';

int? shelfPercent(Book book, Data? position) {
  final chapter = book.chapterAt(position?['resource']);
  if (chapter < 0 || position == null) return null;
  final fraction = (position['fraction'] as num?) ?? 0;
  return ((chapter + fraction) * 100 / book.chapters.length).floor().clamp(
    0,
    99,
  );
}

String bookCredit(Book book) => [
  if (book.author.trim().isNotEmpty && book.author != '作者未知') book.author,
  book.format,
].join(' · ');

/// EPUB chapters can include multi-megabyte inline images. Only inspect the prefix.
Future<String> shelfExcerpt(
  Book book,
  int index, {
  String anchor = '',
  int offset = 0,
}) async {
  String shorten(String passage) {
    final text = passage.characters.take(90).toString();
    return text.length < passage.length ? '$text…' : text;
  }

  try {
    final input =
        await (book.isSourceBook
                ? book.cachedText(index)
                : book.chapterFile(index))
            .open();
    late final List<int> bytes;
    try {
      bytes = await input.read(16 * 1024);
    } finally {
      await input.close();
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    final lines = book.isSourceBook
        ? const LineSplitter().convert(raw)
        : html
              .parseFragment(raw)
              .querySelectorAll('p, blockquote, li, figcaption, pre')
              .map((e) => e.text);
    final heading = book.chapters[index]['title'];
    for (final passage in lines) {
      final line = passage.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty || line == heading) continue;
      if (anchor.isEmpty) return shorten(line);
      final at =
          offset >= 0 &&
              offset <= line.length &&
              line.startsWith(anchor, offset)
          ? offset
          : line.indexOf(anchor);
      if (at < 0) continue;
      final stop = RegExp(r'[。！？!?]|\.(?=\s|$)');
      final start = at == 0 ? 0 : line.lastIndexOf(stop, at - 1) + 1;
      // Keep the saved words in view even when a whole paragraph is one sentence.
      if (at - start > 35) return shorten('…${line.substring(at).trimLeft()}');
      return shorten(line.substring(start).trimLeft());
    }
  } on FileSystemException {
    // The rest of the shelf is usable if a chapter is unavailable.
  }
  return anchor.isEmpty ? '' : '…$anchor…';
}

class ShelfSpotlight extends StatefulWidget {
  const ShelfSpotlight({
    super.key,
    required this.book,
    required this.position,
    required this.gutter,
    this.standalone = false,
    required this.onRead,
    required this.onDetails,
  });
  final Book book;
  final Data? position;
  final double gutter;
  final bool standalone;
  final VoidCallback onRead, onDetails;

  static const titleStyle = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 36,
    height: 1.14,
    letterSpacing: -1,
    fontWeight: FontWeight.w700,
  );

  static double expandedHeight(
    BuildContext context,
    Book book,
    double textWidth,
  ) {
    final scale = MediaQuery.textScalerOf(context);
    final title = TextPainter(
      text: TextSpan(text: book.title, style: titleStyle),
      textDirection: Directionality.of(context),
      textScaler: scale,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: textWidth);
    // Budget both excerpt lines before the local chapter prefix has loaded.
    final contentHeight =
        kToolbarHeight +
        72 +
        title.height +
        scale.scale(13) * 1.4 +
        scale.scale(15) * 3.2 +
        scale.scale(14) * 1.6;
    title.dispose();
    return book.cover == null ? contentHeight : math.max(280, contentHeight);
  }

  @override
  State<ShelfSpotlight> createState() => _ShelfSpotlightState();
}

class _ShelfSpotlightState extends State<ShelfSpotlight> {
  int get chapter => widget.book
      .chapterAt(widget.position?['resource'])
      .clamp(0, widget.book.chapters.length - 1);
  String get contextText =>
      (widget.position?['context'] as String? ?? '').trim();
  late Future<String> excerpt;

  Future<String> loadExcerpt() {
    if (widget.position?['image'] != null && contextText.isEmpty) {
      return Future.value('');
    }
    return shelfExcerpt(
      widget.book,
      chapter,
      anchor: contextText,
      offset: widget.position?['ch'] as int? ?? 0,
    );
  }

  @override
  void initState() {
    super.initState();
    excerpt = loadExcerpt();
  }

  @override
  void didUpdateWidget(ShelfSpotlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book ||
        oldWidget.position?['resource'] != widget.position?['resource'] ||
        oldWidget.position?['ch'] != widget.position?['ch'] ||
        oldWidget.position?['context'] != widget.position?['context'] ||
        oldWidget.position?['image'] != widget.position?['image']) {
      excerpt = loadExcerpt();
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final file = book.cover;
    final withArt = file != null;
    final foreground = withArt ? Colors.white : const Color(0xff171717);
    final secondary = withArt
        ? const Color(0xffeaeaea)
        : const Color(0xff505050);
    final percent = shelfPercent(book, widget.position);
    final chapterName = book.chapters[chapter]['title'];
    final caption = TextStyle(color: secondary, fontSize: 13, height: 1.4);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: withArt ? const Color(0xff262626) : const Color(0xffefefec),
        ),
        if (file != null) ...[
          LayoutBuilder(
            builder: (context, size) => Image.file(
              file,
              fit: BoxFit.cover,
              alignment: const Alignment(.3, 0),
              cacheWidth:
                  (size.maxWidth * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          if (!widget.standalone)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xe5121212),
                    Color(0xb2161616),
                    Color(0x26161616),
                  ],
                  stops: [0, .59, 1],
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: widget.standalone
                    ? const [
                        Colors.transparent,
                        Color(0x16000000),
                        Color(0xb0000000),
                        Color(0xed000000),
                      ]
                    : const [
                        Color(0xa0000000),
                        Colors.transparent,
                        Color(0x10000000),
                        Color(0xb3000000),
                      ],
                stops: [0, .36, .65, 1],
              ),
            ),
          ),
        ],
        Positioned(
          left: 0,
          right: 0,
          top: widget.standalone
              ? 0
              : MediaQuery.paddingOf(context).top + kToolbarHeight,
          bottom: 0,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onRead,
              onLongPress: widget.onDetails,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.gutter,
                  14,
                  widget.gutter,
                  widget.standalone ? 36 : 18,
                ),
                child: Column(
                  mainAxisAlignment: widget.standalone && !withArt
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ShelfSpotlight.titleStyle.copyWith(
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      bookCredit(book),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                    const SizedBox(height: 12),
                    FutureBuilder<String>(
                      future: excerpt,
                      builder: (_, snap) {
                        final text =
                            snap.connectionState == ConnectionState.done
                            ? snap.data ?? ''
                            : contextText;
                        if (text.isEmpty) return const SizedBox.shrink();
                        return ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.min(
                              490,
                              MediaQuery.sizeOf(context).width * .79,
                            ),
                          ),
                          child: Text(
                            text,
                            maxLines: widget.standalone ? 4 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.6,
                              color: foreground,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            percent == null
                                ? '$chapterName'
                                : '$chapterName · $percent%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: caption,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          widget.position == null ? '开始阅读' : '继续阅读',
                          style: TextStyle(
                            color: foreground,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(Icons.arrow_forward, color: foreground, size: 18),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
