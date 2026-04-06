import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

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
  bool _debugExpanded = false;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _sendPrompt() async {
    final text = _promptController.text.trim();
    if (text.isEmpty) return;
    _promptController.clear();
    await widget.controller.startTurn(text);
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
          body: Row(
            children: [
              // ── Left workspace/threads panel ──────────────────────────────────
              Container(
                width: 200,
                color: const Color(0xFF151515),
                child: _WorkspacePanel(controller: ctrl),
              ),
              // ── Main content area ──────────────────────────────────────────────
              Expanded(
                child: Column(
                  children: [
                    // ── Connection status bar ────────────────────────────
                    ConnectionPanel(
                      controller: ctrl,
                      defaultEndpoint: widget.runtimeConfig.endpoint,
                    ),
                    const Divider(height: 1, color: Color(0xFF2A2A2A)),

                    // ── Chat view (main area) ────────────────────────────
                    Expanded(
                      child: ChatView(controller: ctrl),
                    ),

                    // ── Approval panel ───────────────────────────────────
                    ApprovalPanel(controller: ctrl),

                    // ── Debug panel ──────────────────────────────────────
                    _DebugPanel(
                      controller: ctrl,
                      expanded: _debugExpanded,
                      onToggle: () =>
                          setState(() => _debugExpanded = !_debugExpanded),
                    ),

                    const Divider(height: 1, color: Color(0xFF333333)),

                    // ── Prompt input bar ─────────────────────────────────
                    _PromptBar(
                      promptController: _promptController,
                      controller: ctrl,
                      onSend: _sendPrompt,
                    ),
                  ],
                ),
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
  final WorkbenchController controller;
  final VoidCallback onSend;

  const _PromptBar({
    required this.promptController,
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
          // Prompt row (cwd removed per requirements)
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

class _WorkspacePanel extends StatefulWidget {
  final WorkbenchController controller;

  const _WorkspacePanel({required this.controller});

  @override
  State<_WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<_WorkspacePanel> {
  final Set<String> _expandedIds = {};
  bool _didAutoExpand = false;

  Future<void> _pickAndCreateWorkspace() async {
    final selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath == null) return;
    await widget.controller.createWorkspace(selectedPath);
    final newId = widget.controller.currentWorkspaceId;
    if (newId != null) {
      setState(() => _expandedIds.add(newId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    // Auto-expand the current workspace on first build so threads are visible.
    if (!_didAutoExpand && ctrl.currentWorkspaceId != null) {
      _expandedIds.add(ctrl.currentWorkspaceId!);
      _didAutoExpand = true;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── New Workspace button ──────────────────────────────────────────
        InkWell(
          onTap: _pickAndCreateWorkspace,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: const Color(0xFF1A1A1A),
            child: Row(
              children: [
                const Icon(Icons.create_new_folder_outlined, size: 14, color: Colors.white54),
                const SizedBox(width: 6),
                const Text(
                  'New Workspace',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2A)),
        // ── Workspace tree ────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: ctrl.workspaceList
                  .map((ws) => _buildWorkspaceGroup(ctrl, ws))
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspaceGroup(WorkbenchController ctrl, Workspace ws) {
    final isSelected = ctrl.currentWorkspaceId == ws.id;
    final isExpanded = _expandedIds.contains(ws.id);
    final threads = ctrl.workspaceThreads[ws.id] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Workspace row
        Container(
          color: isSelected
              ? Colors.blue.shade900.withAlpha(80)
              : Colors.transparent,
          child: Row(
            children: [
              // Arrow + folder + name (tap to expand/collapse; switch workspace only if different)
              Expanded(
                child: InkWell(
                  onTap: () async {
                    setState(() {
                      if (isExpanded) {
                        _expandedIds.remove(ws.id);
                      } else {
                        _expandedIds.add(ws.id);
                      }
                    });
                    // Only switch workspace if selecting a different one.
                    if (ctrl.currentWorkspaceId != ws.id) {
                      await ctrl.switchWorkspace(ws.id);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Row(
                      children: [
                        Icon(
                          isExpanded ? Icons.expand_more : Icons.chevron_right,
                          size: 14,
                          color: Colors.white54,
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          isExpanded ? Icons.folder_open : Icons.folder,
                          size: 14,
                          color: isSelected
                              ? Colors.blue.shade300
                              : Colors.white54,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            ws.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: isSelected
                                  ? Colors.blue.shade100
                                  : Colors.white70,
                              fontWeight: isSelected
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // + button
              InkWell(
                onTap: () async {
                  if (ctrl.currentWorkspaceId != ws.id) {
                    await ctrl.switchWorkspace(ws.id);
                  }
                  setState(() => _expandedIds.add(ws.id));
                  await ctrl.createWorkspaceThread();
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                  child: Icon(Icons.add, size: 13, color: Colors.white38),
                ),
              ),
              // Delete workspace (not for default)
              if (ws.id != 'default')
                InkWell(
                  onTap: () async {
                    await ctrl.removeWorkspace(ws.id);
                    setState(() => _expandedIds.remove(ws.id));
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(right: 6, top: 5, bottom: 5),
                    child: Icon(Icons.close, size: 12, color: Colors.white24),
                  ),
                ),
            ],
          ),
        ),
        // Thread items
        if (isExpanded)
          ...threads.map((t) => _buildThreadItem(ctrl, t, ws.id)),
      ],
    );
  }

  Widget _buildThreadItem(WorkbenchController ctrl, ThreadInfo thread, String workspaceId) {
    final isSelected = ctrl.currentThreadId == thread.id;
    final displayText = thread.title ??
        (thread.id.length > 8 ? '${thread.id.substring(0, 8)}…' : thread.id);
    final isTitle = thread.title != null;
    return GestureDetector(
      onTap: () async => await ctrl.resumeWorkspaceThread(thread.id),
      onLongPressStart: (details) {
        _showThreadMenu(context, details.globalPosition, ctrl, thread, workspaceId);
      },
      child: Container(
        color: isSelected
            ? Colors.amber.shade900.withAlpha(80)
            : Colors.transparent,
        padding: const EdgeInsets.only(left: 30, right: 8, top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 12,
              color: isSelected ? Colors.amber.shade200 : Colors.grey.shade600,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                displayText,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.amber.shade100 : Colors.grey,
                  fontFamily: isTitle ? null : 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showThreadMenu(
    BuildContext context,
    Offset position,
    WorkbenchController ctrl,
    ThreadInfo thread,
    String workspaceId,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      color: const Color(0xFF252525),
      items: [
        const PopupMenuItem(value: 'rename', child: Text('Rename', style: TextStyle(fontSize: 12))),
        const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
      ],
    ).then((value) {
      if (value == 'rename') {
        _showRenameDialog(context, ctrl, thread);
      } else if (value == 'delete') {
        ctrl.archiveThread(workspaceId, thread.id);
      }
    });
  }

  void _showRenameDialog(BuildContext context, WorkbenchController ctrl, ThreadInfo thread) {
    final textController = TextEditingController(text: thread.title ?? '');
    showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252525),
        title: const Text('Rename Thread', style: TextStyle(fontSize: 14)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Thread name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((newName) {
      if (newName != null && newName.isNotEmpty) {
        ctrl.renameThread(thread.id, newName);
      }
    });
  }
}
