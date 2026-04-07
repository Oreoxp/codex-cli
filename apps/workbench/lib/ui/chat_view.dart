import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../controllers/workbench_controller.dart';
import '../models/chat_message.dart';
import '../models/thread_state.dart';
import 'workbench_page.dart' show DiffView;

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens — derived from CodexMonitor themes.dark.css & messages.css
// ─────────────────────────────────────────────────────────────────────────────

const _kFontMono = 'monospace';

// Surfaces
const _kSurfaceUserBubble = Color(0xFF0D2040);     // user bubble (blue-tinted)
const _kSurfaceAssistBubble = Color(0xFF14161F);   // assistant bubble
const _kSurfaceTerminal  = Color(0xFF0A0C12);      // terminal / command output
const _kSurfaceReasoning = Color(0xFF111318);      // reasoning block bg

// Borders
const _kBorderSoft    = Color(0xFF1A1D28);   // tool capsule default
const _kBorderRunning = Color(0xFF2C2C55);   // running state — subtle blue
const _kBorderSuccess = Color(0xFF1A3028);   // success state — subtle green
const _kBorderError   = Color(0xFF3A1A1A);   // error state — subtle red
const _kBorderTerminal = Color(0xFF1E2030);  // terminal panel border
const _kBorderUser    = Color(0xFF1A3A5C);   // user bubble border

// Status accent colors (from themes.dark.css --status-*)
const _kColorSuccess = Color(0xFF78EBB5);   // rgba(120,235,190,0.95) approx
const _kColorRunning = Color(0xFFFFAF55);   // rgba(255,175,85,0.95) approx
const _kColorError   = Color(0xFFFF6B6B);   // rgba(255,110,110,0.95)

// Text
const _kTextStrong  = Color(0xFFD9DCE8);    // primary body text (85% white)
const _kTextMuted   = Color(0xFFAAAFC0);    // secondary / muted (70%)
const _kTextSubtle  = Color(0xFF787E96);    // labels, timestamps (60%)
const _kTextFaint   = Color(0xFF525870);    // very quiet text (50%)
const _kTextCmd     = Color(0xFFBBBFCC);    // monospace command text (75%)

/// Chat-style message list with block-based rendering.
///
/// User messages render as right-aligned bubbles.
/// Assistant messages render blocks: TextBlock → markdown, ToolCallBlock → capsule.
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
        final hasBlocks = msg.blocks.isNotEmpty;
        final isStreaming = ctrl.currentThreadState?.streamingMessage == msg;
        if (hasBlocks) {
          children.add(_AssistantBlockBubble(
            message: msg,
            isStreaming: isStreaming,
          ));
        } else {
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
      children.add(_AssistantTimeline(items: ctrl.items, isLive: true));
    }

    if (children.isEmpty && !ctrl.isInProgress) {
      return const Center(
        child: Text(
          'Send a prompt to get started.',
          style: TextStyle(fontSize: 13, color: _kTextFaint),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: children.length,
      itemBuilder: (context, i) => children[i],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// User bubble
// ─────────────────────────────────────────────────────────────────────────────

class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final ts = _fmtTime(message.timestamp);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _kSurfaceUserBubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
                border: Border.all(color: _kBorderUser, width: 1),
              ),
              child: SelectableText(
                message.text,
                style: const TextStyle(
                  fontSize: 14,
                  color: _kTextStrong,
                  height: 1.55,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(ts, style: const TextStyle(fontSize: 10, color: _kTextFaint)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Block-based assistant bubble
// ─────────────────────────────────────────────────────────────────────────────

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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: avatar + name + streaming indicator.
          Row(
            children: [
              _AgentAvatar(isStreaming: isStreaming),
              const SizedBox(width: 8),
              const Text(
                'Assistant',
                style: TextStyle(fontSize: 11, color: _kTextSubtle),
              ),
              if (isStreaming) ...[
                const SizedBox(width: 8),
                const _WorkingDot(),
              ],
            ],
          ),
          const SizedBox(height: 6),

          // Render blocks in order.
          for (final block in message.blocks) ...[
            _buildBlock(block),
          ],

          const SizedBox(height: 3),
          Text(ts, style: const TextStyle(fontSize: 10, color: _kTextFaint)),
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

// ─────────────────────────────────────────────────────────────────────────────
// TextBlock renderer — markdown in a subtle bubble
// ─────────────────────────────────────────────────────────────────────────────

class _TextBlockWidget extends StatelessWidget {
  final TextBlock block;
  const _TextBlockWidget({required this.block});

  @override
  Widget build(BuildContext context) {
    if (block.text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 720),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _kSurfaceAssistBubble,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kBorderSoft, width: 1),
      ),
      child: GptMarkdown(
        block.text,
        style: const TextStyle(
          fontSize: 14,
          color: _kTextStrong,
          height: 1.55,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ReasoningBlock renderer
// ─────────────────────────────────────────────────────────────────────────────

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
    final label = block.isComplete ? 'Thought for ${seconds}s' : 'Thinking…';
    final hasSummary = block.summary.isNotEmpty;
    final hasRaw = block.rawReasoning.isNotEmpty;

    if (!hasSummary && !hasRaw) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Clickable header pill.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _kSurfaceReasoning,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _kBorderSoft, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!block.isComplete)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: CupertinoActivityIndicator(radius: 5),
                    ),
                  Icon(
                    Icons.psychology_outlined,
                    size: 12,
                    color: _kTextSubtle,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: _kTextSubtle,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.chevron_right,
                    size: 13,
                    color: _kTextFaint,
                  ),
                ],
              ),
            ),
          ),

          if (_expanded && hasSummary)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6, bottom: 2),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kSurfaceReasoning,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kBorderSoft, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GptMarkdown(
                    block.summary,
                    style: const TextStyle(
                      fontSize: 12,
                      color: _kTextSubtle,
                      height: 1.5,
                    ),
                  ),
                  if (hasRaw) ...[
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => setState(() => _rawExpanded = !_rawExpanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Raw reasoning',
                            style: const TextStyle(fontSize: 11, color: _kTextFaint, fontStyle: FontStyle.italic),
                          ),
                          const SizedBox(width: 3),
                          Icon(_rawExpanded ? Icons.expand_less : Icons.chevron_right, size: 12, color: _kTextFaint),
                        ],
                      ),
                    ),
                    if (_rawExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GptMarkdown(
                          block.rawReasoning,
                          style: const TextStyle(fontSize: 11, color: _kTextFaint, height: 1.4),
                        ),
                      ),
                  ],
                ],
              ),
            ),

          if (_expanded && !hasSummary && hasRaw)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6, bottom: 2),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kSurfaceReasoning,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kBorderSoft, width: 1),
              ),
              child: GptMarkdown(
                block.rawReasoning,
                style: const TextStyle(fontSize: 12, color: _kTextSubtle, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ToolCallBlock renderer — CodexMonitor-style collapsible capsule
//
// Visual spec (CodexMonitor messages.css + MessageRows.tsx):
//   • Collapsed: icon + title line + status badge — no output visible
//   • Expanded:  + detail section (cwd / file paths)
//                + terminal panel (command stdout / diff output)
//   • Default expanded: only while status == running
//   • Status icons: spinner (running) | ✓ (success) | ✗ (error)
//   • Border color changes by status
// ─────────────────────────────────────────────────────────────────────────────

class _ToolCallBlockWidget extends StatefulWidget {
  final ToolCallBlock block;
  const _ToolCallBlockWidget({required this.block});

  @override
  State<_ToolCallBlockWidget> createState() => _ToolCallBlockWidgetState();
}

class _ToolCallBlockWidgetState extends State<_ToolCallBlockWidget> {
  bool? _manualExpanded;

  // Default: expanded while running, collapsed once done.
  bool get _defaultExpanded => widget.block.status == ToolStatus.running;
  bool get _expanded => _manualExpanded ?? _defaultExpanded;

  ToolCallBlock get block => widget.block;

  @override
  Widget build(BuildContext context) {
    final hasDetail = block.detail.isNotEmpty;
    final hasOutput = block.output.isNotEmpty;
    final hasChanges = block.changes.isNotEmpty;
    final hasExpandableContent = hasDetail || hasOutput || hasChanges;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Container(
        decoration: BoxDecoration(
          color: _kSurfaceTerminal,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _borderColor(), width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header row (always visible) ──────────────────────────────
            _buildHeader(hasExpandableContent),

            // ── Expandable body ──────────────────────────────────────────
            if (_expanded && hasExpandableContent)
              _buildBody(hasDetail, hasOutput, hasChanges),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool tappable) {
    final durationLabel = _durationLabel();
    return InkWell(
      onTap: tappable ? () => setState(() => _manualExpanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(14),
      highlightColor: Colors.white.withValues(alpha: 0.04),
      splashColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Status icon.
            _StatusIcon(status: block.status),
            const SizedBox(width: 10),

            // Tool icon.
            _ToolIcon(toolType: block.toolType, status: block.status),
            const SizedBox(width: 7),

            // Title — command text, file paths, etc.
            Expanded(
              child: Text(
                block.title,
                style: TextStyle(
                  fontSize: 12,
                  color: _titleColor(),
                  fontFamily: block.toolType == ToolType.commandExecution
                      ? _kFontMono
                      : null,
                  height: 1.3,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),

            // Duration badge (only when complete).
            if (durationLabel != null) ...[
              const SizedBox(width: 8),
              Text(
                durationLabel,
                style: const TextStyle(fontSize: 10, color: _kTextFaint),
              ),
            ],

            // Chevron.
            if (tappable) ...[
              const SizedBox(width: 6),
              Icon(
                _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 15,
                color: _kTextFaint,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool hasDetail, bool hasOutput, bool hasChanges) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _kBorderTerminal, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Detail section: cwd or file path summary ─────────────────
          if (hasDetail)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                block.detail,
                style: const TextStyle(
                  fontSize: 11,
                  color: _kTextMuted,
                  fontFamily: _kFontMono,
                  height: 1.4,
                ),
              ),
            ),

          // ── File changes list ─────────────────────────────────────────
          if (hasChanges)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final change in block.changes)
                    _FileChangeTile(change: change),
                ],
              ),
            ),

          // ── Terminal output panel ─────────────────────────────────────
          if (hasOutput)
            _TerminalPanel(
              output: block.output,
              isError: block.status == ToolStatus.error,
            ),

          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Color _borderColor() {
    switch (block.status) {
      case ToolStatus.running:
        return _kBorderRunning;
      case ToolStatus.success:
        return _kBorderSuccess;
      case ToolStatus.error:
        return _kBorderError;
    }
  }

  Color _titleColor() {
    switch (block.status) {
      case ToolStatus.running:
        return _kColorRunning.withValues(alpha: 0.9);
      case ToolStatus.success:
        return _kTextCmd;
      case ToolStatus.error:
        return _kColorError.withValues(alpha: 0.9);
    }
  }

  String? _durationLabel() {
    final ms = block.durationMs;
    if (ms == null || block.status == ToolStatus.running) return null;
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status icon: spinner | ✓ | ✗
// ─────────────────────────────────────────────────────────────────────────────

class _StatusIcon extends StatelessWidget {
  final ToolStatus status;
  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case ToolStatus.running:
        return const CupertinoActivityIndicator(
          radius: 6,
          color: _kColorRunning,
        );
      case ToolStatus.success:
        return const Icon(Icons.check_circle_outline_rounded,
            size: 14, color: _kColorSuccess);
      case ToolStatus.error:
        return const Icon(Icons.cancel_outlined,
            size: 14, color: _kColorError);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool-type icon (matches CodexMonitor's toolIconForSummary logic)
// ─────────────────────────────────────────────────────────────────────────────

class _ToolIcon extends StatelessWidget {
  final ToolType toolType;
  final ToolStatus status;
  const _ToolIcon({required this.toolType, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _iconColor();
    switch (toolType) {
      case ToolType.commandExecution:
        return Icon(Icons.terminal_rounded, size: 13, color: color);
      case ToolType.fileChange:
        return Icon(Icons.edit_document, size: 13, color: color);
      case ToolType.plan:
        return Icon(Icons.format_list_bulleted_rounded, size: 13, color: color);
      case ToolType.mcpToolCall:
        return Icon(Icons.build_circle_outlined, size: 13, color: color);
      case ToolType.webSearch:
        return Icon(Icons.travel_explore_rounded, size: 13, color: color);
      case ToolType.imageView:
        return Icon(Icons.image_outlined, size: 13, color: color);
      case ToolType.unknown:
        return Icon(Icons.handyman_outlined, size: 13, color: color);
    }
  }

  Color _iconColor() {
    switch (status) {
      case ToolStatus.running:
        return _kColorRunning.withValues(alpha: 0.8);
      case ToolStatus.success:
        return _kTextSubtle;
      case ToolStatus.error:
        return _kColorError.withValues(alpha: 0.7);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal output panel (scrollable, max ~8 lines visible)
// ─────────────────────────────────────────────────────────────────────────────

class _TerminalPanel extends StatelessWidget {
  final String output;
  final bool isError;
  const _TerminalPanel({required this.output, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final textColor = isError ? _kColorError.withValues(alpha: 0.85) : _kTextCmd;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      constraints: const BoxConstraints(maxHeight: 180), // ~8 lines @ 1.28 lh
      decoration: BoxDecoration(
        color: _kSurfaceTerminal,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorderTerminal, width: 1),
      ),
      child: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: SelectableText(
            output,
            style: TextStyle(
              fontSize: 11,
              color: textColor,
              fontFamily: _kFontMono,
              height: 1.28,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// File change tile — shows path + kind badge + inline diff
// ─────────────────────────────────────────────────────────────────────────────

class _FileChangeTile extends StatefulWidget {
  final FileChange change;
  const _FileChangeTile({required this.change});

  @override
  State<_FileChangeTile> createState() => _FileChangeTileState();
}

class _FileChangeTileState extends State<_FileChangeTile> {
  bool _diffExpanded = false;

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final hasDiff = (change.diff ?? '').isNotEmpty;
    final kindLabel = _kindLabel(change.kind);
    final kindColor = _kindColor(change.kind);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasDiff ? () => setState(() => _diffExpanded = !_diffExpanded) : null,
            child: Row(
              children: [
                // Kind badge (A / M / D).
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: kindColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    kindLabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: kindColor,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.05,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _basename(change.path),
                    style: const TextStyle(
                      fontSize: 11,
                      color: _kTextMuted,
                      fontFamily: _kFontMono,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasDiff)
                  Icon(
                    _diffExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: _kTextFaint,
                  ),
              ],
            ),
          ),
          if (_diffExpanded && hasDiff)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: DiffView(diff: change.diff!),
            ),
        ],
      ),
    );
  }

  String _kindLabel(String? kind) {
    switch (kind) {
      case 'add':
        return 'A';
      case 'delete':
        return 'D';
      default:
        return 'M';
    }
  }

  Color _kindColor(String? kind) {
    switch (kind) {
      case 'add':
        return _kColorSuccess;
      case 'delete':
        return _kColorError;
      default:
        return _kColorRunning;
    }
  }

  String _basename(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent avatar widget
// ─────────────────────────────────────────────────────────────────────────────

class _AgentAvatar extends StatelessWidget {
  final bool isStreaming;
  const _AgentAvatar({this.isStreaming = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2030),
        shape: BoxShape.circle,
        border: Border.all(color: _kBorderSoft, width: 1),
      ),
      child: Center(
        child: isStreaming
            ? const CupertinoActivityIndicator(radius: 5, color: _kColorRunning)
            : const Icon(Icons.auto_awesome, size: 12, color: _kTextSubtle),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Working dot — pulsing indicator shown in assistant header while streaming
// ─────────────────────────────────────────────────────────────────────────────

class _WorkingDot extends StatefulWidget {
  const _WorkingDot();

  @override
  State<_WorkingDot> createState() => _WorkingDotState();
}

class _WorkingDotState extends State<_WorkingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _opacity = Tween(begin: 0.3, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: _kColorRunning,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Legacy: ItemState-based assistant timeline (backfill fallback)
// ─────────────────────────────────────────────────────────────────────────────

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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _AgentAvatar(isStreaming: isLive),
              const SizedBox(width: 8),
              const Text('Assistant',
                  style: TextStyle(fontSize: 11, color: _kTextSubtle)),
              if (isLive) ...[
                const SizedBox(width: 8),
                const _WorkingDot(),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (hasItems)
            ...items!.map((item) => _buildItemRow(item))
          else if (fallbackText != null && fallbackText!.isNotEmpty)
            _buildPlainText(fallbackText!),
          if (ts != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(ts, style: const TextStyle(fontSize: 10, color: _kTextFaint)),
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
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _kSurfaceAssistBubble,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kBorderSoft, width: 1),
      ),
      child: GptMarkdown(
        text,
        style: const TextStyle(fontSize: 14, color: _kTextStrong, height: 1.55),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Legacy item rows (used for backfilled messages)
// ─────────────────────────────────────────────────────────────────────────────

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
    final label = _isComplete ? 'Thought for ${seconds}s' : 'Thinking…';
    final hasRaw = item.rawReasoning.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _manualExpanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _kSurfaceReasoning,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _kBorderSoft, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isComplete)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: CupertinoActivityIndicator(radius: 5),
                    ),
                  const Icon(Icons.psychology_outlined, size: 12, color: _kTextSubtle),
                  const SizedBox(width: 5),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11, color: _kTextSubtle, fontStyle: FontStyle.italic)),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.chevron_right,
                      size: 13, color: _kTextFaint),
                ],
              ),
            ),
          ),
          if (_expanded && item.content.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kSurfaceReasoning,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kBorderSoft, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GptMarkdown(item.content,
                      style: const TextStyle(fontSize: 12, color: _kTextSubtle, height: 1.5)),
                  if (hasRaw) ...[
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => setState(() => _rawExpanded = !_rawExpanded),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Raw reasoning',
                              style: TextStyle(fontSize: 11, color: _kTextFaint, fontStyle: FontStyle.italic)),
                          const SizedBox(width: 3),
                          Icon(_rawExpanded ? Icons.expand_less : Icons.chevron_right,
                              size: 12, color: _kTextFaint),
                        ],
                      ),
                    ),
                    if (_rawExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GptMarkdown(item.rawReasoning,
                            style: const TextStyle(fontSize: 11, color: _kTextFaint, height: 1.4)),
                      ),
                  ],
                ],
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

  bool get _isComplete =>
      widget.item.status == 'completed' ||
      widget.item.status == 'failed' ||
      widget.item.status == 'declined';
  bool get _expanded => _manualExpanded ?? !_isComplete;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cmdStr = item.command?.join(' ') ?? 'command';
    final seconds = item.duration.inSeconds;
    final output = item.content;
    final isError = item.status == 'failed' || item.status == 'declined';

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Container(
        decoration: BoxDecoration(
          color: _kSurfaceTerminal,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isComplete
                ? (isError ? _kBorderError : _kBorderSuccess)
                : _kBorderRunning,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _manualExpanded = !_expanded),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    _isComplete
                        ? Icon(
                            isError ? Icons.cancel_outlined : Icons.check_circle_outline_rounded,
                            size: 14,
                            color: isError ? _kColorError : _kColorSuccess,
                          )
                        : const CupertinoActivityIndicator(radius: 6, color: _kColorRunning),
                    const SizedBox(width: 10),
                    const Icon(Icons.terminal_rounded, size: 13, color: _kTextSubtle),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        cmdStr,
                        style: const TextStyle(
                          fontSize: 12,
                          color: _kTextCmd,
                          fontFamily: _kFontMono,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_isComplete)
                      Text(
                        '${seconds}s',
                        style: const TextStyle(fontSize: 10, color: _kTextFaint),
                      ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 15,
                      color: _kTextFaint,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && output.isNotEmpty)
              Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _kBorderTerminal, width: 1)),
                ),
                child: _TerminalPanel(output: output, isError: isError),
              ),
            if (_expanded && output.isNotEmpty) const SizedBox(height: 4),
          ],
        ),
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

  bool get _isComplete =>
      widget.item.status == 'completed' ||
      widget.item.status == 'failed' ||
      widget.item.status == 'declined';
  bool get _expanded => _manualExpanded ?? !_isComplete;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final changes = item.fileChanges ?? [];
    final pathSummary = changes
            .map((c) => c['path'] as String? ?? '')
            .where((p) => p.isNotEmpty)
            .join(', ')
        .let((s) => s.isNotEmpty ? s : 'file change');
    final isError = item.status == 'failed' || item.status == 'declined';

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Container(
        decoration: BoxDecoration(
          color: _kSurfaceTerminal,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _isComplete
                ? (isError ? _kBorderError : _kBorderSuccess)
                : _kBorderRunning,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _manualExpanded = !_expanded),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    _isComplete
                        ? Icon(
                            isError ? Icons.cancel_outlined : Icons.check_circle_outline_rounded,
                            size: 14,
                            color: isError ? _kColorError : _kColorSuccess,
                          )
                        : const CupertinoActivityIndicator(radius: 6, color: _kColorRunning),
                    const SizedBox(width: 10),
                    const Icon(Icons.edit_document, size: 13, color: _kTextSubtle),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        pathSummary,
                        style: const TextStyle(fontSize: 12, color: _kTextMuted, fontFamily: _kFontMono),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 15, color: _kTextFaint,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && changes.isNotEmpty) ...[
              Container(
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _kBorderTerminal, width: 1)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final change in changes)
                      _FileChangeTile(
                        change: FileChange.fromMap(change),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
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
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _kSurfaceAssistBubble,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kBorderSoft, width: 1),
      ),
      child: GptMarkdown(
        text,
        style: const TextStyle(fontSize: 14, color: _kTextStrong, height: 1.55),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _fmtTime(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}:'
    '${dt.second.toString().padLeft(2, '0')}';

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}
