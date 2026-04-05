import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';
import '../models/runtime_config.dart';
import 'approval_panel.dart';
import 'chat_view.dart';
import 'connection_panel.dart';

/// Main workbench page.
///
/// Layout:
///
///   ┌─────────────────────────────────────────┐
///   │  AppBar (name · title · conn status)    │
///   ├─────────────────────────────────────────┤
///   │  ConnectionPanel (status bar)           │
///   ├─────────────────────────────────────────┤
///   │  ChatView  (main area)                  │
///   ├─────────────────────────────────────────┤
///   │  ApprovalPanel (only when pending)      │
///   ├─────────────────────────────────────────┤
///   │  Debug Panel (collapsible)              │
///   ├─────────────────────────────────────────┤
///   │  Prompt input + Send / Interrupt        │
///   └─────────────────────────────────────────┘
class WorkbenchPage extends StatefulWidget {
  final WorkbenchController controller;
  final RuntimeConfig runtimeConfig;

  /// Called when the user taps Settings.  Caller is responsible for navigating
  /// to SetupPage and triggering a reconnect if needed.
  final VoidCallback onOpenSettings;

  const WorkbenchPage({
    super.key,
    required this.controller,
    required this.runtimeConfig,
    required this.onOpenSettings,
  });

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  final _promptController = TextEditingController();
  final _cwdController = TextEditingController(text: '/tmp');
  bool _debugExpanded = false;

  @override
  void dispose() {
    _promptController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  Future<void> _sendPrompt() async {
    final text = _promptController.text.trim();
    if (text.isEmpty) return;
    _promptController.clear();
    await widget.controller.startTurn(
      text,
      cwd: _cwdController.text.trim().ifEmpty('/tmp'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        return Scaffold(
          backgroundColor: const Color(0xFF1A1A1A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF111111),
            title: Row(
              children: [
                const CircleAvatar(
                  radius: 14,
                  backgroundColor: Color(0xFF333333),
                  child: Icon(Icons.person, size: 16, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  ctrl.userProfile?.name ?? 'User',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const SizedBox(width: 12),
                const Text('·',
                    style: TextStyle(fontSize: 15, color: Colors.grey)),
                const SizedBox(width: 12),
                const Text(
                  '小螃蟹 Workbench',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ],
            ),
            actions: [
              if (ctrl.currentThreadId != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: Text(
                      'thread: ${_short(ctrl.currentThreadId!)}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.settings, size: 18),
                tooltip: 'Settings',
                onPressed: widget.onOpenSettings,
              ),
            ],
          ),
          body: Column(
            children: [
              // ── Connection status bar ─────────────────────────────────────
              ConnectionPanel(
                controller: ctrl,
                defaultEndpoint: widget.runtimeConfig.endpoint,
              ),
              const Divider(height: 1, color: Color(0xFF2A2A2A)),

              // ── Chat view (main area) ─────────────────────────────────────
              Expanded(
                child: ChatView(controller: ctrl),
              ),

              // ── Approval panel (only when pending) ────────────────────────
              ApprovalPanel(controller: ctrl),

              // ── Collapsible debug / log panel ─────────────────────────────
              _DebugPanel(
                controller: ctrl,
                expanded: _debugExpanded,
                onToggle: () =>
                    setState(() => _debugExpanded = !_debugExpanded),
              ),

              const Divider(height: 1, color: Color(0xFF333333)),

              // ── Prompt input bar ──────────────────────────────────────────
              _PromptBar(
                promptController: _promptController,
                cwdController: _cwdController,
                controller: ctrl,
                onSend: _sendPrompt,
              ),
            ],
          ),
        );
      },
    );
  }

  String _short(String id) =>
      id.length > 12 ? '${id.substring(0, 12)}…' : id;
}

// ── Debug / Diff panel ────────────────────────────────────────────────────────

class _DebugPanel extends StatelessWidget {
  final WorkbenchController controller;
  final bool expanded;
  final VoidCallback onToggle;

  const _DebugPanel({
    required this.controller,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final diff = controller.lastTurnDiff;
    final hasDiff = diff != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Toggle header
        InkWell(
          onTap: hasDiff ? onToggle : null,
          child: Container(
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: hasDiff ? Colors.grey : Colors.grey.shade700,
                ),
                const SizedBox(width: 4),
                Text(
                  hasDiff ? 'Diff' : 'Diff  (none)',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasDiff ? Colors.grey : Colors.grey.shade700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),

        if (expanded && hasDiff)
          Container(
            height: 160,
            color: const Color(0xFF111111),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: _DiffView(diff: diff),
            ),
          ),
      ],
    );
  }
}

class _DiffView extends StatelessWidget {
  final String diff;
  const _DiffView({required this.diff});

  @override
  Widget build(BuildContext context) {
    final lines = diff.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        final color = line.startsWith('+')
            ? Colors.green.shade400
            : line.startsWith('-')
                ? Colors.red.shade400
                : line.startsWith('@@')
                    ? Colors.blue.shade300
                    : Colors.grey.shade400;
        return Text(
          line,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            color: color,
          ),
        );
      }).toList(),
    );
  }
}

// ── Prompt input bar ──────────────────────────────────────────────────────────

class _PromptBar extends StatelessWidget {
  final TextEditingController promptController;
  final TextEditingController cwdController;
  final WorkbenchController controller;
  final VoidCallback onSend;

  const _PromptBar({
    required this.promptController,
    required this.cwdController,
    required this.controller,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final canSend = controller.isConnected && !controller.isInProgress;
    final canInterrupt = controller.isConnected && controller.isInProgress;

    return Container(
      padding: const EdgeInsets.all(8),
      color: const Color(0xFF111111),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // CWD row
          Row(
            children: [
              const Text(
                'cwd:',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: cwdController,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '/path/to/project',
                    hintStyle: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Prompt row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: promptController,
                  enabled: canSend,
                  maxLines: null,
                  style:
                      const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: canSend
                        ? 'Enter a prompt for Codex…'
                        : (controller.isConnected
                            ? 'Working…'
                            : 'Connecting…'),
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: canSend ? (_) => onSend() : null,
                ),
              ),
              const SizedBox(width: 8),
              if (canInterrupt)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.orange),
                  tooltip: 'Interrupt turn',
                  onPressed: controller.interruptTurn,
                ),
              const SizedBox(width: 4),
              ElevatedButton.icon(
                onPressed: canSend ? onSend : null,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Send'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
