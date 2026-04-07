import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../controllers/workbench_controller.dart';
import '../models/chat_message.dart';
import '../models/thread_state.dart';
import 'workbench_page.dart' show DiffView;

/// Chat-style message list with block-based rendering.
///
/// User messages render as right-aligned bubbles.
/// Assistant messages render blocks: TextBlock -> markdown, ToolCallBlock -> capsule.
/// Falls back to legacy ItemState timeline for backfilled messages without blocks.
class ChatView extends StatefulWidget {
  final WorkbenchController controller;

  const ChatView({super.key, required this.controller});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final msgs = ctrl.chatMessages;
    final messageItems = ctrl.messageItems;

    final List<Widget> children = [];

    for (int idx = 0; idx < msgs.length; idx++) {
      final msg = msgs[idx];
      if (msg.role == ChatRole.user) {
        children.add(_UserBubble(message: msg));
      } else {
        // Prefer block-based rendering if the message has blocks.
        final hasBlocks = msg.blocks.isNotEmpty;
        final isStreaming = ctrl.currentThreadState?.streamingMessage == msg;
        if (hasBlocks) {
          children.add(_AssistantBlockBubble(
            message: msg,
            isStreaming: isStreaming,
          ));
        } else {
          // Legacy fallback: ItemState timeline for backfilled messages.
          final timeline = messageItems[idx];
          children.add(_AssistantTimeline(
            items: timeline,
            fallbackText: msg.text,
            timestamp: msg.timestamp,
          ));
        }
      }
    }

    // Legacy: live timeline for in-progress turns without a streamingMessage.
    final showLegacyLive = ctrl.isInProgress &&
        ctrl.currentThreadState?.streamingMessage == null &&
        ctrl.items.isNotEmpty;
    if (showLegacyLive) {
      children.add(_AssistantTimeline(
        items: ctrl.items,
        isLive: true,
      ));
    }

    if (children.isEmpty && !ctrl.isInProgress) {
      return const Center(
        child: Text(
          'Send a prompt to get started.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: children.length,
      itemBuilder: (context, i) => children[i],
    );
  }
}

// ── User bubble ─────────────────────────────────────────────────────────────

class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final ts = _fmtTime(message.timestamp);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('You', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E4A8C),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: const Radius.circular(12),
                  bottomRight: const Radius.circular(2),
                ),
              ),
              child: SelectableText(
                message.text,
                style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(ts, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}

// ── Block-based assistant bubble ────────────────────────────────────────────

class _AssistantBlockBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isStreaming;

  const _AssistantBlockBubble({
    required this.message,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final ts = _fmtTime(message.timestamp);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar + label row.
          Row(
            children: [
              const CircleAvatar(
                radius: 10,
                backgroundColor: Color(0xFF444444),
                child: Icon(Icons.smart_toy, size: 12, color: Colors.white60),
              ),
              const SizedBox(width: 6),
              Text('Assistant',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              if (isStreaming) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 10, height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          // Render each block.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final block in message.blocks)
                  _buildBlock(block),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(ts, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(MessageBlock block) {
    if (block is TextBlock) {
      return _TextBlockWidget(block: block);
    } else if (block is ToolCallBlock) {
      return _ToolCallBlockWidget(block: block);
    } else if (block is ReasoningBlock) {
      return _ReasoningBlockWidget(block: block);
    }
    return const SizedBox.shrink();
  }
}

// ── TextBlock renderer ──────────────────────────────────────────────────────

class _TextBlockWidget extends StatelessWidget {
  final TextBlock block;
  const _TextBlockWidget({required this.block});

  @override
  Widget build(BuildContext context) {
    if (block.text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
      child: GptMarkdown(
        block.text,
        style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5),
      ),
    );
  }
}

// ── ReasoningBlock renderer ─────────────────────────────────────────────────

class _ReasoningBlockWidget extends StatefulWidget {
  final ReasoningBlock block;
  const _ReasoningBlockWidget({required this.block});

  @override
  State<_ReasoningBlockWidget> createState() => _ReasoningBlockWidgetState();
}

class _ReasoningBlockWidgetState extends State<_ReasoningBlockWidget> {
  bool? _manualExpanded;
  bool _rawExpanded = false;

  bool get _expanded => _manualExpanded ?? !widget.block.isComplete;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final seconds = block.duration.inSeconds;
    final label = block.isComplete ? 'Thought for ${seconds}s' : 'Thinking...';
    final hasSummary = block.summary.isNotEmpty;
    final hasRaw = block.rawReasoning.isNotEmpty;

    if (!hasSummary && !hasRaw) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!block.isComplete)
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 14,
                  color: const Color(0xFF888888),
                ),
              ],
            ),
          ),
          if (_expanded && hasSummary)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GptMarkdown(
                    block.summary,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF777777),
                      height: 1.5,
                    ),
                  ),
                  if (hasRaw) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => setState(() => _rawExpanded = !_rawExpanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Raw reasoning',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF666666),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            _rawExpanded ? Icons.expand_less : Icons.chevron_right,
                            size: 12,
                            color: const Color(0xFF666666),
                          ),
                        ],
                      ),
                    ),
                    if (_rawExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: GptMarkdown(
                          block.rawReasoning,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF555555),
                            height: 1.4,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          // If only raw reasoning exists (no summary), show it directly.
          if (_expanded && !hasSummary && hasRaw)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(6),
              ),
              child: GptMarkdown(
                block.rawReasoning,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF777777),
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── ToolCallBlock renderer (capsule) ────────────────────────────────────────

class _ToolCallBlockWidget extends StatefulWidget {
  final ToolCallBlock block;
  const _ToolCallBlockWidget({required this.block});

  @override
  State<_ToolCallBlockWidget> createState() => _ToolCallBlockWidgetState();
}

class _ToolCallBlockWidgetState extends State<_ToolCallBlockWidget> {
  bool? _manualExpanded;

  bool get _defaultExpanded =>
      widget.block.status != ToolStatus.success;

  bool get _expanded => _manualExpanded ?? _defaultExpanded;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final hasContent = block.arguments.isNotEmpty ||
        (block.result != null && block.result!.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _borderColor(block.status),
            width: 0.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // Header (always visible).
            InkWell(
              onTap: hasContent ? () => setState(() => _manualExpanded = !_expanded) : null,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    _statusIcon(block.status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusLabel(block.status, block.toolName),
                        style: TextStyle(
                          fontSize: 12,
                          color: _labelColor(block.status),
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasContent)
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: Colors.white24,
                      ),
                  ],
                ),
              ),
            ),
            // Expandable body.
            if (_expanded && hasContent)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (block.arguments.isNotEmpty) ...[
                        SelectableText(
                          block.arguments,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white54,
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (block.result != null && block.result!.isNotEmpty) ...[
                        if (block.arguments.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: Divider(height: 1, color: Colors.white10),
                          ),
                        SelectableText(
                          block.result!,
                          style: TextStyle(
                            fontSize: 11,
                            color: block.status == ToolStatus.error
                                ? const Color(0xFFFF6B6B)
                                : const Color(0xFF88CC88),
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(ToolStatus status) {
    switch (status) {
      case ToolStatus.running:
        return const CupertinoActivityIndicator(radius: 7);
      case ToolStatus.success:
        return const Text('\u2705', style: TextStyle(fontSize: 13));
      case ToolStatus.error:
        return const Text('\u274C', style: TextStyle(fontSize: 13));
    }
  }

  String _statusLabel(ToolStatus status, String toolName) {
    switch (status) {
      case ToolStatus.running:
        return '[\u6267\u884C\u4E2D] $toolName';
      case ToolStatus.success:
        return '[\u5B8C\u6210] $toolName';
      case ToolStatus.error:
        return '[\u5931\u8D25] $toolName';
    }
  }

  Color _labelColor(ToolStatus status) {
    switch (status) {
      case ToolStatus.running:
        return const Color(0xFFAAAADD);
      case ToolStatus.success:
        return const Color(0xFF88AA88);
      case ToolStatus.error:
        return const Color(0xFFFF6B6B);
    }
  }

  Color _borderColor(ToolStatus status) {
    switch (status) {
      case ToolStatus.running:
        return const Color(0xFF333355);
      case ToolStatus.success:
        return const Color(0xFF2A3A2A);
      case ToolStatus.error:
        return const Color(0xFF4A2222);
    }
  }
}

// ── Legacy: ItemState-based assistant timeline ─────────────────────────────

class _AssistantTimeline extends StatelessWidget {
  final List<ItemState>? items;
  final String? fallbackText;
  final DateTime? timestamp;
  final bool isLive;

  const _AssistantTimeline({
    this.items,
    this.fallbackText,
    this.timestamp,
    this.isLive = false,
  });

  @override
  Widget build(BuildContext context) {
    final ts = timestamp != null ? _fmtTime(timestamp!) : null;
    final hasItems = items != null && items!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(
                radius: 10,
                backgroundColor: Color(0xFF444444),
                child: Icon(Icons.smart_toy, size: 12, color: Colors.white60),
              ),
              const SizedBox(width: 6),
              Text('Assistant',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              if (isLive) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 10, height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (hasItems)
            ...items!.map((item) => _buildItemRow(item))
          else if (fallbackText != null && fallbackText!.isNotEmpty)
            _buildPlainText(fallbackText!),
          if (ts != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(ts, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  Widget _buildItemRow(ItemState item) {
    switch (item.type) {
      case 'reasoning':
        return _ItemReasoningRow(item: item);
      case 'commandExecution':
        return _ItemCommandRow(item: item);
      case 'fileChange':
        return _ItemFileChangeRow(item: item);
      case 'agentMessage':
        return _ItemTextRow(item: item);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPlainText(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: GptMarkdown(
          text,
          style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5),
        ),
      ),
    );
  }
}

// ── Legacy item rows ───────────────────────────────────────────────────────

class _ItemReasoningRow extends StatefulWidget {
  final ItemState item;
  const _ItemReasoningRow({required this.item});

  @override
  State<_ItemReasoningRow> createState() => _ItemReasoningRowState();
}

class _ItemReasoningRowState extends State<_ItemReasoningRow> {
  bool? _manualExpanded;
  bool _rawExpanded = false;

  bool get _isComplete => widget.item.status == 'completed';
  bool get _expanded => _manualExpanded ?? !_isComplete;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final seconds = item.duration.inSeconds;
    final label = _isComplete ? 'Thought for ${seconds}s' : 'Thinking...';
    final hasRaw = item.rawReasoning.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isComplete)
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF888888),
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 14,
                  color: const Color(0xFF888888),
                ),
              ],
            ),
          ),
          if (_expanded && item.content.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GptMarkdown(
                    item.content,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF777777),
                      height: 1.5,
                    ),
                  ),
                  if (hasRaw) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => setState(() => _rawExpanded = !_rawExpanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Raw reasoning',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF666666),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            _rawExpanded ? Icons.expand_less : Icons.chevron_right,
                            size: 12,
                            color: const Color(0xFF666666),
                          ),
                        ],
                      ),
                    ),
                    if (_rawExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: GptMarkdown(
                          item.rawReasoning,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF555555),
                            height: 1.4,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          if (_expanded && item.content.isEmpty && hasRaw)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(6),
              ),
              child: GptMarkdown(
                item.rawReasoning,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF777777),
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemCommandRow extends StatefulWidget {
  final ItemState item;
  const _ItemCommandRow({required this.item});

  @override
  State<_ItemCommandRow> createState() => _ItemCommandRowState();
}

class _ItemCommandRowState extends State<_ItemCommandRow> {
  bool? _manualExpanded;

  bool get _isComplete => widget.item.status == 'completed' ||
      widget.item.status == 'failed' ||
      widget.item.status == 'declined';
  bool get _expanded => _manualExpanded ?? !_isComplete;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cmdStr = item.command?.join(' ') ?? 'command';
    final seconds = item.duration.inSeconds;
    final label = _isComplete ? 'Ran for ${seconds}s' : 'Running...';
    final output = item.content;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.terminal,
                  size: 13,
                  color: const Color(0xFF88AA88),
                ),
                const SizedBox(width: 5),
                if (!_isComplete)
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                Flexible(
                  child: Text(
                    '$label  $cmdStr',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF88AA88),
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 14,
                  color: const Color(0xFF88AA88),
                ),
              ],
            ),
          ),
          if (_expanded && output.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                output,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white54,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemFileChangeRow extends StatefulWidget {
  final ItemState item;
  const _ItemFileChangeRow({required this.item});

  @override
  State<_ItemFileChangeRow> createState() => _ItemFileChangeRowState();
}

class _ItemFileChangeRowState extends State<_ItemFileChangeRow> {
  bool? _manualExpanded;

  bool get _isComplete => widget.item.status == 'completed' ||
      widget.item.status == 'failed' ||
      widget.item.status == 'declined';
  bool get _expanded => _manualExpanded ?? !_isComplete;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final changes = item.fileChanges ?? [];
    final paths = changes
        .map((c) => c['path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();
    final pathSummary = paths.isNotEmpty
        ? paths.join(', ')
        : 'file change';
    final output = item.content;
    final statusLabel = item.status == 'declined'
        ? 'Declined'
        : item.status == 'failed'
            ? 'Failed'
            : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.edit_note,
                  size: 14,
                  color: const Color(0xFF8888CC),
                ),
                const SizedBox(width: 5),
                if (!_isComplete)
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                Flexible(
                  child: Text(
                    statusLabel != null
                        ? '$statusLabel  $pathSummary'
                        : pathSummary,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8888CC),
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded ? Icons.expand_less : Icons.chevron_right,
                  size: 14,
                  color: const Color(0xFF8888CC),
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            for (final change in changes)
              if ((change['diff'] as String? ?? '').isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4, bottom: 2),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D1A),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${change['kind'] ?? 'edit'}: ${change['path'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9999CC),
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      DiffView(diff: change['diff'] as String),
                    ],
                  ),
                ),
            if (output.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D1A),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  output,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white54,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ItemTextRow extends StatelessWidget {
  final ItemState item;
  const _ItemTextRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final text = item.content;
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: GptMarkdown(
          text,
          style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.5),
        ),
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

String _fmtTime(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}:'
    '${dt.second.toString().padLeft(2, '0')}';
