import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

typedef KnxValue = Object;

class KnxTelegram {
  KnxTelegram(
    this.id,
    this.time,
    this.direction,
    this.source,
    this.destination,
    this.type, {
    this.dpt,
    this.value,
  });
  final int id;
  final DateTime time;
  final String direction, source, destination, type;
  final String? dpt, value;
}

/// Owns the KNXnet/IP tunnel and translates cEMI group telegrams.
class KnxClient {
  RawDatagramSocket? _socket;
  InternetAddress? _gateway;
  InternetAddress? _dataEndpoint;
  int _port = 3671;
  int _dataPort = 3671;
  int _channel = 0;
  int _individualAddress = 0;
  int _sequence = 0;
  bool _connected = false;
  bool monitorPaused = false;
  int _nextId = 1;
  Timer? _keepAliveTimer;
  DateTime? _lastHeartbeatResponse;
  Completer<void>? _connectResponse;
  final Map<String, Completer<Object>> _reads = {};
  final List<KnxTelegram> history = [];
  void Function()? onChange;
  void Function(String address, Object value)? onValue;
  void Function()? onConnection;
  bool get connected => _connected;

  Future<void> connect(String host, int port) async {
    await disconnect();
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw SocketException('Gateway address could not be resolved.');
    }
    _gateway = addresses.first;
    _port = port;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    _socket!.listen(
      _receive,
      onError: (Object e) {
        _markDisconnected();
      },
    );
    // KNXnet/IP requires both the control and data HPAI structures in a
    // tunnelling connect request. A null HPAI lets the gateway use the UDP
    // packet's source address, which also works on devices with multiple NICs.
    const nullHpai = <int>[0x08, 0x01, 0, 0, 0, 0, 0, 0];
    final request = <int>[
      0x06,
      0x10,
      0x02,
      0x05,
      0,
      0,
      ...nullHpai,
      ...nullHpai,
      0x04,
      0x04,
      0x02,
      0x00,
    ];
    request[4] = request.length >> 8;
    request[5] = request.length & 255;
    final response = Completer<void>();
    _connectResponse = response;
    try {
      _socket!.send(request, _gateway!, _port);
      await response.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      if (identical(_connectResponse, response)) _connectResponse = null;
      _markDisconnected();
      rethrow;
    } finally {
      if (identical(_connectResponse, response)) _connectResponse = null;
    }
    onConnection?.call();
    _lastHeartbeatResponse = DateTime.now();
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_connected && _socket != null && _gateway != null) {
        final lastResponse = _lastHeartbeatResponse;
        if (lastResponse == null ||
            DateTime.now().difference(lastResponse) >
                const Duration(seconds: 40)) {
          _markDisconnected();
          return;
        }
        try {
          _socket!.send(
            _packet(0x0207, [_channel, 0, 0x08, 0x01, 0, 0, 0, 0, 0, 0]),
            _gateway!,
            _port,
          );
        } on SocketException {
          _markDisconnected();
        }
      }
    });
  }

  int _service(List<int> b) => (b[2] << 8) | b[3];
  List<int> _packet(int service, List<int> body) {
    final out = <int>[0x06, 0x10, service >> 8, service & 255, 0, 0, ...body];
    out[4] = out.length >> 8;
    out[5] = out.length & 255;
    return out;
  }

  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (_connected && _socket != null && _gateway != null) {
      try {
        _socket!.send(
          _packet(0x0209, [_channel, 0, 0x08, 0x01, 0, 0, 0, 0, 0, 0]),
          _gateway!,
          _port,
        );
      } on SocketException {
        // Always release the local UDP socket, even if the gateway vanished.
      }
    }
    _markDisconnected();
  }

  void _markDisconnected() {
    final wasConnected = _connected;
    final connectResponse = _connectResponse;
    _connectResponse = null;
    if (connectResponse != null && !connectResponse.isCompleted) {
      connectResponse.completeError(StateError('KNX connection closed.'));
    }
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _connected = false;
    _socket?.close();
    _socket = null;
    _dataEndpoint = null;
    _lastHeartbeatResponse = null;
    _pendingDpt.clear();
    for (final c in _reads.values) {
      if (!c.isCompleted) c.completeError(StateError('Disconnected.'));
    }
    _reads.clear();
    if (wasConnected) onConnection?.call();
  }

  void _sendCemi(
    List<int> cemi, {
    required String address,
    required String type,
    String? value,
    String? dpt,
  }) {
    if (!_connected || _socket == null || _dataEndpoint == null) {
      throw StateError('Connect to the KNX gateway first.');
    }
    final seq = _sequence++ & 255;
    try {
      _socket!.send(
        _packet(0x0420, [4, _channel, seq, 0, ...cemi]),
        _dataEndpoint!,
        _dataPort,
      );
    } on SocketException {
      _markDisconnected();
      rethrow;
    }
    // TX records the group telegram sent by this client. Tunnel packet ACKs
    // are transport bookkeeping and are not shown as bus telegrams.
    _record(
      'tx',
      _individual(_individualAddress),
      address,
      type,
      dpt: dpt,
      value: value,
    );
  }

  List<int> _group(String address) {
    final parts = address.split('/').map(int.parse).toList();
    if (parts.length != 3 || parts[0] > 31 || parts[1] > 7 || parts[2] > 255) {
      throw const FormatException(
        'Use a three-level group address such as 1/0/1.',
      );
    }
    final value = (parts[0] << 11) | (parts[1] << 8) | parts[2];
    return [value >> 8, value & 255];
  }

  List<int> _cemi(String address, int apci, List<int> payload) {
    final group = _group(address);
    final apdu = apci == 0
        ? [0x00, 0x00]
        : [
            0x00,
            apci | (payload.isEmpty ? 0 : payload.first & 0x3f),
            ...payload.skip(1),
          ];
    return [
      0x11,
      0x00,
      0xbe,
      0xe0,
      _individualAddress >> 8,
      _individualAddress & 255,
      ...group,
      apdu.length - 1,
      ...apdu,
    ];
  }

  Future<Object> read(String address, String dpt) async {
    final activeRead = _reads[address];
    if (activeRead != null) return activeRead.future;
    _pendingDpt[address] = dpt;
    _knownDpt[address] = dpt;
    final c = Completer<Object>();
    _reads[address] = c;
    try {
      _sendCemi(
        _cemi(address, 0, []),
        address: address,
        type: 'read',
        dpt: dpt,
      );
      return await c.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('No group response received.'),
      );
    } catch (error, stackTrace) {
      if (identical(_reads[address], c)) _reads.remove(address);
      if (identical(_pendingDpt[address], dpt)) _pendingDpt.remove(address);
      if (!c.isCompleted) c.completeError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> write(String address, String dpt, Object value) async {
    _knownDpt[address] = dpt;
    final payload = _encode(dpt, value);
    final isBit = dpt.startsWith('1.');
    final data = isBit
        ? <int>[0x00, payload.isEmpty ? 0 : payload.first]
        : <int>[...payload];
    final apdu = <int>[
      0x00,
      0x80 | (isBit ? (data.last & 1) : 0),
      if (!isBit) ...data,
    ];
    final group = _group(address);
    final cemi = <int>[
      0x11,
      0x00,
      0xbe,
      0xe0,
      0x00,
      0x00,
      ...group,
      apdu.length - 1,
      ...apdu,
    ];
    _sendCemi(
      cemi,
      address: address,
      type: 'write',
      value:
          '0x${payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      dpt: dpt,
    );
  }

  void requestRead(String address, String dpt) {
    if (_connected) {
      try {
        _sendCemi(
          _cemi(address, 0, []),
          address: address,
          type: 'read',
          dpt: dpt,
        );
      } catch (_) {}
    }
  }

  List<int> _encode(String dpt, Object value) {
    if (dpt.startsWith('1.')) {
      return [value == true || value == 1 || value == '1' ? 1 : 0];
    }
    final n = value is num ? value.toDouble() : double.tryParse('$value');
    if (dpt == '5.001' && n != null) {
      return [(n * 255 / 100).round().clamp(0, 255)];
    }
    if (dpt == '5.003' && n != null) {
      return [(n * 255 / 360).round().clamp(0, 255)];
    }
    if (dpt.startsWith('5.') && n != null) return [n.round().clamp(0, 255)];
    if (dpt == '9.001' && n != null) {
      var exponent = 0;
      var mantissa = (n * 100).round();
      while ((mantissa < -2048 || mantissa > 2047) && exponent < 15) {
        mantissa = (n * 100 / pow(2, ++exponent)).round();
      }
      final raw =
          (mantissa < 0 ? 0x800 | (mantissa & 0x7ff) : mantissa) |
          (exponent << 11);
      return [raw >> 8, raw & 255];
    }
    if (dpt.startsWith('7.') && n != null) {
      return [(n.round() >> 8) & 255, n.round() & 255];
    }
    if (dpt.startsWith('20.') && n != null) return [n.round().clamp(0, 255)];
    if (dpt.startsWith('16.')) {
      // KNX DPT 16 text is carried as single-byte Latin-1 characters.
      final encoded = '$value'.runes
          .map((character) => character <= 0xff ? character : 0x3f)
          .toList();
      return List<int>.generate(14, (i) => i < encoded.length ? encoded[i] : 0);
    }
    if (n != null) {
      final bd = ByteData(4)..setFloat32(0, n);
      return bd.buffer.asUint8List();
    }
    throw FormatException('The value cannot be encoded as $dpt.');
  }

  Object _decode(String dpt, List<int> raw, int bitValue) {
    if (dpt.startsWith('1.')) return bitValue == 1;
    if (dpt == '5.001') return raw.isEmpty ? 0 : raw.last * 100 / 255;
    if (dpt == '5.003') return raw.isEmpty ? 0 : raw.last * 360 / 255;
    if (dpt.startsWith('5.') || dpt.startsWith('20.')) {
      return raw.isEmpty ? 0 : raw.last;
    }
    if (dpt == '9.001' && raw.length >= 2) {
      final word = (raw[0] << 8) | raw[1];
      final sign = (word & 0x8000) != 0;
      final exp = (word >> 11) & 15;
      var mantissa = word & 0x7ff;
      if (sign) mantissa -= 2048;
      return mantissa * 0.01 * pow(2, exp);
    }
    if (dpt.startsWith('16.')) {
      return latin1.decode(raw.takeWhile((v) => v != 0).toList());
    }
    if (raw.length >= 4) {
      return ByteData.sublistView(Uint8List.fromList(raw)).getFloat32(0);
    }
    if (raw.length >= 2) return (raw[0] << 8) | raw[1];
    return raw.isEmpty ? 0 : raw[0];
  }

  void _receive(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) return;
    Datagram? datagram;
    while ((datagram = _socket!.receive()) != null) {
      final packet = datagram!;
      final bytes = packet.data;
      if (bytes.length >= 20 && _service(bytes) == 0x0206) {
        final response = _connectResponse;
        if (response == null || response.isCompleted) continue;
        if (bytes[7] != 0) {
          response.completeError(
            StateError('KNX connection rejected (status ${bytes[7]}).'),
          );
        } else {
          _channel = bytes[6];
          _individualAddress = (bytes[18] << 8) | bytes[19];
          final endpointAddress = bytes.sublist(10, 14);
          _dataEndpoint = endpointAddress.every((part) => part == 0)
              ? packet.address
              : InternetAddress.fromRawAddress(endpointAddress);
          _dataPort = (bytes[14] << 8) | bytes[15];
          if (_dataPort == 0) _dataPort = packet.port;
          _sequence = 0;
          _connected = true;
          response.complete();
        }
      } else {
        _handle(bytes, peer: packet.address, peerPort: packet.port);
      }
    }
  }

  void _handle(List<int> bytes, {InternetAddress? peer, int? peerPort}) {
    if (bytes.length < 8 || bytes[0] != 6) return;
    final service = _service(bytes);
    if (service == 0x0208) {
      if (bytes[6] == _channel && bytes[7] == 0) {
        _lastHeartbeatResponse = DateTime.now();
      } else if (bytes[6] == _channel) {
        _markDisconnected();
      }
      return;
    }
    if (service == 0x0209) {
      try {
        final endpoint = peer ?? _gateway;
        if (_socket != null && endpoint != null) {
          _socket!.send(
            _packet(0x020a, [_channel, 0]),
            endpoint,
            peerPort ?? _port,
          );
        }
      } on SocketException {
        // The peer may already have closed its endpoint; local cleanup still
        // needs to run so the app can reconnect cleanly.
      } finally {
        _markDisconnected();
      }
      return;
    }
    if (service != 0x0420 || bytes.length < 20) return;
    final channel = bytes[7], seq = bytes[8];
    final ackAddress = peer ?? _dataEndpoint;
    if (channel == _channel && _socket != null && ackAddress != null) {
      // Acknowledge receipt of this KNXnet/IP tunnel packet separately from
      // any group-level response carried inside its cEMI frame.
      _socket?.send(
        _packet(0x0421, [4, channel, seq, 0]),
        ackAddress,
        peerPort ?? _dataPort,
      );
    }
    final start = 10;
    if (bytes.length < start + 9) return;
    final cemi = bytes.sublist(start);
    final fields = 2 + cemi[1];
    if (cemi.length < fields + 7) return;
    final src = _individual((cemi[fields + 2] << 8) | cemi[fields + 3]);
    final destValue = (cemi[fields + 4] << 8) | cemi[fields + 5];
    final dest =
        '${(destValue >> 11) & 31}/${(destValue >> 8) & 7}/${destValue & 255}';
    final len = cemi[fields + 6];
    final apduStart = fields + 7;
    if (cemi.length < apduStart + len + 1) return;
    final apdu = cemi.sublist(apduStart, apduStart + len + 1);
    if (apdu.length < 2) return;
    final apci = ((apdu[0] & 3) << 2) | ((apdu[1] >> 6) & 3);
    final type = switch (apci) {
      0 => 'read',
      1 => 'response',
      2 => 'write',
      _ => 'other',
    };
    if (type == 'other') return;
    final inline = apdu[1] & 0x3f;
    final raw = apdu.length > 2 ? apdu.sublist(2) : <int>[];
    final requested = _reads[dest];
    Object? value;
    if (type != 'read') {
      final selectedDpt = _pendingDpt[dest] ?? _knownDpt[dest] ?? '1.001';
      value = _decode(selectedDpt, raw, inline);
      onValue?.call(dest, value);
      if (requested != null && !requested.isCompleted) {
        requested.complete(value);
      }
      _reads.remove(dest);
      final monitorBytes = raw.isEmpty ? [inline] : raw;
      _record(
        'rx',
        src,
        dest,
        type,
        dpt: selectedDpt,
        value:
            '0x${monitorBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
      );
    } else {
      _record('rx', src, dest, type);
    }
  }

  final Map<String, String> _pendingDpt = {}, _knownDpt = {};
  String _individual(int address) =>
      '${(address >> 12) & 15}.${(address >> 8) & 15}.${address & 255}';
  void rememberDpt(String address, String dpt) {
    _knownDpt[address] = dpt;
  }

  void _record(
    String direction,
    String source,
    String destination,
    String type, {
    String? dpt,
    String? value,
  }) {
    if (monitorPaused) return;
    history.insert(
      0,
      KnxTelegram(
        _nextId++,
        DateTime.now(),
        direction,
        source,
        destination,
        type,
        dpt: dpt,
        value: value,
      ),
    );
    if (history.length > 500) history.removeLast();
    onChange?.call();
  }
}
