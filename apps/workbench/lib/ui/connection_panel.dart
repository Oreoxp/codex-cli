import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';
import '../services/app_server_service.dart';

/// Read-only connection status bar.
///
/// Shows the endpoint URL and a status dot.  No connect/disconnect button —
/// connection is managed automatically by the app.
class ConnectionPanel extends StatelessWidget {
  final WorkbenchController controller;
  final String defaultEndpoint;

  const ConnectionPanel({
    super.key,
    required this.controller,
    required this.defaultEndpoint,
  });

  @override
  Widget build(BuildContext context) {
    final state = controller.connectionState;
    final err = controller.lastError;

    final (dot, label) = switch (state) {
      AppServerConnectionState.connected => (Colors.green, 'Connected'),
      AppServerConnectionState.connecting => (Colors.orange, 'Connecting…'),
      AppServerConnectionState.error => (Colors.red, 'Error'),
      AppServerConnectionState.disconnected => (Colors.grey, 'Disconnected'),
    };

    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _Dot(color: dot),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
          const SizedBox(width: 12),
          const Text('·', style: TextStyle(color: Colors.grey)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              defaultEndpoint,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.grey,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (err != null && state == AppServerConnectionState.error)
            Tooltip(
              message: err,
              child: const Icon(Icons.error_outline,
                  size: 14, color: Colors.red),
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
