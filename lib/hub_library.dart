import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nami_hub_client/nami_hub_client.dart';
import 'package:path/path.dart' as p;

import 'book_import.dart';
import 'library.dart';
import 'hub_reading.dart';
import 'hub_zip.dart';

class HubHost {
  const HubHost(
    this.id,
    this.name,
    this.address,
    this.pin,
    this.device,
    this.token,
  );
  final String id, name, address, pin, device, token;
  HubHost.fromJson(Data j)
    : this(j['id'], j['name'], j['address'], j['pin'], j['device'], j['token']);
  Data toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'pin': pin,
    'device': device,
    'token': token,
  };
  HubSession get session =>
      HubSession(hubId: id, deviceId: device, token: token);
}

String hubMessage(Object e) {
  if (e is HandshakeException ||
      e is HubException && e.code == 'certificate_mismatch') {
    return '证书未通过验证，请与电脑上显示的 SHA-256 指纹核对。';
  }
  if (e is HubException) {
    switch (e.code) {
      case 'discovery_empty':
        return '没有找到正在共享的电脑。请确认连接同一局域网，重试或选择手动连接。';
      case 'ambiguous_pair_code':
        return '发现多台可能匹配的主机。请在目标电脑生成新码后重试。';
      case 'invalid_or_expired_code':
        return '没有匹配的有效配对码，请核对电脑上的八码或生成新码。';
      case 'hub_identity_changed':
      case 'invalid_pair_response':
        return '主机身份未通过核验，请核对电脑后重新配对。';
      case 'pairing_busy':
        return '电脑正在处理其他配对，请稍后重试。';
    }
    return switch (e.status) {
      401 => '电脑端授权已失效，请重新配对。本地藏书仍可阅读。',
      403 => '配对码错误或已过期，请在电脑上生成新码。',
      404 => '电脑上已找不到这本书，请刷新书目。',
      409 => '电脑上的文件已变化，请在 NamiHub 重新索引，再刷新书目。',
      412 || 416 => '文件版本已变化，请刷新书目并重新获取。',
      _ => e.code == 'integrity_failed' ? '文件校验未通过，请重新获取。' : '主机未能完成请求，请重试。',
    };
  }
  if (e is SocketException || e is TimeoutException || e is HttpException) {
    return '无法连接主机，请确认电脑正在共享，且两台设备的网络可以互通。';
  }
  if (e is FileSystemException) return '未能保存书籍，请检查设备剩余空间后重试。';
  if (e is FormatException) return e.message;
  if (e is PlatformException) return e.message ?? '系统操作未完成，请重试。';
  return '此次操作未完成，请重试。';
}

typedef HubEncodingChoice = Future<String?> Function(
  Directory dir,
  String name,
);

class HubLibrary extends ChangeNotifier {
  HubLibrary(this.library);
  final Library library;
  List<HubHost> hosts = [];
  bool _loaded = false, _closed = false;
  Future<void> _writes = Future.value();
  final _clients = <HubClient, String>{};
  final _tasks = <String, ({String version, Future<Book> future})>{};
  final stages = <String, String>{};

  Future<void> load() async {
    if (_loaded) return;
    final json = await platform.invokeMethod<String>('hubConnections');
    hosts = [
      for (final h in jsonDecode(json!) as List) HubHost.fromJson(Data.from(h)),
    ];
    _loaded = true;
  }

  Future<void> _update(String id, HubHost? value, {HubHost? expected}) {
    final update = _writes.then((_) async {
      if (expected != null && !hosts.contains(expected)) return;
      final next = [?value, ...hosts.where((h) => h.id != id)];
      await platform.invokeMethod('saveHubConnections', {
        'json': jsonEncode(next),
      });
      hosts = next;
      _notify();
    });
    _writes = update.then<void>((_) {}, onError: (Object _) {});
    return update;
  }

  Future<void> forget(HubHost host) async {
    await _update(host.id, null);
    for (final entry
        in _clients.entries.where((e) => e.value == host.id).toList()) {
      entry.key.close();
    }
  }

  static String _identity(Data info) {
    if (info['apiVersion'] != 1) {
      throw const FormatException('此主机的 API 版本暂不支持。');
    }
    final id = info['hubId'];
    if (id is! String || id.isEmpty) throw const FormatException('主机身份无效。');
    return id;
  }

  Future<InternetAddress?> _gateway() async {
    if (!Platform.isAndroid) return null;
    try {
      return InternetAddress.tryParse(
        await platform.invokeMethod<String>('hubGateway') ?? '',
      );
    } on PlatformException {
      return null;
    }
  }

  Future<HubHost> connectByCode(String code, {HubHost? previous}) async {
    if (!RegExp(r'^[0-9]{8}$').hasMatch(code)) {
      throw const FormatException('请输入电脑显示的八位配对码。');
    }
    final client = await HubLan.pair(
      code,
      'NamiRead · Android',
      expectedHubId: previous?.id,
      localGateway: await _gateway(),
    );
    try {
      final s = client.session!;
      final host = HubHost(
        s.hubId,
        previous?.name ?? client.origin.host,
        client.origin.origin,
        client.certificateSha256,
        s.deviceId,
        s.token,
      );
      await _update(host.id, host);
      return host;
    } finally {
      client.close();
    }
  }

  HubHost? _current(HubHost host) => hosts
      .where(
        (h) =>
            h.id == host.id &&
            h.pin == host.pin &&
            h.token == host.token &&
            h.device == host.device,
      )
      .firstOrNull;

  Future<HubHost> connect(
    String address,
    String pin,
    String code,
    String name, {
    HubHost? previous,
  }) async {
    final uri = Uri.tryParse(address.trim());
    pin = pin.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path)) {
      throw const FormatException('请输入电脑显示的 HTTPS 地址和端口。');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) {
      throw const FormatException('SHA-256 指纹需要 64 位十六进制字符。');
    }
    final reuse =
        previous != null &&
        previous.token.isNotEmpty &&
        previous.pin == pin &&
        code.isEmpty;
    if (!reuse && !RegExp(r'^\d{8}$').hasMatch(code)) {
      throw const FormatException('请输入电脑显示的八位配对码。');
    }
    final client = HubClient(origin: uri, certificateSha256: pin);
    try {
      final id = _identity(await client.info());
      if (previous != null && id != previous.id) {
        throw const FormatException('主机身份与已保存的连接不同，请核对电脑。');
      }
      final session = reuse
          ? previous.session
          : await client.pair(code, 'NamiRead · Android');
      if (session.hubId != id ||
          session.token.isEmpty ||
          session.deviceId.isEmpty) {
        throw const FormatException('配对返回的主机身份无效。');
      }
      final host = HubHost(
        id,
        name.trim().isEmpty ? uri.host : name.trim(),
        uri.origin,
        pin,
        session.deviceId,
        session.token,
      );
      await _update(id, host);
      return host;
    } finally {
      client.close();
    }
  }

  Future<T> _remote<T>(HubHost host, Future<T> Function(HubClient) work) async {
    final saved = _current(host);
    if (saved == null || host.token.isEmpty) {
      throw const HubException('unauthorized', 401);
    }
    final client = await HubLan.restore(
      Uri.parse(saved.address),
      host.pin,
      host.session,
      localGateway: await _gateway(),
    );
    _clients[client] = host.id;
    try {
      if (_closed || _current(host) == null) {
        throw const FormatException('主机连接已更改，请重试。');
      }
      if (client.origin.origin != saved.address) {
        await _update(
          host.id,
          HubHost(
            host.id,
            saved.name,
            client.origin.origin,
            host.pin,
            host.device,
            host.token,
          ),
          expected: saved,
        );
      }
      if (_closed || _current(host) == null) {
        throw const FormatException('主机连接已更改，请重试。');
      }
      return await work(client);
    } on HubException catch (e) {
      final current = _current(host);
      if (e.status == 401 && current != null) {
        await _update(
          host.id,
          HubHost(
            host.id,
            current.name,
            current.address,
            host.pin,
            host.device,
            '',
          ),
          expected: current,
        );
      }
      rethrow;
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  Future<List<HubResource>> browse(HubHost host) =>
      _remote(host, (client) async {
        final items = <String, HubResource>{};
        await for (final item in client.resources(type: 'book')) {
          if (_supported(item)) items[item.id] = item;
        }
        return items.values.toList()..sort((a, b) => a.name.compareTo(b.name));
      });

  static bool _supported(HubResource book) =>
      book.type == 'book' &&
      {'.epub', '.txt'}.contains(p.extension(book.name).toLowerCase());
  static String originKey(String hub, String id) =>
      sha256.convert(utf8.encode(jsonEncode([hub, id]))).toString();

  String readingId(String hostId, HubResource item) =>
      originKey(originKey(hostId, item.id), item.version);

  // Only directory metadata survives requests. Chapter bytes belong to the reader.
  final _indices = <String, HubReading>{};

  Future<T> _withBytes<T>(
    String hostId,
    HubResource item,
    Future<T> Function(HubBytes) work,
  ) async {
    final local = library.findBook(item.digest);
    if (local != null) {
      final file = await File(p.join(local.dir.path, 'original')).open();
      try {
        return await work((offset, length) async {
          await file.setPosition(offset);
          final data = await file.read(length);
          if (data.length != length) throw const FormatException('本机副本不完整。');
          return data;
        });
      } finally {
        await file.close();
      }
    }
    await load();
    final host = hosts.where((h) => h.id == hostId).firstOrNull;
    if (host == null || host.token.isEmpty) {
      throw const FormatException('请返回 NamiHub 书目，重新配对此主机。');
    }
    return _remote(
      host,
      (client) => work((offset, length) async {
        if (length == 0) return Uint8List(0);
        final result = BytesBuilder(copy: false);
        final stream = await client.read(
          item,
          start: offset,
          end: offset + length - 1,
        );
        await for (final chunk in stream) {
          result.add(chunk);
        }
        if (result.length != length) throw const FormatException('读取中断，请重试连接。');
        return result.takeBytes();
      }),
    );
  }

  Future<HubReading> _index(
    String host,
    HubResource item,
    HubBytes bytes,
  ) async {
    final id = readingId(host, item);
    final cached = _indices[id];
    if (cached != null) return cached;
    final index = await HubReading.open(host, item, id, bytes);
    if (_indices.length >= 3) _indices.remove(_indices.keys.first);
    _indices[id] = index;
    return index;
  }

  Future<Book> online(HubHost host, HubResource item) async {
    final id = readingId(host.id, item), local = library.findBook(item.digest);
    final ref = library.hubReference(id);
    if (local != null &&
        ((ref == null &&
                library.positions[id] == null &&
                library.bookmarks[id] == null) ||
            (local.format == 'TXT' && local.meta['encoding'] != 'UTF-8'))) {
      return local;
    }
    if (ref != null) return ref;
    final index = await _withBytes(
      host.id,
      item,
      (read) => _index(host.id, item, read),
    );
    return library.hubBook(index.meta);
  }

  Future<String> chapter(Book book, int number) async {
    final host = book.meta['hubId'] as String,
        item = HubResource.fromJson(Data.from(book.meta['hubItem']));
    return _withBytes(host, item, (read) async {
      final index = await _index(host, item, read);
      return index.chapter(number, read);
    });
  }

  Future<Book> linkDownload(HubHost host, HubResource item, Book local) async {
    if (local.id != item.digest ||
        local.meta['hubDownload'] != true ||
        library.saved(local) != null ||
        (local.format == 'TXT' && local.meta['encoding'] != 'UTF-8')) {
      return local;
    }
    try {
      final index = await _withBytes(
        host.id,
        item,
        (read) => _index(host.id, item, read),
      );
      final ref = library.hubBook(index.meta);
      await library.saveHubReference(ref);
      return ref;
    } on FormatException {
      // A local import can support editions outside the range reader's format profile.
      return local;
    }
  }

  bool canRemoveCopy(Book local) => library.canRemoveHubCopy(local);

  Future<void> removeCopy(Book reference) async {
    final local = library.findBook(reference.meta['hubItem']['sha256']);
    if (local == null || !canRemoveCopy(local)) return;
    await library.saveHubReference(reference);
    await library.remove(local);
  }

  Future<Book> obtain(
    HubHost host,
    HubResource item,
    HubEncodingChoice choose,
  ) {
    final key = originKey(host.id, item.id);
    final active = _tasks[key];
    if (active != null) {
      if (active.version == item.version) return active.future;
      return Future.error(const FormatException('正在获取这个条目的另一版本，请稍后重试。'));
    }
    stages[key] = '正在获取';
    final future = _obtain(host, item, key, choose).whenComplete(() {
      _tasks.remove(key);
      stages.remove(key);
      _notify();
    });
    _tasks[key] = (version: item.version, future: future);
    _notify();
    return future;
  }

  Future<Book> _obtain(
    HubHost host,
    HubResource item,
    String key,
    HubEncodingChoice choose,
  ) async {
    final generation = library.generation;
    final root = await platform.invokeMethod<String>('hubCache');
    final dir = Directory(p.join(root!, key));
    void check() {
      library.checkGeneration(generation);
      if (_closed || _current(host) == null) {
        throw const FormatException('主机连接已更改，请重试。');
      }
    }

    Future<Book?> localEdition(HubResource book) async {
      check();
      if (!_supported(book) || book.size <= 0 || book.size > (96 << 20)) {
        throw const FormatException('请选择非空且不超过 96 MiB 的 TXT 或 EPUB。');
      }
      return library.reuseHubBook(book.digest, key, generation);
    }

    Future<Book> install(HubClient client, HubResource book) async {
      check();
      final target = File(p.join(dir.path, book.version, 'original'));
      final partial = File('${target.path}.${book.version}.part');
      final available = await platform.invokeMethod<int>('hubSpace');
      final retained = await target.exists()
          ? await target.length()
          : await partial.exists()
          ? await partial.length()
          : 0;
      if (available! <
          (8 << 20) + book.size * 4 - math.min(retained, book.size)) {
        throw const FormatException('设备空间不足，请释放空间后重试。');
      }
      await client.download(book, target);
      check();
      stages[key] = '正在整理';
      _notify();
      final stage = await library.staging.createTemp('hub-');
      try {
        final raw = await target.copy(p.join(stage.path, 'original'));
        String? encoding;
        final name = p.posix.basename(book.name.replaceAll('\\', '/'));
        if (p.extension(name).toLowerCase() == '.txt') {
          final handle = await raw.open();
          late List<int> head;
          try {
            head = await handle.read(2);
          } finally {
            await handle.close();
          }
          encoding = listEquals(head, [255, 254])
              ? 'UTF-16LE'
              : listEquals(head, [254, 255])
              ? 'UTF-16BE'
              : 'UTF-8';
          try {
            await platform.invokeMethod('decode', {
              'dir': stage.path,
              'encoding': encoding,
              'hub': true,
            });
          } on PlatformException catch (e) {
            if (e.code != 'encoding') rethrow;
            encoding = await choose(stage, name);
            if (encoding == null) {
              throw const FormatException('已保留下载，下次可继续选择编码。');
            }
          }
        }
        check();
        return await finishBookImport(
          library,
          stage,
          name: name,
          id: book.digest,
          encoding: encoding,
          hubOrigin: key,
          generation: generation,
          check: check,
        );
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    }

    final saved =
        await localEdition(item) ??
        await _remote<Book>(host, (client) async {
          try {
            return await install(client, item);
          } on HubException catch (e) {
            if (e.status != 412 && e.status != 416) rethrow;
            final fresh = await client.resource(item.id);
            if (fresh.id != item.id) throw const FormatException('主机返回了不同的书目。');
            if (e.status == 416 && fresh.version == item.version) {
              final part = File(
                p.join(dir.path, item.version, 'original.${item.version}.part'),
              );
              if (await part.exists()) await part.delete();
            }
            return await localEdition(fresh) ?? await install(client, fresh);
          }
        });
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // The validated copy remains reusable after an interrupted cleanup.
    }
    return saved;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    for (final client in _clients.keys) {
      client.close();
    }
    super.dispose();
  }
}
