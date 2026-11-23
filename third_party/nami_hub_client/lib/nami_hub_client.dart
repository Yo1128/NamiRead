library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'pair_protocol.dart';

part 'lan_pairing.dart';

typedef HubJson = Map<String, dynamic>;

class HubException implements Exception {
  const HubException(this.code, [this.status]);
  final String code;
  final int? status;
  @override
  String toString() =>
      'HubException($code${status == null ? '' : ', $status'})';
}

class HubResource {
  HubResource.fromJson(HubJson json)
    : id = json['resourceId'] as String,
      name = json['displayName'] as String,
      type = json['type'] as String,
      mimeType = json['mimeType'] as String,
      version = json['contentVersion'] as String,
      digest = json['sha256'] as String,
      size = json['sizeBytes'] as int {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        version != digest ||
        size < 0) {
      throw const FormatException('Invalid v1 resource identity or size');
    }
  }
  final String id, name, type, mimeType, version, digest;
  final int size;
}

class HubSession {
  const HubSession({
    required this.hubId,
    required this.deviceId,
    required this.token,
  });
  final String hubId, deviceId, token;
}

class HubClient {
  HubClient({
    required this.origin,
    required String certificateSha256,
    this.session,
  }) : _pin = certificateSha256.toLowerCase().replaceAll(':', ''),
       _http = HttpClient(context: SecurityContext(withTrustedRoots: false)) {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        !['', '/'].contains(origin.path) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(_pin))
      throw ArgumentError(
        'Expected HTTPS origin and SHA-256 certificate fingerprint.',
      );
    _http.findProxy = (_) => 'DIRECT';
    _http
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false
      ..badCertificateCallback = (cert, host, port) {
        final now = DateTime.now();
        return host == origin.host &&
            port == origin.port &&
            now.isAfter(cert.startValidity) &&
            now.isBefore(cert.endValidity) &&
            sha256.convert(cert.der).toString() == _pin;
      };
  }
  final Uri origin;
  final String _pin;
  String get certificateSha256 => _pin;
  final HttpClient _http;
  HubSession? session;
  static const _timeout = Duration(seconds: 30);
  static final _writing = <String>{};
  void close() => _http.close(force: true);

  /// Native players must apply the same certificate trust and keep headers private.
  ({Uri uri, Map<String, String> headers, String certificateSha256})
  playbackRequest(HubResource item) {
    final auth = session;
    if (auth == null) throw const HubException('pair_required');
    return (
      uri: origin.replace(path: '/v1/resources/${item.id}/content'),
      headers: Map<String, String>.unmodifiable({
        'Authorization': 'Bearer ${auth.token}',
        'If-Match': '"${item.version}"',
      }),
      certificateSha256: _pin,
    );
  }

  Future<HttpClientResponse> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    HubJson? body,
    bool authenticated = true,
  }) async {
    final auth = session;
    if (authenticated && auth == null)
      throw const HubException('pair_required');
    final req = await _http
        .openUrl(method, origin.replace(path: path, queryParameters: query))
        .timeout(_timeout);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (authenticated)
      req.headers.set('Authorization', 'Bearer ${auth!.token}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(
      _timeout,
      onTimeout: () {
        req.abort();
        throw TimeoutException('Hub response timed out');
      },
    );
    final peer = res.certificate;
    if (peer == null || sha256.convert(peer.der).toString() != _pin) {
      close();
      throw const HubException('certificate_mismatch');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      var error = 'http_error';
      try {
        final json = await _readJson(res, 8192);
        if (json is Map && json['error'] is String) error = json['error'];
      } on FormatException {
        /* Non-JSON proxy or server response. */
      }
      throw HubException(error, res.statusCode);
    }
    return res;
  }

  Future<dynamic> _readJson(HttpClientResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > limit)
        throw const FormatException('Oversized Hub response');
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<HubJson> _json(
    Future<HttpClientResponse> response, {
    int limit = 4 << 20,
  }) async {
    final value = await _readJson(await response, limit);
    if (value is! HubJson) throw const FormatException('Invalid Hub response');
    return value;
  }

  Future<HubJson> info() =>
      _json(_request('GET', '/v1/info', authenticated: false), limit: 4096);
  Future<HubJson> _pairMessage(String step, HubJson body) => _json(
    _request('POST', '/v1/pair/$step', authenticated: false, body: body),
    limit: 4096,
  );
  Future<HubSession> pair(String code, String clientName) async {
    final data = await _json(
      _request(
        'POST',
        '/v1/pair',
        authenticated: false,
        body: {'code': code, 'clientName': clientName},
      ),
    );
    return session = HubSession(
      hubId: data['hubId'],
      deviceId: data['deviceId'],
      token: data['accessToken'],
    );
  }

  Stream<HubResource> resources({String? type, int pageSize = 50}) async* {
    String? cursor;
    do {
      final data = await _json(
        _request(
          'GET',
          '/v1/resources',
          query: {
            'limit': '$pageSize',
            if (type != null) 'type': type,
            if (cursor != null) 'cursor': cursor,
          },
        ),
      );
      for (final item in data['items'] as List) {
        yield HubResource.fromJson(item as HubJson);
      }
      final next = data['nextCursor'] as String?;
      if (next != null && cursor != null && next.compareTo(cursor) <= 0)
        throw const HubException('invalid_cursor');
      cursor = next;
    } while (cursor != null);
  }

  Future<HubResource> resource(String id) async => HubResource.fromJson(
    await _json(_request('GET', '/v1/resources/${Uri.encodeComponent(id)}')),
  );

  /// Reads a version-checked whole file or inclusive byte range.
  Future<Stream<List<int>>> read(
    HubResource item, {
    int? start,
    int? end,
  }) async {
    if (start == null && end != null ||
        start != null && (start < 0 || end != null && end < start))
      throw ArgumentError('Invalid byte range');
    final tag = '"${item.version}"';
    final res = await _request(
      'GET',
      '/v1/resources/${item.id}/content',
      headers: {
        'If-Match': tag,
        if (start != null) 'Range': 'bytes=$start-${end ?? ''}',
      },
    );
    final last = end == null || end >= item.size ? item.size - 1 : end;
    if (res.statusCode != (start == null ? 200 : 206) ||
        res.headers.value('etag') != tag ||
        res.contentLength != last - (start ?? 0) + 1 ||
        (start != null &&
            res.headers.value('content-range') !=
                'bytes $start-$last/${item.size}')) {
      final socket = await res.detachSocket();
      socket.destroy();
      throw const HubException('invalid_content_response');
    }
    return res.timeout(_timeout);
  }

  /// The caller chooses a private destination. A failed update preserves its previous contents.
  Future<File> download(
    HubResource item,
    File destination, {
    int retries = 1,
  }) async {
    RangeError.checkValueInInterval(retries, 0, 3, 'retries');
    for (var attempt = 0; ; attempt++) {
      try {
        return await _downloadOnce(item, destination);
      } catch (error) {
        if (attempt == retries ||
            !(error is SocketException ||
                error is HttpException ||
                error is TimeoutException))
          rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
  }

  Future<File> _downloadOnce(HubResource item, File destination) async {
    await destination.parent.create(recursive: true);
    final key = destination.absolute.path;
    if (!_writing.add(key)) throw const HubException('download_busy');
    RandomAccessFile? lock;
    try {
      lock = await File('$key.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      if (await destination.exists() && await _matches(destination, item))
        return destination;
      final partial = File('$key.${item.version}.part');
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > item.size) {
        await partial.delete();
        offset = 0;
      }
      if (offset < item.size || !await partial.exists()) {
        final stream = await read(item, start: offset == 0 ? null : offset);
        final writer = await partial.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        try {
          await for (final chunk in stream) {
            await writer.writeFrom(chunk);
          }
          await writer.flush();
        } finally {
          await writer.close();
        }
      }
      if (!await _matches(partial, item)) {
        await partial.delete();
        throw const HubException('integrity_failed');
      }
      await partial.rename(destination.path);
      return destination;
    } finally {
      try {
        await lock?.close();
      } finally {
        _writing.remove(key);
      }
    }
  }

  Future<bool> _matches(File file, HubResource item) async =>
      await file.length() == item.size &&
      (await sha256.bind(file.openRead()).first).toString() == item.digest;
}
