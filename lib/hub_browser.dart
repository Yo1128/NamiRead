import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nami_hub_client/nami_hub_client.dart';

import 'hub_library.dart';
import 'library.dart';
import 'import_sheet.dart';

Future<Book> downloadHubBook(
  BuildContext context,
  HubLibrary hub,
  HubHost current,
  HubResource item,
) async {
  final book = await hub.obtain(current, item, (
    Directory dir,
    String name,
  ) async {
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (_) =>
          EncodingPreview(dir, name, hub: true, initialEncoding: 'GB18030'),
    );
  });
  return hub.linkDownload(current, item, book);
}

class HubBrowser extends StatefulWidget {
  const HubBrowser(this.hub, {super.key});
  final HubLibrary hub;
  @override
  State<HubBrowser> createState() => _HubBrowserState();
}

class _HubBrowserState extends State<HubBrowser> {
  String? selected, error, opening;
  bool loading = true;
  int request = 0;
  List<HubResource> items = [];
  HubHost? get host =>
      widget.hub.hosts.where((h) => h.id == selected).firstOrNull;

  @override
  void initState() {
    super.initState();
    widget.hub.addListener(update);
    refresh();
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.hub.removeListener(update);
    super.dispose();
  }

  Future<void> refresh([String? id]) async {
    final ticket = ++request;
    setState(() {
      loading = true;
      error = null;
      items = [];
    });
    try {
      await widget.hub.load();
      if (!mounted || ticket != request) return;
      selected = id ?? host?.id ?? widget.hub.hosts.firstOrNull?.id;
      final current = host;
      if (current == null || current.token.isEmpty) return;
      final result = await widget.hub.browse(current);
      if (mounted && ticket == request) items = result;
    } catch (e) {
      if (mounted && ticket == request) error = hubMessage(e);
    } finally {
      if (mounted && ticket == request) setState(() => loading = false);
    }
  }

  Future<void> pair([HubHost? previous]) async {
    final added = await Navigator.push<HubHost>(
      context,
      MaterialPageRoute(
        builder: (ctx) => _PairPage(
          widget.hub,
          previous: previous,
          onConnected: (h) => Navigator.pop(ctx, h),
        ),
      ),
    );
    if (mounted && added != null) await refresh(added.id);
  }

  Future<void> forget(HubHost current) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('忘记「${current.name}」？'),
        content: const Text('已下载的书可以离线阅读。再次连接这台电脑时需要配对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('忘记连接'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await widget.hub.forget(current);
      if (mounted) await refresh();
    } catch (e) {
      if (mounted) setState(() => error = hubMessage(e));
    }
  }

  Future<void> select(HubHost current, HubResource item, String action) async {
    if (opening != null) return;
    setState(() {
      opening = item.id;
      error = null;
    });
    try {
      final hub = widget.hub;
      if (action == 'remove') {
        final ref = hub.library.hubReference(hub.readingId(current.id, item));
        if (ref != null) await hub.removeCopy(ref);
        return;
      }
      if (action != 'download') {
        final book = await hub.online(current, item);
        if (!mounted ||
            selected != current.id ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        if (action == 'shelf') {
          if (book.isHubBook) await hub.library.saveHubReference(book);
        } else {
          Navigator.pop(context, book);
        }
        return;
      }
      await downloadHubBook(context, hub, current, item);
      if (mounted && selected == current.id) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已下载，可离线阅读')));
      }
    } catch (e) {
      if (mounted && selected == current.id) {
        setState(() => error = hubMessage(e));
      }
    } finally {
      if (mounted) setState(() => opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub, current = host;
    if (!loading && error == null && hub.hosts.isEmpty) {
      return _PairPage(hub, onConnected: (h) => refresh(h.id));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('NamiHub 书库'),
        actions: [
          IconButton(
            tooltip: '刷新书目',
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '管理主机',
            onSelected: (action) {
              if (action == 'add') {
                pair();
              } else if (current != null) {
                if (action == 'edit') {
                  pair(current);
                } else {
                  forget(current);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'add', child: Text('连接其他主机')),
              if (current != null)
                const PopupMenuItem(value: 'edit', child: Text('修改连接')),
              if (current != null)
                const PopupMenuItem(value: 'forget', child: Text('忘记此 Hub')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (current != null)
                    DropdownButton<String>(
                      value: current.id,
                      isExpanded: true,
                      items: [
                        for (final h in hub.hosts)
                          DropdownMenuItem(
                            value: h.id,
                            child: Text(
                              h.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: opening == null ? (id) => refresh(id) : null,
                    ),
                  if (loading) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: ListView(
                      children: [
                        if (error != null ||
                            current != null && current.token.isEmpty) ...[
                          const SizedBox(height: 16),
                          Text(error ?? '此主机需要重新配对。'),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed:
                                  current != null && current.token.isEmpty
                                  ? () => pair(current)
                                  : refresh,
                              child: Text(
                                current != null && current.token.isEmpty
                                    ? '重新配对'
                                    : '重试连接',
                              ),
                            ),
                          ),
                        ],
                        if (!loading &&
                            error == null &&
                            current != null &&
                            current.token.isNotEmpty &&
                            items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 28),
                            child: Text('这台主机还没有共享 TXT 或 EPUB。'),
                          ),
                        if (current != null)
                          for (final item in items) _row(current, item),
                      ],
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

  Widget _row(HubHost current, HubResource item) {
    final hub = widget.hub, key = HubLibrary.originKey(current.id, item.id);
    final old = hub.library.hubEdition(key);
    final updated = old != null && old.id != item.digest;
    final local = hub.library.findBook(item.digest);
    final reference = hub.library.hubReference(hub.readingId(current.id, item));
    final state =
        hub.stages[key] ??
        (local != null
            ? '可离线阅读'
            : updated
            ? '在线阅读 · 有新版本'
            : reference != null
            ? '在线阅读 · 已在书架'
            : '在线阅读');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(item.name),
      subtitle: Text(
        [
          if (item.size < 1 << 20)
            '${(item.size / 1024).ceil()} KiB'
          else
            '${(item.size / (1 << 20)).toStringAsFixed(1)} MiB',
          state,
        ].join(' · '),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '${item.name}的更多操作',
        enabled: opening == null,
        onSelected: (action) {
          if (action == 'old') {
            Navigator.pop(context, old);
            return;
          }
          select(current, item, action);
        },
        itemBuilder: (_) => [
          if (reference == null && local == null)
            const PopupMenuItem(value: 'shelf', child: Text('加入书架')),
          if (local == null)
            const PopupMenuItem(value: 'download', child: Text('下载到本机')),
          if (reference != null && local != null && hub.canRemoveCopy(local))
            const PopupMenuItem(value: 'remove', child: Text('移除本机下载')),
          if (updated) const PopupMenuItem(value: 'old', child: Text('打开旧版')),
          if (local != null)
            const PopupMenuItem(value: 'open', child: Text('阅读本机版')),
        ],
      ),
      onTap: opening != null ? null : () => select(current, item, 'open'),
    );
  }
}

class _PairPage extends StatefulWidget {
  const _PairPage(this.hub, {this.previous, required this.onConnected});
  final HubLibrary hub;
  final HubHost? previous;
  final ValueChanged<HubHost> onConnected;
  @override
  State<_PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<_PairPage> {
  late final address = TextEditingController(text: widget.previous?.address);
  late final pin = TextEditingController(text: widget.previous?.pin);
  late final name = TextEditingController(text: widget.previous?.name);
  final code = TextEditingController();
  late bool manual = widget.previous?.token.isNotEmpty == true;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [address, pin, name, code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final h = manual
          ? await widget.hub.connect(
              address.text,
              pin.text,
              code.text,
              name.text,
              previous: widget.previous,
            )
          : await widget.hub.connectByCode(
              code.text,
              previous: widget.previous,
            );
      if (mounted) widget.onConnected(h);
    } catch (e) {
      if (mounted) setState(() => error = hubMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('连接 NamiHub')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
            children: [
              Text(
                manual ? '填写电脑显示的连接信息。' : '手机和电脑连接同一局域网后，输入 NamiHub 显示的八位码。',
              ),
              const SizedBox(height: 18),
              if (manual)
                TextField(
                  controller: address,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS 地址',
                    hintText: 'https://192.168.1.10:8443',
                  ),
                ),
              if (manual)
                TextField(
                  controller: pin,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '证书 SHA-256 指纹'),
                ),
              TextField(
                controller: code,
                enabled: !busy,
                onSubmitted: (_) => submit(),
                enableIMEPersonalizedLearning: false,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: InputDecoration(
                  labelText: '八位配对码',
                  helperText:
                      manual && widget.previous?.token.isNotEmpty == true
                      ? '仅更新地址时可留空'
                      : null,
                ),
              ),
              if (manual)
                TextField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '主机备注（选填）'),
                ),
              const SizedBox(height: 22),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(error!),
                ),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? '正在连接…' : '连接主机'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        manual = !manual;
                        error = null;
                      }),
                child: Text(manual ? '使用八位码自动连接' : '手动连接'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
