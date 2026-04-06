import 'dart:convert';

/// Sealed hierarchy for messages received from codex app-server.
///
/// Three shapes exist on the wire:
///   Notification  - { "method": "...", "params": {...} }            (no id)
///   ServerRequest - { "id": X, "method": "...", "params": {...} }   (server→client, needs response)
///   Response      - { "id": X, "result": {...} } or { "id": X, "error": {...} }
sealed class AppServerMessage {}

/// Unsolicited notification pushed by the server (no id).
class AppServerNotification extends AppServerMessage {
  final String method;
  final Map<String, dynamic>? params;

  AppServerNotification({required this.method, this.params});
}

/// Server-initiated request that requires a client response (has id + method).
/// Used for approval flows: item/commandExecution/requestApproval, item/fileChange/requestApproval.
class AppServerServerRequest extends AppServerMessage {
  final dynamic id;
  final String method;
  final Map<String, dynamic>? params;

  AppServerServerRequest({required this.id, required this.method, this.params});
}

/// Response to a client-initiated request.
class AppServerResponse extends AppServerMessage {
  final dynamic id;
  final dynamic result;
  final Map<String, dynamic>? error;

  AppServerResponse({required this.id, this.result, this.error});
}

/// Parse a raw JSON string into an [AppServerMessage].
AppServerMessage parseAppServerMessage(String raw) {
  final json = jsonDecode(raw) as Map<String, dynamic>;
  if (json.containsKey('method')) {
    if (json.containsKey('id') && json['id'] != null) {
      return AppServerServerRequest(
        id: json['id'],
        method: json['method'] as String,
        params: json['params'] as Map<String, dynamic>?,
      );
    }
    return AppServerNotification(
      method: json['method'] as String,
      params: json['params'] as Map<String, dynamic>?,
    );
  }
  return AppServerResponse(
    id: json['id'],
    result: json['result'],
    error: json['error'] as Map<String, dynamic>?,
  );
}

/// Pending approval request from the server.
class ApprovalRequest {
  final dynamic requestId; // JSON-RPC id to send the response to
  final String kind; // 'commandExecution' | 'fileChange'
  final String threadId;
  final String turnId;
  final String? itemId;
  final List<String>? command;
  final String? cwd;
  final String? reason;
  final String? diffSnapshot; // captured lastTurnDiff at approval creation time

  const ApprovalRequest({
    required this.requestId,
    required this.kind,
    required this.threadId,
    required this.turnId,
    this.itemId,
    this.command,
    this.cwd,
    this.reason,
    this.diffSnapshot,
  });

  String get commandSummary =>
      command != null ? command!.join(' ') : '(file change)';
}
