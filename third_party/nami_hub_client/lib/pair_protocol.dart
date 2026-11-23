/// Wire primitives shared by the Windows host and the SDK.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/srp/srp6_client.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

const discoveryPort = 47832;
const discoveryPrefix = 'NAMI-HUB/1 ';
final _rng = Random.secure();
Uint8List _bytes(int count) =>
    Uint8List.fromList(List.generate(count, (_) => _rng.nextInt(256)));
String pairingNonce() => base64Url.encode(_bytes(16)).replaceAll('=', '');
bool validNonce(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value);
int routingHint(String invitation, String code) =>
    sha256
        .convert(utf8.encode('NamiHub/route/1:$invitation:$code'))
        .bytes
        .first &
    15;

final _group = SRP6StandardGroups.rfc5054_3072;
FortunaRandom _random() => FortunaRandom()..seed(KeyParameter(_bytes(32)));

BigInt _parse(Object? raw, {required int digits}) {
  if (raw is! String ||
      raw.isEmpty ||
      raw.length > digits ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(raw)) {
    throw const FormatException('Invalid pairing message');
  }
  return BigInt.parse(raw, radix: 16);
}

BigInt _public(Object? raw) {
  final value = _parse(raw, digits: 768);
  if (value <= BigInt.one || value >= _group.N - BigInt.one) {
    throw const FormatException('Invalid SRP public value');
  }
  return value;
}

class PairContext {
  PairContext(
    String hubId,
    String fingerprint,
    String name,
    String invitation,
    String code,
  ) : salt = base64Url.decode(base64Url.normalize(invitation)),
      identity = utf8.encode(
        jsonEncode(['NamiHub/SRP6a/1', hubId, fingerprint, name, invitation]),
      ),
      password = utf8.encode(code);
  final Uint8List salt, identity, password;
}

class ClientProof {
  ClientProof(PairContext ctx) {
    offer = _client
        .generateClientCredentials(ctx.salt, ctx.identity, ctx.password)!
        .toRadixString(16);
  }
  final _client = SRP6Client(
    group: _group,
    digest: SHA256Digest(),
    random: _random(),
  );
  late final String offer;
  String answer(Object? challenge) {
    _client.calculateSecret(_public(challenge));
    return _client.calculateClientEvidenceMessage()!.toRadixString(16);
  }

  bool accepts(Object? proof) =>
      _client.verifyServerEvidenceMessage(_parse(proof, digits: 64));
}

class HostProof {
  HostProof(PairContext ctx, Object? offer) {
    final a = _public(offer);
    final verifier = SRP6VerifierGenerator(
      group: _group,
      digest: SHA256Digest(),
    ).generateVerifier(ctx.salt, ctx.identity, ctx.password);
    _server = SRP6Server(
      group: _group,
      v: verifier,
      digest: SHA256Digest(),
      random: _random(),
    );
    challenge = _server.generateServerCredentials()!.toRadixString(16);
    _server.calculateSecret(a);
  }
  late final SRP6Server _server;
  late final String challenge;
  String? confirm(Object? proof) =>
      _server.verifyClientEvidenceMessage(_parse(proof, digits: 64))
      ? _server.calculateServerEvidenceMessage()!.toRadixString(16)
      : null;
}
