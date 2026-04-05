import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';
import '../models/runtime_config.dart';
import 'approval_panel.dart';
import 'connection_panel.dart';
import 'event_list.dart';

/// Main workbench page.
///
/// Layout (single window, desktop):
///
///   ┌────────────────────────────────────────────────┐
///   │  Connection Panel (top bar)                    │
///   ├─────────────────────────┬──────────────────────┤
///   │                         │  Result / Diff Panel │
///   │  Event Feed             │  (right side)        │
///   │                         │                      │
///   ├─────────────────────────┴──────────────────────┤
///   │  Approval Panel (shown only when pending)      │
///   ├────────────────────────────────────────────────┤
///   │  Prompt Input + Send / Interrupt buttons       │
///   └────────────────────────────────────────────────┘
class WorkbenchPage extends StatefulWidget {
  final WorkbenchController controller;
  final RuntimeConfig runtimeConfig;
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
                const Text(
                  '·',
                  style: TextStyle(fontSize: 15, color: Colors.grey),
                ),
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
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
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
              // ── Connection panel ─────────────────────────────────────────
              ConnectionPanel(
                controller: ctrl,
                defaultEndpoint: widget.runtimeConfig.endpoint,
              ),

              // ── Main area: event feed + result panel ─────────────────────
              Expanded(
                child: Row(
                  children: [
                    // Event feed (left, 60% width)
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 0, 2),
                            child: Text(
                              'Event Feed',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFF333333)),
                          Expanded(
                            child: EventList(controller: ctrl),
                          ),
                        ],
                      ),
                    ),

                    const VerticalDivider(
                        width: 1, color: Color(0xFF333333)),

                    // Result / diff panel (right, 40% width)
                    Expanded(
                      flex: 4,
                      child: _ResultPanel(controller: ctrl),
                    ),
                  ],
                ),
              ),

              // ── Approval panel (only visible when pending) ────────────────
              ApprovalPanel(controller: ctrl),

              const Divider(height: 1, color: Color(0xFF333333)),

              // ── Prompt input bar ─────────────────────────────────────────
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

// ── Result / Diff Panel ────────────────────────────────────────────────────

class _ResultPanel extends StatelessWidget {
  final WorkbenchController controller;
  const _ResultPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final msg = controller.lastAgentMessage;
    final diff = controller.lastTurnDiff;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 2),
          child: Text(
            'Result  /  Diff',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF333333)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (controller.isInProgress)
                  const Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Working…',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                if (msg != null) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Agent reply:',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    msg,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                    ),
                  ),
                ],
                if (diff != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Diff:',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _DiffView(diff: diff),
                ],
                if (msg == null && diff == null && !controller.isInProgress)
                  const Text(
                    'No result yet.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
              ],
            ),
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
            fontSize: 11,
            color: color,
          ),
        );
      }).toList(),
    );
  }
}

// ── Prompt input bar ──────────────────────────────────────────────────────

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
    final canInterrupt =
        controller.isConnected && controller.isInProgress;

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
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Enter a prompt for Codex…',
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
