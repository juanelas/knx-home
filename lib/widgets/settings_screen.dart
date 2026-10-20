// Gateway setup, entity configuration summary, and bus-monitor layout.
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.host,
    required this.port,
    required this.connected,
    required this.busy,
    required this.entities,
    required this.kindLabel,
    required this.onConnect,
    required this.onDisconnect,
    required this.onImport,
    required this.readableExpanded,
    required this.onToggleReadable,
    required this.entityRows,
    required this.busMonitor,
  });

  final TextEditingController host;
  final TextEditingController port;
  final bool connected;
  final bool busy;
  final List<KnxEntity> entities;
  final String Function(EntityKind) kindLabel;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onImport;
  final bool readableExpanded;
  final VoidCallback onToggleReadable;
  final List<Widget> entityRows;
  final Widget busMonitor;

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: appPanelDecoration(),
    child: child,
  );

  Widget _sectionTitle(IconData icon, String title, String subtitle) => Row(
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

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(
              Icons.wifi,
              'KNXnet/IP gateway',
              'Connect directly to a tunneling interface on your local network.',
            ),
            const SizedBox(height: 15),
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: constraints.maxWidth > 500
                        ? constraints.maxWidth * .65
                        : constraints.maxWidth,
                    child: _field('Gateway address', host, '192.168.1.100'),
                  ),
                  SizedBox(
                    width: constraints.maxWidth > 500
                        ? 130
                        : constraints.maxWidth,
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
                      color: connected ? Colors.green : muted,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      connected ? 'Connected · KNXnet/IP' : 'Not connected',
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : connected
                      ? onDisconnect
                      : onConnect,
                  icon: Icon(
                    busy
                        ? Icons.hourglass_top
                        : connected
                        ? Icons.wifi_off
                        : Icons.wifi,
                    size: 16,
                  ),
                  label: Text(
                    busy
                        ? 'Connecting…'
                        : connected
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
            _sectionTitle(
              Icons.verified_user,
              'Configured KNX entities',
              'Loaded from the imported configuration.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 9,
              children: [
                for (final kind in EntityKind.values)
                  Text(
                    '${entities.where((entity) => entity.kind == kind).length} ${kindLabel(kind)}',
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
                  onPressed: onImport,
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
              onTap: onToggleReadable,
              child: Row(
                children: [
                  Expanded(
                    child: _sectionTitle(
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
            if (readableExpanded) ...entityRows,
          ],
        ),
      ),
      const SizedBox(height: 10),
      _panel(child: busMonitor),
    ],
  );
}
