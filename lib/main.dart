import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'knx_client.dart';
import 'models.dart';

const ink = Color(0xff202a25),
    dark = Color(0xff202f28),
    lime = Color(0xffd8ef94),
    paper = Color(0xfff4f5f0),
    muted = Color(0xff7b847e),
    line = Color(0xffe3e6e0),
    blue = Color(0xff3588c7),
    orange = Color(0xffdf6338);

const _localNetworkChannel = MethodChannel(
  'com.juanelas.knx_home/local_network',
);

String _decodeConfigBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    return utf8.decode(bytes.sublist(3));
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Invalid UTF-16 YAML file.');
    }
    final littleEndian = bytes[0] == 0xff;
    return String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Accept legacy Windows-1252 YAML exports from desktop editors.
    const windows1252 = <int, int>{
      0x80: 0x20ac,
      0x82: 0x201a,
      0x83: 0x0192,
      0x84: 0x201e,
      0x85: 0x2026,
      0x86: 0x2020,
      0x87: 0x2021,
      0x88: 0x02c6,
      0x89: 0x2030,
      0x8a: 0x0160,
      0x8b: 0x2039,
      0x8c: 0x0152,
      0x8e: 0x017d,
      0x91: 0x2018,
      0x92: 0x2019,
      0x93: 0x201c,
      0x94: 0x201d,
      0x95: 0x2022,
      0x96: 0x2013,
      0x97: 0x2014,
      0x98: 0x02dc,
      0x99: 0x2122,
      0x9a: 0x0161,
      0x9b: 0x203a,
      0x9c: 0x0153,
      0x9e: 0x017e,
      0x9f: 0x0178,
    };
    return String.fromCharCodes(bytes.map((byte) => windows1252[byte] ?? byte));
  }
}

String _repairStoredMojibake(String text) {
  if (!text.contains('Ã') && !text.contains('Â')) return text;
  final runes = text.runes.toList();
  if (runes.any((rune) => rune > 0xff)) return text;
  try {
    final repaired = utf8.decode(latin1.encode(text));
    return repaired.contains('\uFFFD') ? text : repaired;
  } on FormatException {
    return text;
  }
}

void main() => runApp(const KnxHomeApp());

class KnxHomeApp extends StatelessWidget {
  const KnxHomeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'KNX home',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: dark,
        primary: dark,
        surface: paper,
      ),
      fontFamily: 'Arial',
    ),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final client = KnxClient();
  List<KnxEntity> entities = [];
  final Map<String, Object> values = {};
  final host = TextEditingController(),
      port = TextEditingController(text: '3671'),
      search = TextEditingController(),
      monitorAddress = TextEditingController(),
      monitorDpt = TextEditingController(text: '1.001'),
      monitorValue = TextEditingController();
  String configText = '',
      category = 'All',
      roomFilter = 'All rooms',
      query = '',
      filter = '';
  int page = 0;
  bool ready = false,
      busy = false,
      manuallyDisconnected = false,
      reconnecting = false,
      paused = false,
      readableExpanded = false,
      gatewayConfigured = false;
  final selectedDpt = <int, String>{};
  OverlayEntry? noticeEntry;
  Timer? noticeTimer;
  double noticeOpacity = 1;
  String? movementEntity;
  double movementStart = 0, movementTarget = 0;
  DateTime? movementAt;
  Timer? coverTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client.onValue = _onValue;
    client.onChange = () {
      if (mounted) setState(() {});
    };
    client.onConnection = () {
      if (mounted) setState(() {});
      if (!client.connected) unawaited(_recoverConnection());
    };
    host.addListener(_onGatewayInputChanged);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    coverTimer?.cancel();
    noticeTimer?.cancel();
    noticeEntry?.remove();
    client.disconnect();
    host.removeListener(_onGatewayInputChanged);
    host.dispose();
    port.dispose();
    search.dispose();
    monitorAddress.dispose();
    monitorDpt.dispose();
    monitorValue.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        !gatewayConfigured ||
        entities.isEmpty ||
        manuallyDisconnected) {
      return;
    }
    if (client.connected) {
      unawaited(_refreshAll());
    } else if (!busy && !reconnecting) {
      unawaited(_recoverConnection());
    }
  }

  Future<void> _recoverConnection() async {
    if (reconnecting ||
        manuallyDisconnected ||
        !gatewayConfigured ||
        entities.isEmpty) {
      return;
    }
    reconnecting = true;
    try {
      for (final delay in const [
        Duration.zero,
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (!mounted ||
            client.connected ||
            manuallyDisconnected ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        try {
          await _connect(silent: true);
          if (client.connected) return;
        } catch (_) {}
      }
    } finally {
      reconnecting = false;
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    configText = _repairStoredMojibake(p.getString('knx-config-yaml') ?? '');
    host.text = p.getString('knx-host') ?? '';
    gatewayConfigured = host.text.trim().isNotEmpty;
    port.text = p.getString('knx-port') ?? '3671';
    if (configText.isNotEmpty) {
      try {
        entities = parseEntities(configText);
        await p.setString('knx-config-yaml', configText);
      } catch (_) {
        configText = '';
      }
    }
    setState(() => ready = true);
    if (entities.isNotEmpty && host.text.trim().isNotEmpty) {
      try {
        await _connect(silent: true);
      } catch (_) {}
    }
  }

  void _onGatewayInputChanged() {
    if (mounted) setState(() {});
  }

  void _onValue(String address, Object value) {
    if (!mounted) return;
    setState(() {
      for (final e in entities) {
        for (final s in e.states.where((s) => s.address == address)) {
          if (e.kind == EntityKind.cover &&
              s.role == StateRole.position &&
              movementEntity == e.id &&
              movementAt != null) {
            continue;
          }
          // A manual Bus Monitor read can use a different DPT from the one
          // configured for this entity. Do not let a decoded bit value replace
          // a numeric position (or vice versa).
          if (s.dpt.startsWith('1.') != (value is bool)) continue;
          values[s.id] = _logical(e, s, value);
        }
      }
    });
  }

  Object _logical(KnxEntity e, EntityState s, Object raw) {
    if (s.role == StateRole.mode) {
      final n = raw is num ? raw.toInt() : int.tryParse('$raw');
      return ({
            0: 'auto',
            1: 'heat',
            2: 'heat',
            3: 'cool',
            4: 'cool',
            5: 'cool',
            6: 'off',
            8: 'heat',
            9: 'fan',
            10: 'cool',
            11: 'cool',
            12: 'heat',
            13: 'economic',
            14: 'cool',
            16: 'cool',
            17: 'heat',
          })[n] ??
          '$raw';
    }
    if (s.role == StateRole.heatCool) {
      return raw == true || raw == 1 || raw == '1' ? 'heat' : 'cool';
    }
    if (s.role == StateRole.direction) {
      final n = raw is num ? raw.round() : int.tryParse('$raw');
      final winter = e.directionValues['winter'] ?? 0,
          summer = e.directionValues['summer'] ?? 255;
      return n == winter ||
              (s.dpt == '5.001' && n == (winter * 100 / 255).round())
          ? 'winter'
          : n == summer ||
                (s.dpt == '5.001' && n == (summer * 100 / 255).round())
          ? 'summer'
          : '$raw';
    }
    if (s.role == StateRole.option) return raw;
    if (s.invert && raw is num) return 100 - raw;
    if (s.invert && raw is bool) return !raw;
    return raw;
  }

  double _numericValue(Object? value, {double fallback = 0}) =>
      value is num ? value.toDouble() : fallback;

  bool _isOn(KnxEntity e) {
    final p = e.state(StateRole.power);
    final speed = e.state(StateRole.speed);
    final v = values[p?.id ?? speed?.id];
    return v == true || (v is num && v > 0);
  }

  Future<void> _connect({bool silent = false}) async {
    if (busy) return;
    manuallyDisconnected = false;
    setState(() => busy = true);
    try {
      if (Platform.isAndroid) {
        final allowed =
            await _localNetworkChannel.invokeMethod<bool>('requestAccess') ??
            false;
        if (!allowed) {
          throw StateError(
            'Local network access is required to connect to the KNX gateway.',
          );
        }
      }
      await client.connect(host.text.trim(), int.tryParse(port.text) ?? 3671);
      final p = await SharedPreferences.getInstance();
      await p.setString('knx-host', host.text.trim());
      await p.setString('knx-port', port.text);
      gatewayConfigured = true;
      for (final e in entities) {
        for (final s in e.states) {
          if (s.assumed) {
            values.putIfAbsent(
              s.id,
              () => _logical(
                e,
                s,
                s.dpt.startsWith('1.') ? s.invert : (s.invert ? 100 : 0),
              ),
            );
          }
        }
      }
      unawaited(_refreshAll());
      if (!silent) _notice('Connected to KNX gateway.');
    } catch (e) {
      if (!silent) _notice('$e', error: true);
      rethrow;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _disconnect() async {
    manuallyDisconnected = true;
    await client.disconnect();
    _notice('Gateway disconnected.');
  }

  Future<void> _importConfig() async {
    final result = await FilePicker.pickFile(
      // Some Android document providers report YAML files as plain text, so
      // extension filtering can make valid .yaml/.yml files unselectable.
      type: FileType.any,
    );
    if (result == null) return;
    try {
      final fileName = result.name.toLowerCase();
      if (!fileName.endsWith('.yaml') && !fileName.endsWith('.yml')) {
        throw const FormatException('Choose a .yaml or .yml file.');
      }
      final text = _repairStoredMojibake(
        _decodeConfigBytes(await result.readAsBytes()),
      );
      final parsed = parseEntities(text);
      final p = await SharedPreferences.getInstance();
      await p.setString('knx-config-yaml', text);
      setState(() {
        configText = text;
        entities = parsed;
        values.clear();
        page = 0;
        category = 'All';
        roomFilter = 'All rooms';
        query = '';
        search.clear();
      });
      if (client.connected) {
        unawaited(_refreshAll());
      }
      _notice('Configuration imported and saved on this device.');
    } catch (e) {
      _notice('Could not import configuration: $e', error: true);
    }
  }

  void _notice(String text, {bool error = false}) {
    if (!mounted) return;
    noticeTimer?.cancel();
    noticeEntry?.remove();
    noticeOpacity = 1;
    noticeEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 12,
        left: 12,
        right: 12,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: noticeOpacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 560),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: error
                      ? const Color(0xfffff2ed)
                      : const Color(0xfff2f8e9),
                  border: Border.all(
                    color: error
                        ? const Color(0xffeac4b8)
                        : const Color(0xffcde1bd),
                  ),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x29242b26),
                      blurRadius: 22,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      error ? Icons.error_outline : Icons.check_circle_outline,
                      size: 17,
                      color: error
                          ? const Color(0xff9b4b35)
                          : const Color(0xff4c682f),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: 12,
                          color: error
                              ? const Color(0xff9b4b35)
                              : const Color(0xff4c682f),
                        ),
                      ),
                    ),
                    if (error)
                      IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: _dismissNotice,
                        icon: const Icon(Icons.close, size: 16),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(noticeEntry!);
    if (!error) {
      noticeTimer = Timer(const Duration(milliseconds: 1600), () {
        noticeOpacity = 0;
        noticeEntry?.markNeedsBuild();
        noticeTimer = Timer(const Duration(milliseconds: 400), _dismissNotice);
      });
    }
  }

  void _dismissNotice() {
    noticeTimer?.cancel();
    noticeEntry?.remove();
    noticeEntry = null;
  }

  Future<void> _read(EntityState s) async {
    if (!client.connected || s.assumed) return;
    try {
      // KnxClient delivers the decoded response through onValue before the
      // read future completes. Applying it again would invert positions twice.
      await _readAddressWithRetry(s.address, s.dpt);
    } catch (e) {
      _notice('$e', error: true);
    }
  }

  Future<Object> _readAddressWithRetry(String address, String dpt) async {
    Object? lastError;
    for (var retry = 0; retry <= 3; retry++) {
      if (!client.connected) {
        throw StateError('Disconnected from KNX gateway.');
      }
      try {
        return await client.read(address, dpt);
      } catch (error) {
        lastError = error;
        if (retry == 3 || !client.connected) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw lastError ?? StateError('Could not read KNX state.');
  }

  Future<void> _readEntity(KnxEntity e) async {
    await _readStatesInParallel(e.states);
  }

  void _showEntityAddresses(KnxEntity e) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (e.states.isNotEmpty) ...[
                  const Text(
                    'State addresses',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  ...e.states.map(
                    (state) => _addressRow(
                      state.label,
                      state.address,
                      state.dpt,
                      currentValue: _display(state),
                    ),
                  ),
                ],
                if (e.commands.isNotEmpty) ...[
                  if (e.states.isNotEmpty) const SizedBox(height: 12),
                  const Text(
                    'Command addresses',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  ...e.commands.entries.map(
                    (command) => _addressRow(
                      command.key.name.replaceAllMapped(
                        RegExp(r'[A-Z]'),
                        (match) => ' ${match[0]!.toLowerCase()}',
                      ),
                      command.value.address,
                      command.value.dpt,
                    ),
                  ),
                ],
                if (e.states.isEmpty && e.commands.isEmpty)
                  const Text('No group addresses configured.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _addressRow(
    String label,
    String address,
    String dpt, {
    String? currentValue,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ),
            Text(dpt, style: const TextStyle(fontSize: 10, color: muted)),
          ],
        ),
        Text(
          address,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
        if (currentValue != null)
          Text(
            'Current: $currentValue',
            style: const TextStyle(fontSize: 10, color: muted),
          ),
      ],
    ),
  );

  Future<void> _refreshAll() async {
    await _readStatesInParallel(
      entities.expand((entity) => entity.states),
      quiet: true,
    );
  }

  Future<void> _readStatesInParallel(
    Iterable<EntityState> states, {
    bool quiet = false,
  }) async {
    final statesByAddress = <String, EntityState>{};
    for (final state in states) {
      if (!state.assumed) {
        statesByAddress.putIfAbsent(state.address, () => state);
      }
    }
    final uniqueStates = statesByAddress.values.toList();
    for (final state in uniqueStates) {
      client.rememberDpt(state.address, state.dpt);
    }
    var nextIndex = 0;
    Future<void> worker() async {
      while (client.connected) {
        final index = nextIndex++;
        if (index >= uniqueStates.length) return;
        final state = uniqueStates[index];
        if (quiet) {
          await _readQuietly(state);
        } else {
          await _read(state);
        }
      }
    }

    final workerCount = math.min(4, uniqueStates.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<void> _readQuietly(EntityState state) async {
    try {
      await _readAddressWithRetry(state.address, state.dpt);
    } catch (_) {
      // Background refreshes retry silently so a batch cannot flood notices.
    }
  }

  void _scheduleStateRefresh(KnxEntity entity) {
    for (final delay in const [1, 3, 6]) {
      Future<void>.delayed(Duration(seconds: delay), () {
        if (!client.connected) return;
        unawaited(_readStatesInParallel(entity.states, quiet: true));
      });
    }
  }

  Future<void> _write(KnxEntity e, CommandRole role, Object input) async {
    final point = e.commands[role];
    if (point == null || !client.connected) return;
    Object value = input;
    if (role == CommandRole.heatCool) value = input == 'heat';
    if (role == CommandRole.mode) {
      value = input == 'auto'
          ? 0
          : input == 'heat'
          ? 1
          : 3;
    }
    if (role == CommandRole.direction) value = e.directionValues[input] ?? 0;
    if (role == CommandRole.move) value = input == 'open' ? 0 : 1;
    if (role == CommandRole.stop) value = false;
    if (point.invert && role != CommandRole.move) {
      if (role == CommandRole.power) {
        value = !(value == true);
      } else if (value is num) {
        value = 100 - value;
      }
    }
    try {
      await client.write(point.address, point.dpt, value);
      final state = e.state(
        role == CommandRole.heatCool
            ? StateRole.heatCool
            : role == CommandRole.direction
            ? StateRole.direction
            : role == CommandRole.speed
            ? StateRole.speed
            : role == CommandRole.target
            ? StateRole.target
            : role == CommandRole.position
            ? StateRole.position
            : role == CommandRole.power
            ? StateRole.power
            : StateRole.mode,
      );
      if (state != null && state.assumed) {
        final shown = _logical(e, state, value);
        setState(() => values[state.id] = shown);
      }
      if (role == CommandRole.power && state != null) {
        setState(() => values[state.id] = input == true);
      }
      if (e.kind == EntityKind.cover &&
          (role == CommandRole.position || role == CommandRole.move)) {
        _startCover(
          e,
          role == CommandRole.position
              ? (input as num).toDouble()
              : input == 'open'
              ? 100
              : 0,
          unknownStart: input == 'open' ? 0 : 100,
        );
      }
      if (!(e.kind == EntityKind.cover &&
          (role == CommandRole.position || role == CommandRole.move))) {
        _scheduleStateRefresh(e);
      }
    } catch (err) {
      _notice('$err', error: true);
    }
  }

  void _startCover(KnxEntity e, double target, {double unknownStart = 0}) {
    final s = e.state(StateRole.position);
    if (s == null) return;
    final start = (values[s.id] as num?)?.toDouble() ?? unknownStart;
    coverTimer?.cancel();
    setState(() {
      movementEntity = e.id;
      movementStart = start;
      movementTarget = target.clamp(0, 100).toDouble();
      movementAt = DateTime.now();
    });
    coverTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || movementAt == null) return;
      final up = movementTarget > movementStart;
      final seconds = up ? e.travellingTimeUp : e.travellingTimeDown;
      if (seconds == null || seconds <= 0) {
        coverTimer?.cancel();
        return;
      }
      final duration = seconds * (movementTarget - movementStart).abs() / 100;
      final progress = math.min(
        1,
        DateTime.now().difference(movementAt!).inMilliseconds /
            (duration * 1000),
      );
      final raw = movementStart + (movementTarget - movementStart) * progress;
      setState(() {
        values[s.id] = raw;
        if (progress >= 1) {
          coverTimer?.cancel();
          movementEntity = null;
          movementAt = null;
        }
      });
      if (progress >= 1) _scheduleStateRefresh(e);
    });
  }

  Future<void> _stopCover(KnxEntity e) async {
    if (movementEntity != e.id || movementAt == null) return;
    final movingUp = movementTarget > movementStart;
    final stop = e.commands[CommandRole.stop];
    final move = e.commands[CommandRole.move];
    coverTimer?.cancel();
    setState(() {
      movementEntity = null;
      movementAt = null;
    });
    try {
      if (stop != null) {
        await client.write(stop.address, stop.dpt, false);
      } else if (move != null) {
        // Repeating the active direction acts as the stop request on setups
        // that expose only a move group address.
        await client.write(move.address, move.dpt, movingUp ? 0 : 1);
      }
      _scheduleStateRefresh(e);
    } catch (err) {
      _notice('$err', error: true);
    }
  }

  List<String> get categories {
    final names = [
      'All',
      'Plugs',
      'Lighting',
      'Fans',
      'Extractors',
      'Covers',
      'Climate',
      'Selectors',
    ];
    return names
        .where((c) => c == 'All' || entities.any((e) => _label(e.kind) == c))
        .toList();
  }

  String _label(EntityKind k) => switch (k) {
    EntityKind.plug => 'Plugs',
    EntityKind.light => 'Lighting',
    EntityKind.fan => 'Fans',
    EntityKind.extractor => 'Extractors',
    EntityKind.cover => 'Covers',
    EntityKind.climate => 'Climate',
    EntityKind.select => 'Selectors',
  };
  List<KnxEntity> get filtered => entities
      .where(
        (e) =>
            (page == 1 || category == 'All' || _label(e.kind) == category) &&
            (roomFilter == 'All rooms' || roomFilter == e.room) &&
            (page == 1 ||
                '${e.name} ${e.room} ${e.states.map((s) => s.address).join(' ')}'
                    .toLowerCase()
                    .contains(query.toLowerCase())),
      )
      .toList();
  String _display(EntityState s) {
    final v = values[s.id];
    if (v == null) return 'Not read';
    if (s.role == StateRole.power) return v == true ? 'On' : 'Off';
    if (s.role == StateRole.temperature || s.role == StateRole.target) {
      return '${(v as num).toStringAsFixed(1)} °C';
    }
    if (s.role == StateRole.position ||
        s.role == StateRole.speed ||
        s.role == StateRole.brightness) {
      return '${(v as num).round()}%';
    }
    if (s.role == StateRole.heatCool) {
      return v == 'heat' ? 'Heating' : 'Cooling';
    }
    if (s.role == StateRole.direction) {
      return v == 'winter' ? 'Winter' : 'Summer';
    }
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (configText.isEmpty || entities.isEmpty || !gatewayConfigured) {
      return _welcome();
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: Row(
        children: [
          if (wide) _sidebar(),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _pageContent()),
                if (!wide) _bottomNav(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _welcome() {
    final hasConfig = configText.isNotEmpty && entities.isNotEmpty;
    final hasGateway = host.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.all(28),
              decoration: _box(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: lime,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'K',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.bold,
                          color: dark,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Center(
                    child: Text(
                      'KNX home',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  const Center(
                    child: Text(
                      'Welcome home.',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Complete both steps to bring your rooms and devices into view.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  _setupStep(
                    number: '1',
                    title: 'Rooms configuration',
                    complete: hasConfig,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _importConfig,
                    icon: const Icon(Icons.upload_file),
                    label: Text(
                      hasConfig
                          ? 'Update configuration'
                          : 'Import configuration',
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 7),
                    child: Text(
                      'Choose a .yaml or .yml file',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Divider(height: 1),
                  ),
                  _setupStep(
                    number: '2',
                    title: 'KNX gateway connection',
                    complete: gatewayConfigured || client.connected,
                  ),
                  const SizedBox(height: 12),
                  _field('Gateway address', host, '192.168.1.100'),
                  const SizedBox(height: 12),
                  _field(
                    'UDP port',
                    port,
                    '3671',
                    keyboard: TextInputType.number,
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 42,
                    child: FilledButton.icon(
                      onPressed: busy || client.connected || !hasGateway
                          ? null
                          : () => _connect(),
                      icon: Icon(
                        busy
                            ? Icons.hourglass_top
                            : client.connected
                            ? Icons.check_circle_outline
                            : Icons.wifi,
                        size: 17,
                      ),
                      label: Text(
                        busy
                            ? 'Connecting…'
                            : client.connected
                            ? 'Gateway connected'
                            : 'Connect gateway',
                      ),
                    ),
                  ),
                  if (hasGateway && !client.connected)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        gatewayConfigured
                            ? 'Gateway is offline. Reconnect to continue.'
                            : 'Enter the gateway address and connect to continue.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: muted),
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

  Widget _setupStep({
    required String number,
    required String title,
    required bool complete,
  }) => Row(
    children: [
      Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: complete ? lime : paper,
          shape: BoxShape.circle,
        ),
        child: complete
            ? const Icon(Icons.check, size: 15, color: dark)
            : Text(number, style: const TextStyle(fontSize: 12, color: muted)),
      ),
      const SizedBox(width: 9),
      Expanded(
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Text(
        complete ? 'Ready' : 'Required',
        style: TextStyle(
          fontSize: 11,
          color: complete ? dark : muted,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
  BoxDecoration _box() => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: line),
  );

  void _goPage(int index) {
    setState(() {
      page = index;
      if (index != 2) {
        category = 'All';
        roomFilter = 'All rooms';
        query = '';
        search.clear();
      }
    });
  }

  Widget _sidebar() => Container(
    width: 210,
    color: dark,
    padding: const EdgeInsets.fromLTRB(15, 22, 15, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _goPage(0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 0, 5, 38),
            child: Row(
              children: [
                Container(
                  width: 37,
                  height: 37,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: lime,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Text(
                    'K',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 21,
                      color: dark,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'KNX home',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'by Juanelas',
                      style: TextStyle(color: Color(0xffa5b0a9), fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 11, bottom: 12),
          child: Text(
            'WORKSPACE',
            style: TextStyle(
              color: Color(0xff84928a),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        _navButton(0, 'Functions', Icons.grid_view_rounded),
        _navButton(1, 'Rooms', Icons.door_front_door_outlined),
        _navButton(2, 'Settings', Icons.tune),
      ],
    ),
  );
  Widget _navButton(int index, String label, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => _goPage(index),
      child: Container(
        height: 39,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: page == index ? lime : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: page == index ? dark : const Color(0xffacb8b0),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: page == index ? dark : const Color(0xffacb8b0),
                fontWeight: page == index ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _bottomNav() => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: line)),
    ),
    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
    child: Row(
      children:
          [
                (0, 'Functions', Icons.grid_view_rounded),
                (1, 'Rooms', Icons.door_front_door_outlined),
                (2, 'Settings', Icons.tune),
              ]
              .map(
                (e) => Expanded(
                  child: InkWell(
                    onTap: () => _goPage(e.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            e.$3,
                            color: page == e.$1 ? dark : muted,
                            size: 20,
                          ),
                          Text(
                            e.$2,
                            style: TextStyle(
                              fontSize: 10,
                              color: page == e.$1 ? dark : muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
    ),
  );
  Widget _pageContent() {
    final title = ['Functions', 'Rooms', 'Settings'][page];
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(26, 25, 26, 35),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'KNX HOME',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1.1,
                                      color: muted,
                                    ),
                                  ),
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    page == 2
                                        ? 'Manage the connection, configuration and bus monitor.'
                                        : 'Browse and control your configured devices.',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (page != 2)
                              TextButton.icon(
                                onPressed: client.connected ? _refresh : null,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('Refresh'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (page == 2) _settings() else ..._listing(),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _refresh() async {
    await _readStatesInParallel(filtered.expand((entity) => entity.states));
  }

  List<Widget> _listing() {
    final list = <Widget>[if (page == 0) _searchFilter() else _roomFilter()];
    list.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${filtered.length} entities',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            const Text(
              'CONFIGURED KNX DEVICES',
              style: TextStyle(fontSize: 9, color: muted, letterSpacing: 1),
            ),
          ],
        ),
      ),
    );
    if (page == 0) {
      if (category == 'All') {
        for (final name in categories.where((name) => name != 'All')) {
          final group = filtered
              .where((entity) => _label(entity.kind) == name)
              .toList();
          if (group.isEmpty) continue;
          list.add(_groupHeading(name, group.length));
          list.add(_grid(group));
        }
      } else {
        list.add(_grid(filtered));
      }
    } else {
      final roomNames = filtered.map((e) => e.room).toSet();
      for (final name in roomNames) {
        final group = filtered.where((e) => e.room == name).toList();
        list.add(_groupHeading(name, group.length));
        list.add(_grid(group));
      }
    }
    return list;
  }

  Widget _groupHeading(String name, int count) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          '${count.toString().padLeft(2, '0')} ENTITIES',
          style: const TextStyle(fontSize: 9, color: muted, letterSpacing: 1),
        ),
      ],
    ),
  );

  Widget _searchFilter() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: search,
        onChanged: (v) => setState(() => query = v),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, size: 17),
          hintText: 'Search functions',
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: BorderSide(color: line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: BorderSide(color: line),
          ),
        ),
      ),
      const SizedBox(height: 10),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: categories
              .map(
                (c) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(c),
                    selected: category == c,
                    onSelected: (_) => setState(() => category = c),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    ],
  );
  Widget _roomFilter() {
    final rooms = ['All rooms', ...entities.map((e) => e.room).toSet()];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: rooms
              .map(
                (r) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(r),
                    selected: roomFilter == r,
                    onSelected: (_) => setState(() => roomFilter = r),
                    visualDensity: VisualDensity.compact,
                    showCheckmark: false,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _grid(List<KnxEntity> list) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final count = math.max(
          1,
          math.min(
            ((availableWidth + 9) / 210).floor(),
            ((availableWidth + 9) / 340).ceil(),
          ),
        );
        final cardWidth = (availableWidth - (count - 1) * 9) / count;
        return Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            for (final entity in list)
              Builder(
                builder: (context) {
                  final titlePainter = TextPainter(
                    text: TextSpan(
                      text: entity.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                  )..layout(maxWidth: math.max(1.0, cardWidth - 92));
                  final titleLines = titlePainter.computeLineMetrics().length;
                  final compact =
                      entity.kind == EntityKind.plug ||
                      entity.kind == EntityKind.light ||
                      entity.kind == EntityKind.extractor;
                  return SizedBox(
                    width: cardWidth,
                    height: compact
                        ? (128 + math.max(0, titleLines - 2) * 19).toDouble()
                        : (306 + math.max(0, titleLines - 1) * 19).toDouble(),
                    child: _entityCard(entity),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  IconData _icon(KnxEntity e) => switch (e.kind) {
    EntityKind.plug => Icons.power,
    EntityKind.light => Icons.lightbulb_outline,
    EntityKind.fan => Icons.mode_fan_off,
    EntityKind.extractor => Icons.air,
    EntityKind.cover => Icons.roller_shades,
    EntityKind.climate => Icons.thermostat,
    EntityKind.select => Icons.list_alt,
  };
  Widget _entityCard(KnxEntity e) {
    Object? current(id) => id == null ? null : values[id];
    final temp = e.state(StateRole.temperature),
        target = e.state(StateRole.target),
        speed = e.state(StateRole.speed),
        position = e.state(StateRole.position),
        power = e.state(StateRole.power),
        season = e.state(StateRole.heatCool),
        direction = e.state(StateRole.direction);
    final tempValue = current(temp?.id) as num?,
        targetValue = current(target?.id) as num?;
    final seasonValue =
        current(season?.id) ?? current(e.state(StateRole.mode)?.id);
    final isCooling =
        seasonValue == 'cool' ||
        (seasonValue != 'heat' &&
            tempValue != null &&
            targetValue != null &&
            tempValue > targetValue);
    final winter = current(direction?.id) == 'winter';
    final controlsOpacity = power == null && speed == null
        ? 1.0
        : _isOn(e)
        ? 1.0
        : 0.55;
    final color = e.kind == EntityKind.climate
        ? (isCooling ? blue : orange)
        : e.kind == EntityKind.fan
        ? (winter ? orange : blue)
        : dark;
    final switchable =
        e.kind == EntityKind.plug ||
        e.kind == EntityKind.light ||
        e.kind == EntityKind.extractor ||
        (e.kind == EntityKind.climate &&
            e.commands.containsKey(CommandRole.power));
    final compactEntity =
        e.kind == EntityKind.plug ||
        e.kind == EntityKind.light ||
        e.kind == EntityKind.extractor;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: !client.connected
                    ? null
                    : e.kind == EntityKind.fan &&
                          e.commands.containsKey(CommandRole.speed)
                    ? () => _write(e, CommandRole.speed, _isOn(e) ? 0 : 100)
                    : switchable
                    ? () => _write(e, CommandRole.power, !_isOn(e))
                    : null,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _isOn(e)
                        ? e.kind == EntityKind.climate
                              ? color.withValues(alpha: 0.16)
                              : e.kind == EntityKind.fan
                              ? color.withValues(alpha: 0.16)
                              : lime
                        : const Color(0xfff0f2ee),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: e.kind == EntityKind.fan
                      ? Stack(
                          clipBehavior: Clip.none,
                          children: [
                            FanGlyph(
                              color: _isOn(e)
                                  ? (winter ? orange : blue)
                                  : muted,
                            ),
                            if (winter)
                              const Positioned(
                                right: -6,
                                bottom: -5,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Color(0xfff0f2ee),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(1),
                                    child: Icon(
                                      Icons.sync,
                                      size: 15,
                                      color: orange,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Icon(
                          _icon(e),
                          size: 24,
                          color: _isOn(e)
                              ? e.kind == EntityKind.climate
                                    ? color
                                    : dark
                              : muted,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (e.kind == EntityKind.climate &&
              target != null &&
              e.commands.containsKey(CommandRole.target))
            Opacity(
              opacity: controlsOpacity,
              child: SizedBox(
                height: 174,
                child: Center(
                  child: SizedBox(
                    width: 158,
                    height: 158,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        DialControl(
                          diameter: 158,
                          value: targetValue?.toDouble() ?? (e.minTemp ?? 16),
                          min: e.minTemp ?? 5,
                          max: e.maxTemp ?? 35,
                          step: e.temperatureStep ?? 0.5,
                          arcValue: tempValue?.toDouble(),
                          color: color,
                          label: '${e.name} target temperature',
                          format: (v) => '${v.toStringAsFixed(1)}°',
                          sub: tempValue == null
                              ? null
                              : 'Now ${tempValue.toStringAsFixed(1)} °C',
                          enabled: client.connected,
                          onCommit: (v) => _write(e, CommandRole.target, v),
                        ),
                        Positioned(
                          left: 5,
                          right: 0,
                          // top: 158 - 13 - 35 / 2,
                          top: 120,
                          child: Center(
                            child: HeatCoolSwitch(
                              cooling: seasonValue == 'cool',
                              enabled:
                                  client.connected &&
                                  (e.commands.containsKey(
                                        CommandRole.heatCool,
                                      ) ||
                                      e.commands.containsKey(CommandRole.mode)),
                              onChanged: (cooling) => _write(
                                e,
                                e.commands.containsKey(CommandRole.heatCool)
                                    ? CommandRole.heatCool
                                    : CommandRole.mode,
                                cooling ? 'cool' : 'heat',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (e.kind == EntityKind.fan &&
              speed != null &&
              e.commands.containsKey(CommandRole.speed))
            Opacity(
              opacity: controlsOpacity,
              child: SizedBox(
                height: 168,
                child: Center(
                  child: SizedBox(
                    width: 158,
                    height: 158,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        DialControl(
                          diameter: 158,
                          value: (current(speed.id) as num?)?.toDouble() ?? 0,
                          min: 0,
                          max: 100,
                          step: 1,
                          color: color,
                          label: '${e.name} speed',
                          format: (v) => '${v.round()}%',
                          enabled: client.connected,
                          onCommit: (v) => _write(e, CommandRole.speed, v),
                        ),
                        Positioned(
                          left: 5,
                          right: 0,
                          top: 110,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                'Winter mode',
                                style: TextStyle(fontSize: 10, color: muted),
                              ),
                              SizedBox(
                                width: 55,
                                height: 28,
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: Switch.adaptive(
                                    value: winter,
                                    onChanged: client.connected
                                        ? (_) => _write(
                                            e,
                                            CommandRole.direction,
                                            winter ? 'summer' : 'winter',
                                          )
                                        : null,
                                    activeTrackColor: orange,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (e.kind == EntityKind.cover && position != null)
            Opacity(
              opacity: controlsOpacity,
              child: SizedBox(
                height: 168,
                child: CoverControl(
                  value: _numericValue(current(position.id)),
                  enabled: client.connected,
                  movingDirection: movementEntity == e.id && movementAt != null
                      ? (movementTarget > movementStart ? 1 : -1)
                      : 0,
                  movingTarget: movementTarget,
                  up: () => e.commands.containsKey(CommandRole.move)
                      ? _write(e, CommandRole.move, 'open')
                      : _write(e, CommandRole.position, 100),
                  down: () => e.commands.containsKey(CommandRole.move)
                      ? _write(e, CommandRole.move, 'close')
                      : _write(e, CommandRole.position, 0),
                  stop: () => _stopCover(e),
                  setPosition: (v) =>
                      e.commands.containsKey(CommandRole.position)
                      ? _write(e, CommandRole.position, v)
                      : _write(
                          e,
                          CommandRole.move,
                          v > _numericValue(current(position.id))
                              ? 'open'
                              : 'close',
                        ),
                ),
              ),
            )
          else if (speed != null && e.kind == EntityKind.fan)
            _stateText(speed)
          else if (power != null && !compactEntity)
            Text(
              _display(power),
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w500),
            )
          else if (temp != null)
            Text(
              _display(temp),
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w500),
            )
          else
            const Spacer(),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text(
                  e.room,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              ),
              if (client.connected)
                SizedBox(
                  width: 38,
                  height: 38,
                  child: IconButton(
                    onPressed: () => _readEntity(e),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 20, color: muted),
                  ),
                ),
              SizedBox(
                width: 38,
                height: 38,
                child: IconButton(
                  onPressed: () => _showEntityAddresses(e),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.info_outline, size: 20, color: muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stateText(EntityState s) => Text(
    _display(s),
    style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w500),
  );

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelTitle(
              Icons.wifi,
              'KNXnet/IP gateway',
              'Connect directly to a tunneling interface on your local network.',
            ),
            const SizedBox(height: 15),
            LayoutBuilder(
              builder: (c, con) => Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: con.maxWidth > 500
                        ? con.maxWidth * .65
                        : con.maxWidth,
                    child: _field('Gateway address', host, '192.168.1.100'),
                  ),
                  SizedBox(
                    width: con.maxWidth > 500 ? 130 : con.maxWidth,
                    child: _field(
                      'UDP port',
                      port,
                      '3671',
                      keyboard: TextInputType.number,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 9,
                      color: client.connected ? Colors.green : muted,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      client.connected
                          ? 'Connected · KNXnet/IP'
                          : 'Not connected',
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : client.connected
                      ? _disconnect
                      : () => _connect(),
                  icon: Icon(
                    busy
                        ? Icons.hourglass_top
                        : client.connected
                        ? Icons.wifi_off
                        : Icons.wifi,
                    size: 16,
                  ),
                  label: Text(
                    busy
                        ? 'Connecting…'
                        : client.connected
                        ? 'Disconnect'
                        : 'Connect gateway',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelTitle(
              Icons.verified_user,
              'Configured KNX entities',
              'Loaded from the imported configuration.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 9,
              children: [
                for (final k in EntityKind.values)
                  Text(
                    '${entities.where((e) => e.kind == k).length} ${_label(k).toLowerCase()}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Saved on this device and restored on restart',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _importConfig,
                  icon: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('Update configuration'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      _panel(
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => readableExpanded = !readableExpanded),
              child: Row(
                children: [
                  Expanded(
                    child: _panelTitle(
                      Icons.view_list,
                      'Readable entities',
                      '${entities.length} TOTAL',
                    ),
                  ),
                  Icon(
                    readableExpanded ? Icons.expand_less : Icons.expand_more,
                  ),
                ],
              ),
            ),
            if (readableExpanded) ...entities.map((e) => _entityRow(e)),
          ],
        ),
      ),
      const SizedBox(height: 10),
      _panel(child: _monitor()),
    ],
  );
  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: _box(),
    child: child,
  );
  Widget _panelTitle(IconData icon, String title, String sub) => Row(
    children: [
      Container(
        width: 37,
        height: 37,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xfff0f2ee),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 19, color: dark),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            Text(sub, style: const TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ),
    ],
  );
  Widget _field(
    String label,
    TextEditingController controller,
    String hint, {
    TextInputType? keyboard,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 3),
      TextField(
        controller: controller,
        keyboardType: keyboard,
        maxLines: 1,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xffbcc3bd)),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: line),
          ),
        ),
      ),
    ],
  );
  Widget _entityRow(KnxEntity e) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: e.kind == EntityKind.fan
        ? const FanGlyph(color: muted)
        : Icon(_icon(e), size: 18, color: muted),
    title: Text(e.name, style: const TextStyle(fontSize: 12)),
    subtitle: Text(
      '${e.room} · ${e.states.map((s) => s.address).join(', ')}',
      style: const TextStyle(fontSize: 10, color: muted),
    ),
    trailing: IconButton(
      tooltip: 'Read ${e.name}',
      onPressed: client.connected ? () => _readEntity(e) : null,
      icon: const Icon(Icons.refresh, size: 17),
    ),
  );
  Widget _monitor() {
    final known = <String, String>{};
    for (final e in entities) {
      for (final s in e.states) {
        known[s.address] = '${e.name} · ${s.label}';
      }
      for (final c in e.commands.values) {
        known[c.address] = '${e.name} (cmd)';
      }
    }
    final items = client.history
        .where(
          (t) =>
              filter.isEmpty ||
              '${t.source} ${t.destination} ${t.type} ${t.dpt ?? ''} ${t.value ?? ''} ${known[t.destination] ?? ''}'
                  .toLowerCase()
                  .contains(filter.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _panelTitle(
                Icons.cable,
                'Bus monitor',
                'LIVE TELEGRAMS · ${client.connected ? 'CONNECTED' : 'DISCONNECTED'}',
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                paused = !paused;
                client.monitorPaused = paused;
              }),
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            ),
            IconButton(
              onPressed: () => setState(() => client.history.clear()),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final addressField = SizedBox(
              height: 60,
              child: _field('Group address', monitorAddress, '1/0/1'),
            );
            final dptField = SizedBox(
              height: 60,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Datapoint type',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  const SizedBox(height: 3),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: monitorDpt.text,
                      style: const TextStyle(fontSize: 12, color: ink),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: line),
                        ),
                      ),
                      items:
                          const [
                                '1.001',
                                '1.008',
                                '5.001',
                                '5.003',
                                '5.004',
                                '5.005',
                                '5.010',
                                '7.001',
                                '9.001',
                                '16.000',
                                '20.105',
                              ]
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(
                                    v,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                      onChanged: (v) => monitorDpt.text = v ?? '1.001',
                    ),
                  ),
                ],
              ),
            );
            final valueField = SizedBox(
              height: 60,
              child: _field('Value', monitorValue, '0 / 1 / 21.5'),
            );
            final readButton = SizedBox(
              child: FilledButton(
                onPressed: client.connected
                    ? () async {
                        try {
                          final address = monitorAddress.text.trim();
                          final configuredDpt = entities
                              .expand((entity) => entity.states)
                              .where((state) => state.address == address)
                              .map((state) => state.dpt)
                              .firstOrNull;
                          final v = await _readAddressWithRetry(
                            address,
                            configuredDpt ?? monitorDpt.text,
                          );
                          _notice('$address = $v');
                        } catch (e) {
                          _notice('$e', error: true);
                        }
                      }
                    : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Read', maxLines: 1, softWrap: false),
              ),
            );
            final writeButton = SizedBox(
              child: FilledButton.tonal(
                onPressed: client.connected
                    ? () => client.write(
                        monitorAddress.text.trim(),
                        monitorDpt.text,
                        monitorValue.text.trim(),
                      )
                    : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Write', maxLines: 1, softWrap: false),
              ),
            );

            if (constraints.maxWidth < 420) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  addressField,
                  const SizedBox(height: 10),
                  dptField,
                  const SizedBox(height: 10),
                  valueField,
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: readButton),
                      const SizedBox(width: 10),
                      Expanded(child: writeButton),
                    ],
                  ),
                ],
              );
            }
            if (constraints.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  addressField,
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: dptField),
                      const SizedBox(width: 10),
                      Expanded(child: valueField),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: readButton),
                      const SizedBox(width: 10),
                      Expanded(child: writeButton),
                    ],
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(flex: 3, child: addressField),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: dptField),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: valueField),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(width: 90, child: readButton),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(width: 90, child: writeButton),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        TextField(
          style: const TextStyle(fontSize: 14),
          onChanged: (v) => setState(() => filter = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            prefixIconConstraints: BoxConstraints.tightFor(
              width: 44,
              height: 44,
            ),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            hintText: 'Filter address, type or value',
            hintStyle: TextStyle(fontSize: 14, color: Color(0xffbcc3bd)),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '${items.length} telegrams',
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'No telegrams yet.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        for (final t in items.take(80)) _telegramRow(t, known[t.destination]),
      ],
    );
  }

  Widget _telegramRow(KnxTelegram t, String? name) {
    final id = t.id;
    final bytes = _hexBytes(t.value);
    final candidates = <String>{
      ...entities.expand(
        (e) => [
          ...e.states
              .where((s) => s.address == t.destination)
              .map((s) => s.dpt),
          ...e.commands.values
              .where((p) => p.address == t.destination)
              .map((p) => p.dpt),
        ],
      ),
      ..._dpts.where((d) => _payloadBytes(d) == bytes),
      if (bytes == null) ..._dpts,
    }.where((d) => bytes == null || _payloadBytes(d) == bytes).toList();
    final initial = t.dpt != null && candidates.contains(t.dpt)
        ? t.dpt!
        : (candidates.isNotEmpty ? candidates.first : '');
    final selected = selectedDpt[id] ?? initial;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final time = Text(
            '${t.time.hour.toString().padLeft(2, '0')}:${t.time.minute.toString().padLeft(2, '0')}:${t.time.second.toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 11, color: muted),
          );
          final route = Text(
            '${t.source} → ${t.destination}${name == null ? '' : ' · $name'}',
            maxLines: constraints.maxWidth < 620 ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          );
          final type = Text(
            t.type.toUpperCase(),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          );
          final dptControl = DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isDense: true,
              isExpanded: true,
              value: selected,
              style: const TextStyle(fontSize: 10, color: ink),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('No DPT', style: TextStyle(fontSize: 10)),
                ),
                for (final d in candidates)
                  DropdownMenuItem(
                    value: d,
                    child: Text('DPT $d', style: const TextStyle(fontSize: 10)),
                  ),
              ],
              onChanged: (v) => setState(() => selectedDpt[id] = v ?? ''),
            ),
          );
          final valueText = _formatTelegram(t.value, selected);
          final dptLabel = selected.isEmpty ? 'No DPT' : 'DPT $selected';
          final dptColumnWidth = (dptLabel.length * 6.2 + 26)
              .clamp(76.0, 112.0)
              .toDouble();
          final maxValueWidth = (constraints.maxWidth - 266 - dptColumnWidth)
              .clamp(120.0, 360.0)
              .toDouble();
          final valueColumnWidth = (valueText.length * 7.3 + 12)
              .clamp(120.0, maxValueWidth)
              .toDouble();
          final displayValue = valueText.replaceAllMapped(
            RegExp(r'(\d)\.(\d)'),
            (match) => '${match[1]}.\u2060${match[2]}',
          );
          final formattedValue = Text(
            displayValue,
            maxLines: constraints.maxWidth < 620 ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            textAlign: constraints.maxWidth < 620
                ? TextAlign.end
                : TextAlign.end,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          );

          if (constraints.maxWidth < 620) {
            final mobileDetailsWidth = math.min(
              constraints.maxWidth * .56,
              math.max(dptColumnWidth, valueText.length * 7.3 + 12),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    time,
                    const Spacer(),
                    SizedBox(width: 72, child: type),
                  ],
                ),
                const SizedBox(height: 4),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: route),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: mobileDetailsWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 26,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(
                                  width: dptColumnWidth,
                                  child: dptControl,
                                ),
                              ),
                            ),
                            formattedValue,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return SizedBox(
            height: 36,
            child: Row(
              children: [
                SizedBox(width: 58, child: time),
                const SizedBox(width: 8),
                Expanded(child: route),
                const SizedBox(width: 10),
                SizedBox(width: 68, child: type),
                const SizedBox(width: 8),
                SizedBox(width: dptColumnWidth, child: dptControl),
                const SizedBox(width: 8),
                SizedBox(width: valueColumnWidth, child: formattedValue),
              ],
            ),
          );
        },
      ),
    );
  }

  static const _dpts = [
    '1.001',
    '1.008',
    '1.010',
    '5.001',
    '5.003',
    '5.004',
    '5.005',
    '5.010',
    '7.001',
    '9.001',
    '16.000',
    '20.105',
  ];
  int? _hexBytes(String? value) {
    if (value == null || !value.startsWith('0x')) return null;
    return (value.length - 2) ~/ 2;
  }

  int? _payloadBytes(String d) {
    final main = int.tryParse(d.split('.').first) ?? 0;
    if (main >= 1 && main <= 6) return 1;
    if (main >= 7 && main <= 9) return 2;
    if (main >= 10 && main <= 11) return 3;
    if (main >= 12 && main <= 15) return 4;
    if (main == 16) return 14;
    if (main >= 17 && main <= 20) return 1;
    return null;
  }

  String _formatTelegram(String? raw, String dpt) {
    if (raw == null) return '—';
    if (!raw.startsWith('0x')) {
      final n = double.tryParse(raw);
      return n == null ? raw : '$raw ($n)';
    }
    final bytes = [
      for (var i = 2; i + 1 < raw.length; i += 2)
        int.tryParse(raw.substring(i, i + 2), radix: 16) ?? 0,
    ];
    final integer = bytes.fold<int>(0, (value, byte) => (value << 8) | byte);
    if (dpt == '1.001' && bytes.isNotEmpty) {
      return '$raw (${(bytes.first & 1) == 1 ? 'On' : 'Off'})';
    }
    if (dpt == '1.008' && bytes.isNotEmpty) {
      return '$raw (${(bytes.first & 1) == 1 ? 'Down' : 'Up'})';
    }
    if (dpt == '1.010' && bytes.isNotEmpty) {
      return '$raw (${(bytes.first & 1) == 1 ? 'Start' : 'Stop'})';
    }
    if (dpt == '5.001' && bytes.isNotEmpty) {
      return '$raw (${(bytes.last * 100 / 255).round()}%)';
    }
    if (dpt == '5.003' && bytes.isNotEmpty) {
      return '$raw (${(bytes.last * 360 / 255).round()}°)';
    }
    if (dpt == '5.004' && bytes.isNotEmpty) {
      return '$raw (${bytes.first}%)';
    }
    if (dpt == '5.005' && bytes.isNotEmpty) {
      return '$raw (${bytes.first} ratio)';
    }
    if (dpt == '5.010' && bytes.isNotEmpty) {
      return '$raw (${bytes.first} pulses)';
    }
    if (dpt == '7.001' && bytes.length >= 2) {
      return '$raw ($integer pulses)';
    }
    if (dpt == '9.001' && bytes.length >= 2) {
      final word = (bytes[0] << 8) | bytes[1];
      final sign = (word & 0x8000) != 0;
      final exponent = (word >> 11) & 15;
      var mantissa = word & 0x7ff;
      if (sign) mantissa -= 2048;
      final temperature = mantissa * .01 * math.pow(2, exponent);
      return '$raw (${temperature.toStringAsFixed(2)} ºC)';
    }
    if (dpt == '16.000') {
      return '$raw (${latin1.decode(bytes.takeWhile((b) => b != 0).toList())})';
    }
    if (dpt == '20.105' && bytes.isNotEmpty) {
      const modes = {
        0: 'Auto',
        1: 'Heat',
        2: 'Morning warmup',
        3: 'Cool',
        4: 'Night purge',
        5: 'Precool',
        6: 'Off',
        7: 'Test',
        8: 'Emergency heat',
        9: 'Fan only',
        10: 'Free cool',
        11: 'Ice',
        12: 'Maximum heating',
        13: 'Economic heat/cool',
        14: 'Dehumidification',
        15: 'Calibration',
        16: 'Emergency cool',
        17: 'Emergency steam',
        20: 'No demand',
      };
      return '$raw (${modes[bytes.first] ?? 'Reserved (${bytes.first})'})';
    }
    return '$raw ($integer)';
  }
}

class FanGlyph extends StatelessWidget {
  const FanGlyph({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(27.5),
    painter: _FanGlyphPainter(color),
  );
}

class _FanGlyphPainter extends CustomPainter {
  const _FanGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..color = color;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    for (var blade = 0; blade < 3; blade++) {
      canvas.save();
      canvas.rotate(blade * 2 * math.pi / 3);
      final path = Path()
        ..moveTo(-1.5, -1.5)
        ..cubicTo(-4.5, -4, -4, -8, -1.2, -9)
        ..cubicTo(2, -10, 3.8, -6, 2.2, -3.2)
        ..cubicTo(1.5, -2, 0.5, -1.5, -1.5, -1.5)
        ..close();
      canvas.drawPath(path, paint);
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, 2.2, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FanGlyphPainter old) => old.color != color;
}

class HeatCoolSwitch extends StatelessWidget {
  const HeatCoolSwitch({
    super.key,
    required this.cooling,
    required this.enabled,
    required this.onChanged,
  });

  final bool cooling;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Heating or cooling',
    value: cooling ? 'Cooling' : 'Heating',
    child: Container(
      width: 75,
      height: 35,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xffe9ece7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: line),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: cooling ? Alignment.centerRight : Alignment.centerLeft,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: Container(
              width: 33.75,
              height: 30,
              decoration: BoxDecoration(
                color: cooling ? blue : orange,
                borderRadius: BorderRadius.circular(17.5),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _mode(
                  icon: Icons.local_fire_department,
                  selected: !cooling,
                  onTap: enabled ? () => onChanged(false) : null,
                ),
              ),
              Expanded(
                child: _mode(
                  icon: Icons.ac_unit,
                  selected: cooling,
                  onTap: enabled ? () => onChanged(true) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _mode({
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: Center(
      child: Icon(icon, size: 19, color: selected ? Colors.white : muted),
    ),
  );
}

class _TouchDragSurface extends StatelessWidget {
  const _TouchDragSurface({
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: enabled
        ? {
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (instance) {},
                ),
          }
        : const {},
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled ? (event) => onStart(event.localPosition) : null,
      onPointerMove: enabled ? (event) => onUpdate(event.localPosition) : null,
      onPointerUp: enabled ? (_) => onEnd() : null,
      onPointerCancel: enabled ? (_) => onEnd() : null,
      child: child,
    ),
  );
}

class DialControl extends StatefulWidget {
  const DialControl({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.label,
    required this.format,
    required this.enabled,
    required this.onCommit,
    this.arcValue,
    this.color,
    this.sub,
    this.diameter = 134,
  });
  final double diameter;
  final double value, min, max, step;
  final double? arcValue;
  final Color? color;
  final String label;
  final String Function(double) format;
  final String? sub;
  final bool enabled;
  final ValueChanged<double> onCommit;
  @override
  State<DialControl> createState() => _DialControlState();
}

class _DialControlState extends State<DialControl> {
  late double draft = widget.value;
  bool dragging = false;
  @override
  void didUpdateWidget(covariant DialControl old) {
    super.didUpdateWidget(old);
    if (!dragging) draft = widget.value;
  }

  double _snap(double n) =>
      (widget.min + ((n - widget.min) / widget.step).round() * widget.step)
          .clamp(widget.min, widget.max);
  void _move(Offset p, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final deg =
        (math.atan2(p.dy - c.dy, p.dx - c.dx) * 180 / math.pi + 360) % 360;
    double a = (deg - 135 + 360) % 360;
    if (a > 270) a = a > 315 ? 0 : 270;
    setState(
      () => draft = _snap(widget.min + a / 270 * (widget.max - widget.min)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = ((draft - widget.min) / (widget.max - widget.min)).clamp(
      0.0,
      1.0,
    );
    final af =
        (((widget.arcValue ?? draft) - widget.min) / (widget.max - widget.min))
            .clamp(0.0, 1.0);
    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: _TouchDragSurface(
        enabled: widget.enabled,
        onStart: (position) {
          dragging = true;
          _move(position, Size(widget.diameter, widget.diameter));
        },
        onUpdate: (position) =>
            _move(position, Size(widget.diameter, widget.diameter)),
        onEnd: () {
          dragging = false;
          widget.onCommit(draft);
        },
        child: CustomPaint(
          painter: _DialPainter(
            f,
            af,
            widget.color ?? const Color(0xffaeb8b1),
            widget.format(draft),
            widget.sub,
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.f, this.af, this.color, this.text, this.sub);
  final double f, af;
  final Color color;
  final String text;
  final String? sub;
  @override
  void paint(Canvas c, Size s) {
    final center = Offset(s.width / 2, s.height / 2);
    final radius = math.min(s.width, s.height) / 2 - 13;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..color = const Color(0xffe8ebe6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11
      ..strokeCap = StrokeCap.round;
    c.drawArc(rect, 135 * math.pi / 180, 270 * math.pi / 180, false, base);
    if (af > 0) {
      c.drawArc(
        rect,
        135 * math.pi / 180,
        270 * af * math.pi / 180,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11
          ..strokeCap = StrokeCap.round,
      );
    }
    final a = (135 + 270 * f) * math.pi / 180;
    final point = Offset(
      center.dx + radius * math.cos(a),
      center.dy + radius * math.sin(a),
    );
    c.drawCircle(point, 12.5, Paint()..color = color);
    _draw(c, text, center.translate(0, -10), 34, ink, FontWeight.w600);
    if (sub != null) {
      _draw(c, sub!, center.translate(0, 18), 18, muted, FontWeight.w400);
    }
  }

  void _draw(
    Canvas c,
    String t,
    Offset p,
    double size,
    Color color,
    FontWeight w,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(fontSize: size, color: color, fontWeight: w),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 140);
    tp.paint(c, Offset(p.dx - tp.width / 2, p.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _DialPainter o) =>
      o.f != f ||
      o.af != af ||
      o.color != color ||
      o.text != text ||
      o.sub != sub;
}

class CoverControl extends StatefulWidget {
  const CoverControl({
    super.key,
    required this.value,
    required this.enabled,
    required this.movingDirection,
    required this.movingTarget,
    required this.up,
    required this.down,
    required this.stop,
    required this.setPosition,
  });
  final double value;
  final bool enabled;
  final int movingDirection;
  final double movingTarget;
  final VoidCallback up, down;
  final VoidCallback stop;
  final ValueChanged<double> setPosition;
  @override
  State<CoverControl> createState() => _CoverControlState();
}

class _CoverControlState extends State<CoverControl> {
  static const _blindHeight = 145.0;
  double target = 50;
  bool adjusting = false, init = false, hoveringTargetLine = false;

  @override
  void didUpdateWidget(covariant CoverControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!adjusting) {
      target = widget.movingDirection == 0 ? widget.value : widget.movingTarget;
    }
  }

  double get _markerPosition =>
      widget.movingDirection != 0 || !adjusting ? widget.value : target;

  void _updateTarget(double y) {
    final next = (100 * (1 - y / _blindHeight)).clamp(0.0, 100.0);
    setState(() {
      target = next;
      adjusting = true;
    });
  }

  void _updateHover(double y) {
    final lineY = _blindHeight * (1 - _markerPosition.clamp(0, 100) / 100);
    final overLine = (y - lineY).abs() <= 7;
    if (overLine != hoveringTargetLine) {
      setState(() => hoveringTargetLine = overLine);
    }
  }

  void _commitTarget() {
    final value = target;
    setState(() => adjusting = false);
    widget.setPosition(value);
  }

  @override
  Widget build(BuildContext context) {
    if (!init) {
      target = widget.value;
      init = true;
    }
    final markerPosition = _markerPosition;
    final currentLineY = _blindHeight * (1 - widget.value.clamp(0, 100) / 100);
    final targetLineY =
        _blindHeight *
        (1 -
            (widget.movingDirection != 0 ? widget.movingTarget : markerPosition)
                    .clamp(0, 100) /
                100);
    final darkExtent = widget.movingDirection != 0 || adjusting
        ? math.min(currentLineY, targetLineY)
        : currentLineY;
    final percentageColor = darkExtent > _blindHeight / 2 ? Colors.white : dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 95,
          height: _blindHeight,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CustomPaint(
                    painter: _BlindPositionPainter(
                      widget.value,
                      target: widget.movingDirection != 0
                          ? widget.movingTarget
                          : markerPosition,
                      moving: widget.movingDirection != 0 || adjusting,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: MouseRegion(
                  cursor: hoveringTargetLine
                      ? SystemMouseCursors.resizeUpDown
                      : SystemMouseCursors.basic,
                  onHover: (event) => _updateHover(event.localPosition.dy),
                  onExit: (_) => setState(() => hoveringTargetLine = false),
                  child: _TouchDragSurface(
                    enabled: widget.enabled,
                    onStart: (position) => _updateTarget(position.dy),
                    onUpdate: (position) => _updateTarget(position.dy),
                    onEnd: _commitTarget,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BlindTargetPainter(markerPosition),
                  ),
                ),
              ),
              IgnorePointer(
                child: Center(
                  child: Text(
                    '${(adjusting ? target : widget.value).round()}%',
                    style: TextStyle(
                      fontSize: 22.5,
                      fontWeight: FontWeight.w700,
                      color: percentageColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed:
                  widget.enabled &&
                      (widget.value < 100 || widget.movingDirection == 1)
                  ? (widget.movingDirection == 1 ? widget.stop : widget.up)
                  : null,
              icon: Icon(
                Icons.keyboard_arrow_up,
                size: 30,
                color: widget.movingDirection == 1 ? blue : null,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed:
                  widget.enabled &&
                      (widget.value > 0 || widget.movingDirection == -1)
                  ? (widget.movingDirection == -1 ? widget.stop : widget.down)
                  : null,
              icon: Icon(
                Icons.keyboard_arrow_down,
                size: 30,
                color: widget.movingDirection == -1 ? blue : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BlindPositionPainter extends CustomPainter {
  const _BlindPositionPainter(
    this.position, {
    required this.target,
    required this.moving,
  });

  final double position;
  final double target;
  final bool moving;

  @override
  void paint(Canvas canvas, Size size) {
    final lineY = size.height * (1 - position.clamp(0, 100) / 100);
    final targetY = size.height * (1 - target.clamp(0, 100) / 100);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (moving && targetY != lineY) {
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          math.min(lineY, targetY),
          size.width,
          (lineY - targetY).abs(),
        ),
        Paint()..color = const Color(0xffd5dbd6),
      );
    }
    final darkExtent = moving ? math.min(lineY, targetY) : lineY;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, darkExtent),
      Paint()..color = const Color(0xff9ca9a0),
    );
    canvas.drawLine(
      Offset(0, lineY),
      Offset(size.width, lineY),
      Paint()
        ..color = const Color(0xff66736a)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _BlindPositionPainter old) =>
      old.position != position || old.target != target || old.moving != moving;
}

class _BlindTargetPainter extends CustomPainter {
  const _BlindTargetPainter(this.position);

  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * (1 - position.clamp(0, 100) / 100);
    final lineHeight = 2.0;
    final top = (y - lineHeight / 2).clamp(0.0, size.height - lineHeight);
    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, lineHeight),
      Paint()..color = Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _BlindTargetPainter old) =>
      old.position != position;
}
