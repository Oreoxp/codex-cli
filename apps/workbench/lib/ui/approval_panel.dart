import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';

/// Inline approval panel shown when [controller.pendingApproval] is non-null.
class ApprovalPanel extends StatelessWidget {
  final WorkbenchController controller;

  const ApprovalPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final approval = controller.pendingApproval;
    if (approval == null) return const SizedBox.shrink();

    final isCmd = approval.kind == 'commandExecution';
    final label = isCmd ? 'Execute command?' : 'Apply file change?';
    final detail = isCmd
        ? approval.commandSummary
        : 'File change  (see diff)';

    return Card(
      color: Colors.yellow.shade900,
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.yellow),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              detail,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.white70,
              ),
            ),
            if (approval.cwd != null) ...[
              const SizedBox(height: 2),
              Text(
                'cwd: ${approval.cwd}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.white54,
                ),
              ),
            ],
            if (approval.reason != null) ...[
              const SizedBox(height: 4),
              Text(
                'Reason: ${approval.reason}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                _ApprovalButton(
                  label: 'Approve',
                  icon: Icons.check_circle_outline,
                  color: Colors.green,
                  onTap: () => controller.respondToApproval('accept'),
                ),
                const SizedBox(width: 8),
                _ApprovalButton(
                  label: 'Approve for session',
                  icon: Icons.lock_open_outlined,
                  color: Colors.green.shade300,
                  onTap: () => controller.respondToApproval('acceptForSession'),
                ),
                const SizedBox(width: 8),
                _ApprovalButton(
                  label: 'Reject',
                  icon: Icons.cancel_outlined,
                  color: Colors.red.shade400,
                  onTap: () => controller.respondToApproval('decline'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ApprovalButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ApprovalButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }
}
