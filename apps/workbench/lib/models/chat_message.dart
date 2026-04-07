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

class ToolCallBlock extends MessageBlock {
  final String callId;
  final String toolName;
  String arguments;
  String? result;
  ToolStatus status;

  ToolCallBlock({
    required this.callId,
    required this.toolName,
    this.arguments = '',
    this.result,
    this.status = ToolStatus.running,
  });
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

  /// Concatenated plain-text content (backward-compatible with old `.text`).
  String get text =>
      blocks.whereType<TextBlock>().map((b) => b.text).join();

  ChatMessage copyWith({String? text}) => ChatMessage(
        timestamp: timestamp,
        role: role,
        blocks: text != null ? [TextBlock(text: text)] : List.of(blocks),
      );

  // -------------------------------------------------------------------------
  // Block helpers
  // -------------------------------------------------------------------------

  /// Append [text] to the last [TextBlock], or create a new one.
  void appendText(String text) {
    if (blocks.isNotEmpty && blocks.last is TextBlock) {
      (blocks.last as TextBlock).text += text;
    } else {
      blocks.add(TextBlock(text: text));
    }
  }

  /// Begin a new tool-call block.
  void startToolCall(String callId, String toolName) {
    blocks.add(ToolCallBlock(callId: callId, toolName: toolName));
  }

  /// Append an argument chunk to an in-flight tool call.
  void updateToolCallArgs(String callId, String argChunk) {
    final block = _findToolCall(callId);
    if (block != null) block.arguments += argChunk;
  }

  /// Mark a tool call as finished with an optional result.
  void finishToolCall(String callId, String? result, {bool isError = false}) {
    final block = _findToolCall(callId);
    if (block == null) return;
    block.result = result;
    block.status = isError ? ToolStatus.error : ToolStatus.success;
  }

  ToolCallBlock? _findToolCall(String callId) {
    for (final b in blocks) {
      if (b is ToolCallBlock && b.callId == callId) return b;
    }
    return null;
  }

  /// Begin or return the current reasoning block.
  ReasoningBlock startReasoning() {
    // Reuse existing in-progress reasoning block at the tail.
    if (blocks.isNotEmpty && blocks.last is ReasoningBlock && !(blocks.last as ReasoningBlock).isComplete) {
      return blocks.last as ReasoningBlock;
    }
    final rb = ReasoningBlock();
    blocks.add(rb);
    return rb;
  }
}
