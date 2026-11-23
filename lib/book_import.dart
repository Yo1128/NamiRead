import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'library.dart';
import 'parser.dart';

Future<Book> finishBookImport(
  Library library,
  Directory stage, {
  required String name,
  required String id,
  String? uri,
  String? encoding,
  String? hubOrigin,
  required int generation,
  required void Function() check,
}) async {
  final meta = await prepareBook(
    stage,
    name: name,
    id: id,
    uri: uri,
    encoding: encoding,
  );
  if (hubOrigin != null) meta['hubDownload'] = true;
  check();
  try {
    return await library.commit(
      stage,
      meta,
      hubOrigin: hubOrigin,
      expectedGeneration: generation,
    );
  } on FormatException {
    library.checkGeneration(generation);
    final existing = hubOrigin == null
        ? await library.reuseLocalBook(id, generation)
        : await library.reuseHubBook(id, hubOrigin, generation);
    if (existing == null) rethrow;
    return existing;
  }
}

Future<Data> prepareBook(
  Directory stage, {
  required String name,
  required String id,
  String? uri,
  String? encoding,
}) async {
  final meta = await compute(parseBook, {
    'dir': stage.path,
    'name': name,
    'id': id,
    'uri': uri,
    'encoding': encoding,
  });
  if (id ==
      'c8be8d40b16f18ff24253d97e73254c65a377f557c4b6baf768287eab59e4a0a') {
    final cover = await rootBundle.load('assets/samples/tide-cover.webp');
    await File(p.join(stage.path, 'cover.img')).writeAsBytes(
      cover.buffer.asUint8List(cover.offsetInBytes, cover.lengthInBytes),
    );
    meta['author'] = '许舟';
    meta['cover'] = true;
  }
  return meta;
}
