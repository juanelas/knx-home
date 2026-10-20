// Entity card and its kind-specific KNX controls.
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';
import 'knx_controls.dart';

class EntityCard extends StatelessWidget {
  const EntityCard({
    super.key,
    required this.entity,
    required this.values,
    required this.connected,
    required this.movementEntity,
    required this.movementStart,
    required this.movementTarget,
    required this.movementAt,
    required this.isOn,
    required this.iconFor,
    required this.displayValue,
    required this.decorateIcon,
    required this.onWrite,
    required this.onStopCover,
    required this.onReadEntity,
    required this.onShowAddresses,
  });

  final KnxEntity entity;
  final Map<String, Object> values;
  final bool connected;
  final String? movementEntity;
  final double movementStart;
  final double movementTarget;
  final DateTime? movementAt;
  final bool Function(KnxEntity) isOn;
  final IconData Function(KnxEntity) iconFor;
  final String Function(EntityState) displayValue;
  final Widget Function(KnxEntity, Widget) decorateIcon;
  final void Function(KnxEntity, CommandRole, Object) onWrite;
  final void Function(KnxEntity) onStopCover;
  final void Function(KnxEntity) onReadEntity;
  final void Function(KnxEntity) onShowAddresses;

  double _numericValue(Object? value) => value is num ? value.toDouble() : 0;

  @override
  Widget build(BuildContext context) {
    final e = entity;
    Object? current(String? id) => id == null ? null : values[id];
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
        : isOn(e)
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
      decoration: appPanelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: !connected
                    ? null
                    : e.kind == EntityKind.fan &&
                          e.commands.containsKey(CommandRole.speed)
                    ? () => onWrite(e, CommandRole.speed, isOn(e) ? 0 : 100)
                    : switchable
                    ? () => onWrite(e, CommandRole.power, !isOn(e))
                    : null,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isOn(e)
                        ? e.kind == EntityKind.climate
                              ? color.withValues(alpha: 0.16)
                              : e.kind == EntityKind.fan
                              ? color.withValues(alpha: 0.16)
                              : lime
                        : const Color(0xfff0f2ee),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: decorateIcon(
                    e,
                    e.kind == EntityKind.fan
                        ? Stack(
                            clipBehavior: Clip.none,
                            children: [
                              FanGlyph(
                                color: isOn(e)
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
                            iconFor(e),
                            size: 24,
                            color: isOn(e)
                                ? e.kind == EntityKind.climate
                                      ? color
                                      : dark
                                : muted,
                          ),
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
                height: 158,
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
                          enabled: connected,
                          onCommit: (v) => onWrite(e, CommandRole.target, v),
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
                                  connected &&
                                  (e.commands.containsKey(
                                        CommandRole.heatCool,
                                      ) ||
                                      e.commands.containsKey(CommandRole.mode)),
                              onChanged: (cooling) => onWrite(
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
                height: 158,
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
                          enabled: connected,
                          onCommit: (v) => onWrite(e, CommandRole.speed, v),
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
                                    onChanged: connected
                                        ? (_) => onWrite(
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
                height: 145,
                child: CoverControl(
                  value: _numericValue(current(position.id)),
                  enabled: connected,
                  movingDirection: movementEntity == e.id && movementAt != null
                      ? (movementTarget > movementStart ? 1 : -1)
                      : 0,
                  movingTarget: movementTarget,
                  up: () => e.commands.containsKey(CommandRole.move)
                      ? onWrite(e, CommandRole.move, 'open')
                      : onWrite(e, CommandRole.position, 100),
                  down: () => e.commands.containsKey(CommandRole.move)
                      ? onWrite(e, CommandRole.move, 'close')
                      : onWrite(e, CommandRole.position, 0),
                  stop: () => onStopCover(e),
                  setPosition: (v) =>
                      e.commands.containsKey(CommandRole.position)
                      ? onWrite(e, CommandRole.position, v)
                      : onWrite(
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
            Text(
              displayValue(speed),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w500),
            )
          else if (power != null && !compactEntity)
            Text(
              displayValue(power),
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w500),
            )
          else if (temp != null)
            Text(
              displayValue(temp),
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
              if (connected)
                SizedBox(
                  width: 38,
                  height: 38,
                  child: IconButton(
                    onPressed: () => onReadEntity(e),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 20, color: muted),
                  ),
                ),
              SizedBox(
                width: 38,
                height: 38,
                child: IconButton(
                  onPressed: () => onShowAddresses(e),
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
}
