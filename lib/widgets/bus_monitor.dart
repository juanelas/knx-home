// KNX bus monitor: telegram history, manual reads/writes, and DPT decoding.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../knx_client.dart';
import '../models.dart';

class BusMonitor extends StatefulWidget {
  const BusMonitor({
    super.key,
    required this.client,
    required this.entities,
    required this.readAddress,
    required this.onNotice,
  });

  final KnxClient client;
  final List<KnxEntity> entities;
  final Future<Object> Function(String address, String dpt) readAddress;
  final void Function(String message, {bool error}) onNotice;

  @override
  State<BusMonitor> createState() => _BusMonitorState();
}

class _BusMonitorState extends State<BusMonitor> {
  final monitorAddress = TextEditingController();
  final monitorDpt = TextEditingController(text: '1.001');
  final monitorValue = TextEditingController();
  final selectedDpt = <int, String>{};
  String filter = '';
  bool paused = false;

  @override
  void dispose() {
    monitorAddress.dispose();
    monitorDpt.dispose();
    monitorValue.dispose();
    widget.client.monitorPaused = false;
    super.dispose();
  }

  Widget _panelTitle(IconData icon, String title, String subtitle) => Row(
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
            Text(subtitle, style: const TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ),
    ],
  );

  Widget _field(String label, TextEditingController controller, String hint) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 3),
          TextField(
            controller: controller,
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

  @override
  Widget build(BuildContext context) {
    final known = <String, String>{};
    for (final e in widget.entities) {
      for (final s in e.states) {
        known[s.address] = '${e.name} · ${s.label}';
      }
      for (final c in e.commands.values) {
        known[c.address] = '${e.name} (cmd)';
      }
    }
    final items = widget.client.history
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
                'LIVE TELEGRAMS · ${widget.client.connected ? 'CONNECTED' : 'DISCONNECTED'}',
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                paused = !paused;
                widget.client.monitorPaused = paused;
              }),
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            ),
            IconButton(
              onPressed: () => setState(() => widget.client.history.clear()),
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
                onPressed: widget.client.connected
                    ? () async {
                        try {
                          final address = monitorAddress.text.trim();
                          final configuredDpt = widget.entities
                              .expand((entity) => entity.states)
                              .where((state) => state.address == address)
                              .map((state) => state.dpt)
                              .firstOrNull;
                          final v = await widget.readAddress(
                            address,
                            configuredDpt ?? monitorDpt.text,
                          );
                          widget.onNotice('$address = $v');
                        } catch (e) {
                          widget.onNotice('$e', error: true);
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
                onPressed: widget.client.connected
                    ? () => widget.client.write(
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
      ...widget.entities.expand(
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
            '${t.direction.toUpperCase()} ${t.type.toUpperCase()}',
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
            textAlign: TextAlign.end,
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

  /// Decodes the monitor's raw payload for display without changing bus data.
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
