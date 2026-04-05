/// A single entry in the event feed shown to the user.
enum EventKind {
  info,
  connected,
  disconnected,
  turnStarted,
  turnCompleted,
  itemStarted,
  itemCompleted,
  agentMessageDelta,
  commandOutput,
  approvalRequest,
  approvalResolved,
  error,
}

class EventEntry {
  final DateTime timestamp;
  final EventKind kind;
  final String method;
  final String summary;

  /// Optional raw params for detail expansion.
  final Map<String, dynamic>? raw;

  EventEntry({
    DateTime? timestamp,
    required this.kind,
    required this.method,
    required this.summary,
    this.raw,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isApproval => kind == EventKind.approvalRequest;
  bool get isError => kind == EventKind.error;
}
