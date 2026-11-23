part of 'nami_hub_client.dart';

class HubCandidate {
  HubCandidate._(this.origin, this.hubId, this.pin, this.invitation, this.hint);
  final Uri origin;
  final String hubId, pin;
  final String? invitation;
  final int? hint;

  static HubCandidate? _parse(Datagram packet, String nonce) {
    if (packet.data.length > 512) return null;
    try {
      final data = jsonDecode(utf8.decode(packet.data));
      if (data is! Map ||
          data['protocol'] != 'NamiHub/1' ||
          data['nonce'] != nonce)
        return null;
      final id = data['hubId'], pin = data['pin'], port = data['port'];
      final invite = data['invite'], hint = data['hint'];
      if (id is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,96}$').hasMatch(id) ||
          pin is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(pin) ||
          port is! int ||
          port < 1 ||
          port > 65535)
        return null;
      if (!(invite == null && hint == null) &&
          !(validNonce(invite) && hint is int && hint >= 0 && hint < 16))
        return null;
      return HubCandidate._(
        Uri(scheme: 'https', host: packet.address.address, port: port),
        id,
        pin,
        invite as String?,
        hint as int?,
      );
    } on FormatException {
      return null;
    }
  }
}

class HubLan {
  /// Sends a service query on each IPv4 interface and receives unicast replies.
  static Future<List<HubCandidate>> discover({
    InternetAddress? localGateway,
  }) async {
    final nonce = pairingNonce();
    final query = utf8.encode('$discoveryPrefix$nonce');
    final found = <String, HubCandidate>{};
    final sockets = <RawDatagramSocket>[];
    final broadcast = InternetAddress('255.255.255.255');
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    Future<void> probe(InternetAddress local) async {
      try {
        final socket = await RawDatagramSocket.bind(local, 0);
        sockets.add(socket);
        socket.broadcastEnabled = true;
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = socket.receive();
          if (packet == null || packet.port != discoveryPort) return;
          final host = HubCandidate._parse(packet, nonce);
          if (host != null && found.length < 128) {
            found['${host.origin}|${host.hubId}|${host.pin}|${host.invitation}'] =
                host;
          }
        }, onError: (Object _) {});
      } on SocketException {
        // Other active interfaces may still be able to reach the Hub.
      }
    }

    try {
      await Future.wait([
        for (final n in interfaces)
          for (final a in n.addresses) probe(a),
        probe(InternetAddress.loopbackIPv4),
      ]);
      for (var round = 0; round < 2; round++) {
        for (final socket in sockets) {
          try {
            // A computer sharing its Wi-Fi hotspot is also the default gateway.
            if (!socket.address.isLoopback &&
                localGateway?.type == InternetAddressType.IPv4) {
              socket.send(query, localGateway!, discoveryPort);
            }
            socket.send(
              query,
              socket.address.isLoopback
                  ? InternetAddress.loopbackIPv4
                  : broadcast,
              discoveryPort,
            );
          } on SocketException {
            /* A disconnected adapter can disappear mid-query. */
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
      return found.values.toList();
    } finally {
      for (final socket in sockets) {
        socket.close();
      }
    }
  }

  static Future<HubClient> _verified(Uri origin, String pin, String id) async {
    final client = HubClient(origin: origin, certificateSha256: pin);
    try {
      final info = await client.info().timeout(const Duration(seconds: 4));
      if (info['apiVersion'] != 1 || info['hubId'] != id)
        throw const HubException('hub_identity_changed');
      return client;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  /// Returns an open authenticated client. Persist origin, certificateSha256
  /// and session in the platform's credential store, then close when done.
  static Future<HubClient> pair(
    String code,
    String clientName, {
    String? expectedHubId,
    InternetAddress? localGateway,
  }) async {
    if (!RegExp(r'^[0-9]{8}$').hasMatch(code))
      throw const HubException('invalid_pair_code', 403);
    final name = clientName.trim();
    final candidates = await discover(localGateway: localGateway);
    if (candidates.isEmpty) throw const HubException('discovery_empty');
    final matches = candidates
        .where(
          (h) =>
              (expectedHubId == null || h.hubId == expectedHubId) &&
              h.invitation != null &&
              routingHint(h.invitation!, code) == h.hint,
        )
        .toList();
    if (matches.isEmpty)
      throw const HubException('invalid_or_expired_code', 403);
    final identities = matches
        .map((h) => '${h.hubId}|${h.pin}|${h.invitation}')
        .toSet();
    if (identities.length != 1) throw const HubException('ambiguous_pair_code');

    final h = matches.first;
    final client = await _openCandidate(matches);
    try {
      final proof = ClientProof(
        PairContext(h.hubId, h.pin, name, h.invitation!, code),
      );
      final challenge = await client._pairMessage('begin', {
        'invite': h.invitation,
        'clientName': name,
        'A': proof.offer,
      });
      if (!validNonce(challenge['ticket']))
        throw const HubException('invalid_pair_response');
      final result = await client._pairMessage('finish', {
        'ticket': challenge['ticket'],
        'M1': proof.answer(challenge['B']),
      });
      if (!proof.accepts(result['M2']) ||
          result['hubId'] != h.hubId ||
          result['deviceId'] is! String ||
          result['accessToken'] is! String) {
        throw const HubException('invalid_pair_response');
      }
      client.session = HubSession(
        hubId: h.hubId,
        deviceId: result['deviceId'],
        token: result['accessToken'],
      );
      return client;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  static Future<HubClient> _openCandidate(List<HubCandidate> aliases) async {
    final routes = aliases.take(8).toList();
    for (final h in routes) {
      try {
        return await _verified(h.origin, h.pin, h.hubId);
      } on Exception {
        if (identical(h, routes.last)) rethrow;
      }
    }
    throw const HubException('discovery_empty');
  }

  /// Tries the saved address first (including 0.1.0 hosts), then rediscovers
  /// the original identity. Credentials are attached only after verification.
  static Future<HubClient> restore(
    Uri origin,
    String pin,
    HubSession session, {
    InternetAddress? localGateway,
  }) async {
    HubClient client;
    try {
      client = await _verified(origin, pin, session.hubId);
    } on Exception {
      final candidates = (await discover(
        localGateway: localGateway,
      )).where((h) => h.hubId == session.hubId).toList();
      if (candidates.isEmpty) rethrow;
      final matches = candidates.where((h) => h.pin == pin).toList();
      if (matches.isEmpty) throw const HubException('certificate_mismatch');
      client = await _openCandidate(matches);
    }
    client.session = session;
    return client;
  }
}
