import 'dart:convert';

import 'package:yaml/yaml.dart';

enum EntityKind { plug, light, fan, extractor, cover, climate, select }

enum StateRole {
  power,
  brightness,
  color,
  speed,
  oscillation,
  position,
  angle,
  temperature,
  target,
  mode,
  heatCool,
  option,
  direction,
}

enum CommandRole {
  power,
  brightness,
  color,
  speed,
  oscillation,
  position,
  move,
  stop,
  angle,
  target,
  mode,
  heatCool,
  option,
  direction,
}

String _slug(String text) => utf8
    .encode(text.toLowerCase())
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
String _text(Map<dynamic, dynamic> map, String key, [String fallback = '']) =>
    map[key]?.toString() ?? fallback;
double? _number(Map<dynamic, dynamic> map, String key) =>
    (map[key] as num?)?.toDouble();
bool _bool(Map<dynamic, dynamic> map, String key) => map[key] == true;

class GroupPoint {
  const GroupPoint(this.address, this.dpt, {this.invert = false});
  final String address;
  final String dpt;
  final bool invert;
}

class EntityState extends GroupPoint {
  const EntityState({
    required this.id,
    required this.label,
    required this.role,
    required String address,
    required String dpt,
    bool invert = false,
    this.assumed = false,
  }) : super(address, dpt, invert: invert);
  final String id;
  final String label;
  final StateRole role;
  final bool assumed;
}

class KnxEntity {
  KnxEntity({
    required this.id,
    required this.name,
    required this.room,
    required this.kind,
    required this.states,
    required this.commands,
    this.minTemp,
    this.maxTemp,
    this.temperatureStep,
    this.maxStep,
    this.positionStep,
    this.options = const [],
    this.controllerMode = false,
    this.directionValues = const {'winter': 0, 'summer': 255},
    this.travellingTimeDown,
    this.travellingTimeUp,
  });
  final String id, name, room;
  final EntityKind kind;
  final List<EntityState> states;
  final Map<CommandRole, GroupPoint> commands;
  final double? minTemp,
      maxTemp,
      temperatureStep,
      maxStep,
      positionStep,
      travellingTimeDown,
      travellingTimeUp;
  final List<({String name, int value})> options;
  final bool controllerMode;
  final Map<String, int> directionValues;
  EntityState? state(StateRole role) {
    for (final s in states) {
      if (s.role == role) return s;
    }
    return null;
  }
}

/// Maps the YAML device schema to the app's shared state and command model.
List<KnxEntity> parseEntities(String yaml) {
  final root = loadYaml(yaml);
  if (root is! YamlMap || root['rooms'] is! YamlList) {
    throw const FormatException('Configuration must contain a rooms list.');
  }
  final entities = <KnxEntity>[];
  for (final roomValue in root['rooms'] as YamlList) {
    if (roomValue is! YamlMap || roomValue['devices'] is! YamlList) continue;
    final room = _text(roomValue, 'name', 'Room');
    for (final value in roomValue['devices'] as YamlList) {
      if (value is! YamlMap) continue;
      final d = Map<dynamic, dynamic>.from(value);
      final name = _text(d, 'name');
      if (name.isEmpty) continue;
      final type = _text(d, 'type');
      final kind = switch (type) {
        'outlet' || 'switch' => EntityKind.plug,
        'extractor' || 'extractors' => EntityKind.extractor,
        'light' =>
          _text(d, 'device_class') == 'outlet'
              ? EntityKind.plug
              : EntityKind.light,
        'thermostat' => EntityKind.climate,
        'cover' => EntityKind.cover,
        'fan' => EntityKind.fan,
        _ => null,
      };
      if (kind == null) continue;
      final id = '${_slug(room)}-${_slug(name)}';
      final states = <EntityState>[];
      final commands = <CommandRole, GroupPoint>{};
      void state(
        StateRole role,
        String label,
        String? address,
        String dpt, {
        bool invert = false,
        bool assumed = false,
      }) {
        if (address != null && address.isNotEmpty) {
          // Missing explicit feedback addresses fall back to command addresses
          // and are marked assumed so startup reads do not query them.
          states.add(
            EntityState(
              id: '$id-${role.name}',
              label: label,
              role: role,
              address: address,
              dpt: dpt,
              invert: invert,
              assumed: assumed,
            ),
          );
        }
      }

      void command(
        CommandRole role,
        String? address,
        String dpt, {
        bool invert = false,
      }) {
        if (address != null && address.isNotEmpty) {
          commands[role] = GroupPoint(address, dpt, invert: invert);
        }
      }

      switch (type) {
        case 'outlet':
        case 'switch':
        case 'light':
        case 'extractor':
        case 'extractors':
          final address = _text(d, 'group_address');
          final feedback = _text(d, 'state_group_address', address);
          state(
            StateRole.power,
            'Power',
            feedback,
            '1.001',
            assumed: d['state_group_address'] == null && address.isNotEmpty,
          );
          command(CommandRole.power, address, '1.001');
          break;
        case 'thermostat':
          state(
            StateRole.temperature,
            'Temperature',
            d['temperature_group_address']?.toString(),
            '9.001',
          );
          final target = _text(d, 'target_temperature_group_address');
          state(
            StateRole.target,
            'Target',
            _text(d, 'target_temperature_state_group_address', target),
            '9.001',
            assumed:
                d['target_temperature_state_group_address'] == null &&
                target.isNotEmpty,
          );
          final power = _text(d, 'on_off_group_address');
          state(
            StateRole.power,
            'Power',
            _text(d, 'on_off_state_group_address', power),
            '1.001',
            assumed:
                d['on_off_state_group_address'] == null && power.isNotEmpty,
          );
          final mode = _text(d, 'hvac_mode_group_address');
          state(
            StateRole.mode,
            'Mode',
            _text(d, 'hvac_mode_state_group_address', mode),
            '20.105',
            assumed:
                d['hvac_mode_state_group_address'] == null && mode.isNotEmpty,
          );
          final season = _text(d, 'cool_heat_group_address');
          state(
            StateRole.heatCool,
            'Heating/cooling',
            _text(d, 'cool_heat_state_group_address', season),
            '1.001',
            assumed:
                d['cool_heat_state_group_address'] == null && season.isNotEmpty,
          );
          command(CommandRole.target, target, '9.001');
          command(CommandRole.power, power, '1.001');
          command(CommandRole.mode, mode, '20.105');
          command(CommandRole.heatCool, season, '1.001');
          break;
        case 'cover':
          final position = _text(d, 'position_group_address');
          state(
            StateRole.position,
            'Position',
            _text(d, 'position_state_group_address', position),
            '5.001',
            invert: _bool(d, 'invert_position'),
            assumed:
                d['position_state_group_address'] == null &&
                position.isNotEmpty,
          );
          command(
            CommandRole.position,
            position,
            '5.001',
            invert: _bool(d, 'invert_position'),
          );
          command(
            CommandRole.move,
            _text(d, 'move_group_address'),
            '1.008',
            invert: _bool(d, 'invert_updown'),
          );
          command(CommandRole.stop, _text(d, 'stop_group_address'), '1.010');
          break;
        case 'fan':
          final speed = _text(
            d,
            'speed_group_address',
            _text(d, 'group_address'),
          );
          state(
            StateRole.speed,
            'Speed',
            _text(d, 'speed_state_group_address', speed),
            '5.001',
            assumed: d['speed_state_group_address'] == null && speed.isNotEmpty,
          );
          final direction = _text(d, 'direction_group_address');
          final dpt = _text(d, 'direction_mode_dpt', '5.005');
          state(
            StateRole.direction,
            'Season',
            _text(d, 'direction_state_address', direction),
            dpt,
            assumed:
                d['direction_state_address'] == null && direction.isNotEmpty,
          );
          command(CommandRole.speed, speed, '5.001');
          command(CommandRole.direction, direction, dpt);
          break;
      }
      entities.add(
        KnxEntity(
          id: id,
          name: name,
          room: room,
          kind: kind,
          states: states,
          commands: commands,
          minTemp: _number(d, 'min_temperature'),
          maxTemp: _number(d, 'max_temperature'),
          temperatureStep: _number(d, 'temperature_step'),
          maxStep: _number(d, 'max_step'),
          positionStep: _number(d, 'position_step'),
          controllerMode:
              type == 'thermostat' && commands.containsKey(CommandRole.mode),
          directionValues: {
            'winter': (_number(d, 'direction_winter_value') ?? 0).round(),
            'summer': (_number(d, 'direction_summer_value') ?? 255).round(),
          },
          travellingTimeDown: _number(d, 'travelling_time_down'),
          travellingTimeUp: _number(d, 'travelling_time_up'),
        ),
      );
    }
  }
  if (entities.isEmpty) {
    throw const FormatException(
      'No supported devices were found in this configuration.',
    );
  }
  return entities;
}
