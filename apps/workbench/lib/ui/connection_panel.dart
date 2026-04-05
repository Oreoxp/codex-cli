import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';

/// Collapsible connection panel: URL input + connect/disconnect button + status.
class ConnectionPanel extends StatefulWidget {
  final WorkbenchController controller;
  final String defaultEndpoint;

  const ConnectionPanel({
    super.key,
    required this.controller,
    required this.defaultEndpoint,
  });

  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  late final TextEditingController _urlController;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.defaultEndpoint);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    final ctrl = widget.controller;
    if (ctrl.isConnected) {
      await ctrl.disconnect();
      return;
    }
    setState(() => _connecting = true);
    try {
      await ctrl.connect(_urlController.text.trim());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final connected = ctrl.isConnected;

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusDot(connected: connected),
                const SizedBox(width: 8),
                Text(
                  connected
                      ? 'Connected'
                      : (ctrl.lastError != null ? 'Error' : 'Disconnected'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    enabled: !connected && !_connecting,
                    decoration: const InputDecoration(
                      labelText: 'app-server WebSocket URL',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    onSubmitted: (_) => _toggleConnection(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connecting ? null : _toggleConnection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        connected ? Colors.red.shade700 : Colors.green.shade700,
                    foregroundColor: Colors.white,
                  ),
                  child: _connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(connected ? 'Disconnect' : 'Connect'),
                ),
              ],
            ),
            if (ctrl.lastError != null && !connected) ...[
              const SizedBox(height: 6),
              Text(
                ctrl.lastError!,
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool connected;
  const _StatusDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: connected ? Colors.green : Colors.grey,
      ),
    );
  }
}
