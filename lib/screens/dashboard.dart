// Dashboard state, KNX actions, navigation, and entity presentation.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../config_io.dart';
import '../knx_client.dart';
import '../widgets/bus_monitor.dart';
import '../widgets/entity_card.dart';
import '../widgets/knx_controls.dart';
import '../widgets/settings_screen.dart';
import '../widgets/welcome_screen.dart';
import '../models.dart';

/// Coordinates gateway lifecycle, entity values, navigation, and user actions.
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final client = KnxClient();
  List<KnxEntity> entities = [];
  final Map<String, Object> values = {};
  final Set<String> knownStateIds = {};
  final host = TextEditingController(),
      port = TextEditingController(text: '3671'),
      search = TextEditingController();
  String configText = '',
      category = 'All',
      roomFilter = 'All rooms',
      query = '';
  int page = 0;
  bool ready = false,
      busy = false,
      manuallyDisconnected = false,
      reconnecting = false,
      hasConnectedToTunnel = false,
      readableExpanded = false,
      gatewayConfigured = false;
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
    if (client.connected && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(_refreshAll());
    } else if (!client.connected && !busy && !reconnecting) {
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
    configText = repairStoredMojibake(p.getString('knx-config-yaml') ?? '');
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

  /// Applies each incoming bus value to states configured for that group address.
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
          if (!s.assumed) knownStateIds.add(s.id);
        }
      }
    });
  }

  /// Converts a decoded KNX value into the value the UI uses for this role.
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

  bool _isOn(KnxEntity e) {
    final p = e.state(StateRole.power);
    final speed = e.state(StateRole.speed);
    final v = values[p?.id ?? speed?.id];
    return v == true || (v is num && v > 0);
  }

  Future<void> _connect({bool silent = false}) async {
    if (busy) return;
    final isReconnect = hasConnectedToTunnel;
    manuallyDisconnected = false;
    setState(() => busy = true);
    try {
      if (Platform.isAndroid) {
        final allowed =
            await localNetworkChannel.invokeMethod<bool>('requestAccess') ??
            false;
        if (!allowed) {
          throw StateError(
            'Local network access is required to connect to the KNX gateway.',
          );
        }
      }
      await client.connect(host.text.trim(), int.tryParse(port.text) ?? 3671);
      hasConnectedToTunnel = true;
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
      if (isReconnect) {
        _notice('KNX tunnel reconnected.', warning: true);
      } else if (!silent) {
        _notice('Connected to KNX gateway.');
      }
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
      final text = repairStoredMojibake(
        decodeConfigBytes(await result.readAsBytes()),
      );
      final parsed = parseEntities(text);
      final p = await SharedPreferences.getInstance();
      await p.setString('knx-config-yaml', text);
      setState(() {
        configText = text;
        entities = parsed;
        values.clear();
        knownStateIds.clear();
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

  void _notice(String text, {bool error = false, bool warning = false}) {
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
                      : warning
                      ? const Color(0xfffff8df)
                      : const Color(0xfff2f8e9),
                  border: Border.all(
                    color: error
                        ? const Color(0xffeac4b8)
                        : warning
                        ? const Color(0xffead590)
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
                      error
                          ? Icons.error_outline
                          : warning
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      size: 17,
                      color: error
                          ? const Color(0xff9b4b35)
                          : warning
                          ? const Color(0xff8a6a0a)
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
                              : warning
                              ? const Color(0xff765d13)
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
    // Group responses can be delayed or lost, so a direct/manual read gets up
    // to four attempts before the caller reports a failure.
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!client.connected) {
        throw StateError('Disconnected from KNX gateway.');
      }
      try {
        return await client.read(address, dpt);
      } catch (error) {
        lastError = error;
        if (attempt == 3 || !client.connected) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw lastError ?? StateError('Could not read KNX state.');
  }

  Future<void> _readEntity(KnxEntity e) async {
    await _readStates(e.states);
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
    await _readStates(entities.expand((entity) => entity.states), quiet: true);
  }

  Future<void> _readStates(
    Iterable<EntityState> states, {
    bool quiet = false,
  }) async {
    // Read each configured status address once, in sequence. Several entities
    // can share one address, so only its first state needs to trigger a read.
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
    for (final state in uniqueStates) {
      if (!client.connected) return;
      if (quiet) {
        await _readQuietly(state);
      } else {
        await _read(state);
      }
    }
  }

  Future<void> _readQuietly(EntityState state) async {
    try {
      await _readAddressWithRetry(state.address, state.dpt);
    } catch (_) {
      // Background refreshes retry silently so a batch cannot flood notices.
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
      // A command telegram is not itself status feedback. Only states that
      // share the command address are updated optimistically below.
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
        setState(() {
          values[state.id] = shown;
          if (point.address == state.address) {
            knownStateIds.add(state.id);
          }
        });
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
    // Estimate position locally while the cover moves; incoming position
    // feedback is ignored during this interval to avoid fighting the estimate.
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
      return WelcomeScreen(
        hasConfiguration: configText.isNotEmpty && entities.isNotEmpty,
        gatewayConfigured: gatewayConfigured,
        connected: client.connected,
        busy: busy,
        host: host,
        port: port,
        onImport: _importConfig,
        onConnect: () => _connect(),
      );
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
      ],
    );
  }

  Future<void> _refresh() async {
    await _readStates(filtered.expand((entity) => entity.states));
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
              SizedBox(
                width: cardWidth,
                height:
                    entity.kind == EntityKind.plug ||
                        entity.kind == EntityKind.light ||
                        entity.kind == EntityKind.extractor
                    ? 128
                    : 286,
                child: _entityCard(entity),
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

  EntityState? _primaryState(KnxEntity e) => switch (e.kind) {
    EntityKind.plug ||
    EntityKind.light ||
    EntityKind.extractor => e.state(StateRole.power),
    EntityKind.climate =>
      e.state(StateRole.power) ??
          e.state(StateRole.mode) ??
          e.state(StateRole.heatCool) ??
          e.state(StateRole.temperature) ??
          e.state(StateRole.target),
    EntityKind.fan => e.state(StateRole.speed) ?? e.state(StateRole.direction),
    EntityKind.cover => e.state(StateRole.position),
    EntityKind.select => e.state(StateRole.option),
  };

  bool _hasUnknownState(KnxEntity e) {
    final state = _primaryState(e);
    return state == null || !knownStateIds.contains(state.id);
  }

  Widget _withUnknownStateBadge(KnxEntity e, Widget icon) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.center,
    children: [
      icon,
      if (_hasUnknownState(e))
        Positioned(
          right: -5,
          top: -5,
          child: Tooltip(
            message: 'State not yet known',
            child: Container(
              width: 17,
              height: 17,
              decoration: BoxDecoration(
                color: const Color(0xffffdf75),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.priority_high,
                size: 12,
                color: Color(0xff725600),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _entityCard(KnxEntity entity) => EntityCard(
    entity: entity,
    values: values,
    connected: client.connected,
    movementEntity: movementEntity,
    movementStart: movementStart,
    movementTarget: movementTarget,
    movementAt: movementAt,
    isOn: _isOn,
    iconFor: _icon,
    displayValue: _display,
    decorateIcon: _withUnknownStateBadge,
    onWrite: (entity, role, value) => _write(entity, role, value),
    onStopCover: (entity) => _stopCover(entity),
    onReadEntity: (entity) => _readEntity(entity),
    onShowAddresses: _showEntityAddresses,
  );

  Widget _settings() => SettingsScreen(
    host: host,
    port: port,
    connected: client.connected,
    busy: busy,
    entities: entities,
    kindLabel: (kind) => _label(kind).toLowerCase(),
    onConnect: () => _connect(),
    onDisconnect: _disconnect,
    onImport: _importConfig,
    readableExpanded: readableExpanded,
    onToggleReadable: () =>
        setState(() => readableExpanded = !readableExpanded),
    entityRows: readableExpanded ? entities.map(_entityRow).toList() : const [],
    busMonitor: BusMonitor(
      client: client,
      entities: entities,
      readAddress: _readAddressWithRetry,
      onNotice: _notice,
    ),
  );

  Widget _entityRow(KnxEntity e) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: _withUnknownStateBadge(
      e,
      e.kind == EntityKind.fan
          ? const FanGlyph(color: muted)
          : Icon(_icon(e), size: 18, color: muted),
    ),
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
}
