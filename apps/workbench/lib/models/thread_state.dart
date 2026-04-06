import '../models/chat_message.dart';
import '../models/protocol.dart';

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

  /// Agent message buffer (streaming delta assembly).
  final StringBuffer agentMessageBuffer = StringBuffer();
  String? agentMessageItemId;

  /// Final agent message from last completed turn.
  String? lastAgentMessage;

  /// Current turn status: inProgress | completed | interrupted | failed
  String? currentTurnStatus;
  String? currentTurnId;

  ThreadState({required this.threadId});

  String get streamingText => agentMessageBuffer.toString();

  void clear() {
    chatMessages.clear();
    pendingApproval = null;
    lastTurnDiff = null;
    agentMessageBuffer.clear();
    agentMessageItemId = null;
    lastAgentMessage = null;
    currentTurnStatus = null;
    currentTurnId = null;
  }
}
