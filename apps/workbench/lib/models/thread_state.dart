import '../models/chat_message.dart';
import '../models/protocol.dart';

/// Minimal state for a single item within a turn.
class ItemState {
  final String id;
  final String type;
  String status; // started | completed
  final StringBuffer buffer = StringBuffer();
  final DateTime startedAt;
  DateTime? completedAt;

  /// For commandExecution items: the command that was run.
  List<String>? command;

  /// For reasoning items: raw reasoning text (from textDelta, not summary).
  final StringBuffer rawReasoningBuffer = StringBuffer();

  /// For fileChange items: list of {path, kind, diff}.
  List<Map<String, dynamic>>? fileChanges;

  ItemState({required this.id, required this.type, this.status = 'started'})
      : startedAt = DateTime.now();

  String get content => buffer.toString();
  String get rawReasoning => rawReasoningBuffer.toString();

  /// Duration of this item (ongoing or finished).
  Duration get duration =>
      (completedAt ?? DateTime.now()).difference(startedAt);
}

/// Runtime cache for a single thread's UI state.
/// Does NOT persist — purely in-memory storage for UI display.
class ThreadState {
  final String threadId;

  /// Chat messages committed to this thread.
  final List<ChatMessage> chatMessages = [];

  /// Pending approval request for this thread (if any).
  ApprovalRequest? pendingApproval;

  /// Raw diff from last turn/diff/updated notification.
  String? lastTurnDiff;

  /// Agent message buffer (streaming delta assembly — kept for legacy compat).
  final StringBuffer agentMessageBuffer = StringBuffer();
  String? agentMessageItemId;

  /// Live assistant message being built during a turn (block-based).
  ChatMessage? streamingMessage;

  /// Final agent message from last completed turn.
  String? lastAgentMessage;

  /// Current turn status: inProgress | completed | interrupted | failed
  String? currentTurnStatus;
  String? currentTurnId;

  /// Items received during the current turn (live, cleared on next turn).
  final List<ItemState> items = [];

  /// Snapshotted items per committed chat message index.
  /// Key = index in [chatMessages], Value = items associated with that message.
  final Map<int, List<ItemState>> messageItems = {};

  ThreadState({required this.threadId});

  String get streamingText => streamingMessage?.text ?? agentMessageBuffer.toString();

  void clear() {
    chatMessages.clear();
    pendingApproval = null;
    lastTurnDiff = null;
    agentMessageBuffer.clear();
    agentMessageItemId = null;
    streamingMessage = null;
    lastAgentMessage = null;
    currentTurnStatus = null;
    currentTurnId = null;
    items.clear();
    messageItems.clear();
  }
}
