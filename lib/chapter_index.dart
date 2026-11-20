import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps a long directory cheap to open, including deep into an existing book.
class ChapterIndex extends StatefulWidget {
  const ChapterIndex({
    super.key,
    required this.entries,
    required this.resource,
    this.section,
    required this.onSelect,
  });
  final List entries;
  final String resource;
  final String? section;
  final ValueChanged<String> onSelect;

  @override
  State<ChapterIndex> createState() => _ChapterIndexState();
}

class _ChapterIndexState extends State<ChapterIndex> {
  late final List<int> all = List.generate(widget.entries.length, (i) => i);
  late List<int> rows = all;
  late int selected = currentEntry();

  @override
  void didUpdateWidget(ChapterIndex oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resource != oldWidget.resource ||
        widget.section != oldWidget.section) {
      selected = currentEntry();
    }
  }

  final field = TextEditingController();
  ScrollController? scroll;

  int currentEntry() {
    if (widget.section != null) {
      final exact = widget.entries.indexWhere(
        (e) => e['resource'] == '${widget.resource}#${widget.section}',
      );
      if (exact >= 0) return exact;
    }
    return widget.entries.indexWhere(
      (e) => (e['resource'] as String).split('#').first == widget.resource,
    );
  }

  void filter(String value) {
    final query = value.trim().toLowerCase();
    setState(() {
      rows = query.isEmpty
          ? all
          : all
                .where(
                  (i) => (widget.entries[i]['title'] as String)
                      .toLowerCase()
                      .contains(query),
                )
                .toList();
    });
    if (scroll?.hasClients == true) scroll!.jumpTo(0);
  }

  @override
  void dispose() {
    field.dispose();
    scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extent = math.max(
      52.0,
      MediaQuery.textScalerOf(context).scale(16) * 2.55 + 8,
    );
    scroll ??= ScrollController(
      initialScrollOffset: math.max(0, selected - 1) * extent,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.entries.length >= 12)
          TextField(
            controller: field,
            onChanged: filter,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '查找章节',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: field.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除章节搜索',
                      onPressed: () {
                        field.clear();
                        filter('');
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        if (rows.isEmpty)
          const Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text('没有匹配的章节'),
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              controller: scroll,
              shrinkWrap: true,
              itemExtent: extent,
              itemCount: rows.length,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              itemBuilder: (ctx, i) {
                final index = rows[i],
                    entry = widget.entries[index],
                    active = index == selected;
                return ListTile(
                  selected: active,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  title: Text(
                    entry['title'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  trailing: active ? const Icon(Icons.check, size: 20) : null,
                  onTap: () => widget.onSelect(entry['resource']),
                );
              },
            ),
          ),
      ],
    );
  }
}
