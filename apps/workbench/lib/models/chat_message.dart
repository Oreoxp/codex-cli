// ---------------------------------------------------------------------------
// ToolType — matches CodexMonitor's toolType discriminant values
// Reference: docs/CODEX_MONITOR_REFERENCE.md §2.3
// ---------------------------------------------------------------------------

enum ToolType {
  commandExecution,
  fileChange,
  plan,
  mcpToolCall,
  webSearch,
  imageView,
  unknown;

  static ToolType fromString(String? s) {
    switch (s) {
      case 'commandExecution':
        return ToolType.commandExecution;
      case 'fileChange':
        return ToolType.fileChange;
      case 'plan':
        return ToolType.plan;
      case 'mcpToolCall':
        return ToolType.mcpToolCall;
      case 'webSearch':
        return ToolType.webSearch;
      case 'imageView':
        return ToolType.imageView;
      default:
        return ToolType.unknown;
    }
  }
}

// ---------------------------------------------------------------------------
// FileChange — one entry in a fileChange item's changes array
// Reference: docs/CODEX_MONITOR_REFERENCE.md §2.2
// ---------------------------------------------------------------------------

class FileChange {
  final String path;
  final String? kind; // "add" | "delete" | "modify" (or null)
  final String? diff;

  const FileChange({required this.path, this.kind, this.diff});

  /// Build from a raw protocol map (handles both camelCase and snake_case).
  factory FileChange.fromMap(Map<String, dynamic> m) {
    final path = m['path'] as String? ?? '';
    // kind may arrive as a plain string or as an object {type: "..."}
    final rawKind = m['kind'];
    final String? kind;
    if (rawKind is String) {
      kind = rawKind.toLowerCase().isEmpty ? null : rawKind.toLowerCase();
    } else if (rawKind is Map) {
      final t = rawKind['type'] as String?;
      kind = (t != null && t.isNotEmpty) ? t.toLowerCase() : null;
    } else {
      kind = null;
    }
    return FileChange(path: path, kind: kind, diff: m['diff'] as String?);
  }
}

// ---------------------------------------------------------------------------
// Block types
// ---------------------------------------------------------------------------

enum ToolStatus { running, success, error }

abstract class MessageBlock {}

class TextBlock extends MessageBlock {
  String text;
  TextBlock({required this.text});
}

class ReasoningBlock extends MessageBlock {
  String summary;
  String rawReasoning;
  Duration duration;
  bool isComplete;

  ReasoningBlock({
    this.summary = '',
    this.rawReasoning = '',
    this.duration = Duration.zero,
    this.isComplete = false,
  });
}

/// A single tool-call (commandExecution, fileChange, etc.) rendered as a
/// collapsible capsule in the chat view.
///
/// Field semantics (aligned with CodexMonitor ConversationItem):
///   [callId]    — item ID from the protocol, used for event routing.
///   [toolType]  — type discriminant (commandExecution, fileChange, …).
///   [title]     — primary human-readable label shown in the header,
///                 e.g. "Command: ls -la" or "File changes".
///   [detail]    — secondary context shown when expanded (cwd, file paths).
///   [output]    — accumulated live stdout / diff output.  Streaming deltas
///                 are appended via [ChatMessage.appendToolOutput]; on
///                 item/completed the server's aggregatedOutput may replace.
///   [status]    — running | success | error.
///   [durationMs]— execution time reported by item/completed.
///   [changes]   — for fileChange items, the list of per-file changes.
class ToolCallBlock extends MessageBlock {
  final String callId;
  final ToolType toolType;
  String title;
  String detail;
  String output;
  ToolStatus status;
  int? durationMs;
  List<FileChange> changes;

  ToolCallBlock({
    required this.callId,
    this.toolType = ToolType.unknown,
    this.title = '',
    this.detail = '',
    this.output = '',
    this.status = ToolStatus.running,
    this.durationMs,
    List<FileChange>? changes,
  }) : changes = changes ?? const [];

  // ── Backward-compat getters (UI layer reads these until redesigned) ────────

  /// Alias for [title] — legacy UI uses block.toolName for the header label.
  String get toolName => title;

  /// Alias for [detail] — legacy UI uses block.arguments for the input section.
  /// Shows cwd, file paths, or MCP args; NOT command stdout.
  String get arguments => detail;

  /// Alias for [output] — legacy UI uses block.result for the output section.
  String? get result => output.isNotEmpty ? output : null;
}

// ---------------------------------------------------------------------------
// ChatMessage
// ---------------------------------------------------------------------------

enum ChatRole { user, assistant }

class ChatMessage {
  final DateTime timestamp;
  final ChatRole role;

  /// Ordered list of content blocks that make up this message.
  final List<MessageBlock> blocks;

  ChatMessage({
    required this.timestamp,
    required this.role,
    String? text,
    List<MessageBlock>? blocks,
  }) : blocks = blocks ?? [if (text != null) TextBlock(text: text)];

  /// Concatenated plain-text content (backward-compatible).
  String get text =>
      blocks.whereType<TextBlock>().map((b) => b.text).join();

  ChatMessage copyWith({String? text}) => ChatMessage(
        timestamp: timestamp,
        role: role,
        blocks: text != null ? [TextBlock(text: text)] : List.of(blocks),
      );

  // ── Block helpers ──────────────────────────────────────────────────────────

  /// Append [text] to the last [TextBlock], or create a new one.
  void appendText(String text) {
    if (blocks.isNotEmpty && blocks.last is TextBlock) {
      (blocks.last as TextBlock).text += text;
    } else {
      blocks.add(TextBlock(text: text));
    }
  }

  /// Begin a new tool-call block.
  ///
  /// [callId] is the item ID used for subsequent event routing.
  /// [toolType], [title], and [detail] map to CodexMonitor's ConversationItem
  /// fields of the same names.
  void startToolCall(
    String callId, {
    ToolType toolType = ToolType.unknown,
    String title = '',
    String detail = '',
  }) {
    blocks.add(ToolCallBlock(
      callId: callId,
      toolType: toolType,
      title: title,
      detail: detail,
    ));
  }

  /// Append a streaming output delta to a running tool call.
  ///
  /// Called on item/commandExecution/outputDelta and
  /// item/fileChange/outputDelta events (field name: "delta", not "output").
  void appendToolOutput(String callId, String delta) {
    final block = _findToolCall(callId);
    if (block != null) block.output += delta;
  }

  /// Finalize a tool call on item/completed.
  ///
  /// If [aggregatedOutput] is non-null and non-empty, it replaces the
  /// streaming [output] accumulated so far (the server's authoritative value).
  /// [isError] should be true when the item status is "failed"/"error"/"declined".
  void finishToolCall(
    String callId, {
    String? aggregatedOutput,
    bool isError = false,
    int? durationMs,
    List<FileChange>? changes,
  }) {
    final block = _findToolCall(callId);
    if (block == null) return;
    if (aggregatedOutput != null && aggregatedOutput.isNotEmpty) {
      block.output = aggregatedOutput;
    }
    if (durationMs != null) block.durationMs = durationMs;
    if (changes != null) block.changes = changes;
    block.status = isError ? ToolStatus.error : ToolStatus.success;
  }

  ToolCallBlock? _findToolCall(String callId) {
    for (final b in blocks) {
      if (b is ToolCallBlock && b.callId == callId) return b;
    }
    return null;
  }

  /// Begin or return the current (in-progress) reasoning block.
  ReasoningBlock startReasoning() {
    if (blocks.isNotEmpty &&
        blocks.last is ReasoningBlock &&
        !(blocks.last as ReasoningBlock).isComplete) {
      return blocks.last as ReasoningBlock;
    }
    final rb = ReasoningBlock();
    blocks.add(rb);
    return rb;
  }
}
