// Initial setup screen for importing entities and connecting to KNX.
import 'package:flutter/material.dart';

import '../app_theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.hasConfiguration,
    required this.gatewayConfigured,
    required this.connected,
    required this.busy,
    required this.host,
    required this.port,
    required this.onImport,
    required this.onConnect,
  });

  final bool hasConfiguration;
  final bool gatewayConfigured;
  final bool connected;
  final bool busy;
  final TextEditingController host;
  final TextEditingController port;
  final VoidCallback onImport;
  final VoidCallback onConnect;

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
  Widget build(BuildContext context) {
    final hasConfig = hasConfiguration;
    final hasGateway = host.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.all(28),
              decoration: appPanelDecoration(),
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
                    onPressed: onImport,
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
                    complete: gatewayConfigured || connected,
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
                      onPressed: busy || connected || !hasGateway
                          ? null
                          : () => onConnect(),
                      icon: Icon(
                        busy
                            ? Icons.hourglass_top
                            : connected
                            ? Icons.check_circle_outline
                            : Icons.wifi,
                        size: 17,
                      ),
                      label: Text(
                        busy
                            ? 'Connecting…'
                            : connected
                            ? 'Gateway connected'
                            : 'Connect gateway',
                      ),
                    ),
                  ),
                  if (hasGateway && !connected)
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
}
