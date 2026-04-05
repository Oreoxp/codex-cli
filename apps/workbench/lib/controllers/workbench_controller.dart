import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/event_entry.dart';
import '../models/protocol.dart';
import '../models/user_profile.dart';
import '../services/app_server_service.dart';

/// Central state holder for the workbench.
///
/// Wraps [AppServerService] and maintains:
///   - Connection state
///   - Current thread / turn
///   - Event feed list
///   - Pending approval request
///   - User profile
///
/// Notifies listeners on any state change.
class WorkbenchController extends ChangeNotifier {
  final AppServerService _service;
  StreamSubscription<AppServerMessage>? _msgSub;

  // ── User profile ──────────────────────────────────────────────────────────

  UserProfile? userProfile;

  // ── Connection ────────────────────────────────────────────────────────────

  AppServerConnectionState get connectionState => _service.state;
  bool get isConnected => _service.isConnected;
  String? get lastError => _service.lastError;

  // ── Thread / Turn state ───────────────────────────────────────────────────

  String? currentThreadId;
  String? currentTurnId;
  String? currentTurnStatus; // inProgress | completed | interrupted | failed

  bool get isInProgress => currentTurnStatus == 'inProgress';

  // ── Event feed ────────────────────────────────────────────────────────────

  final List<EventEntry> events = [];

  // Buffer for streaming agent message (the current delta sequence).
  final StringBuffer _agentMessageBuffer = StringBuffer();
  String? _agentMessageItemId;

  // ── Pending approval ──────────────────────────────────────────────────────

  ApprovalRequest? pendingApproval;

  // ── Result summary ────────────────────────────────────────────────────────

  /// Final agent reply text from the last completed turn.
  String? lastAgentMessage;

  /// Raw turn diff snapshot from the last turn/diff/updated notification.
  String? lastTurnDiff;

  WorkbenchController(this._service, {this.userProfile});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> connect(String url) async {
    _addEvent(EventEntry(
      kind: EventKind.info,
      method: 'connect',
      summary: 'Connecting to $url …',
    ));
    notifyListeners();

    _msgSub?.cancel();
    _msgSub = _service.messages.listen(
      _handleMessage,
      onError: (Object e) {
        _addEvent(EventEntry(
          kind: EventKind.error,
          method: '__ws_error__',
          summary: 'WebSocket error: $e',
        ));
        notifyListeners();
      },
    );

    try {
      await _service.connect(url);
      _addEvent(EventEntry(
        kind: EventKind.connected,
        method: 'connect',
        summary: 'Connected to $url',
      ));
    } catch (e) {
      _addEvent(EventEntry(
        kind: EventKind.error,
        method: 'connect',
        summary: 'Connection failed: $e',
      ));
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _service.disconnect();
    _msgSub?.cancel();
    _msgSub = null;
    currentThreadId = null;
    currentTurnId = null;
    currentTurnStatus = null;
    pendingApproval = null;
    _agentMessageBuffer.clear();
    _agentMessageItemId = null;
    _addEvent(EventEntry(
      kind: EventKind.disconnected,
      method: 'disconnect',
      summary: 'Disconnected',
    ));
    notifyListeners();
  }

  // ── Thread management ─────────────────────────────────────────────────────

  /// Start a new thread for the given [cwd].
  ///
  /// Call this before [startTurn] if no thread is open yet.
  Future<void> startThread({required String cwd}) async {
    final result = await _service.sendRequest('thread/start', {
      'cwd': cwd,
      'approvalPolicy': 'unlessTrusted',
    });
    currentThreadId =
        (result as Map<String, dynamic>)['thread']['id'] as String;
    _addEvent(EventEntry(
      kind: EventKind.info,
      method: 'thread/start',
      summary: 'Thread started: $currentThreadId',
    ));
    notifyListeners();
  }

  // ── Turn management ───────────────────────────────────────────────────────

  /// Send [prompt] as a new turn on the current thread.
  ///
  /// If no thread is open, starts one with [cwd] first.
  Future<void> startTurn(String prompt, {String cwd = '/'}) async {
    if (!isConnected) return;

    if (currentThreadId == null) {
      await startThread(cwd: cwd);
    }

    lastAgentMessage = null;
    lastTurnDiff = null;
    _agentMessageBuffer.clear();
    _agentMessageItemId = null;

    final result = await _service.sendRequest('turn/start', {
      'threadId': currentThreadId,
      'input': [
        {'type': 'text', 'text': prompt}
      ],
      'approvalPolicy': 'unlessTrusted',
    });
    currentTurnId =
        (result as Map<String, dynamic>)['turn']['id'] as String;
    currentTurnStatus = 'inProgress';
    _addEvent(EventEntry(
      kind: EventKind.info,
      method: 'turn/start',
      summary: 'Turn started: $currentTurnId',
    ));
    notifyListeners();
  }

  Future<void> interruptTurn() async {
    if (currentThreadId == null || currentTurnId == null) return;
    await _service.sendRequest('turn/interrupt', {
      'threadId': currentThreadId,
      'turnId': currentTurnId,
    });
  }

  // ── Approval ──────────────────────────────────────────────────────────────

  void respondToApproval(String decision) {
    if (pendingApproval == null) return;
    _service.sendResponse(pendingApproval!.requestId, {'decision': decision});
    _addEvent(EventEntry(
      kind: EventKind.approvalResolved,
      method: 'approval/response',
      summary: 'Approval: $decision',
    ));
    pendingApproval = null;
    notifyListeners();
  }

  // ── Message handling ─────────────────────────────────────────────────────���

  void _handleMessage(AppServerMessage msg) {
    switch (msg) {
      case AppServerNotification n:
        _handleNotification(n);
      case AppServerServerRequest r:
        _handleServerRequest(r);
      case AppServerResponse _:
        // Responses are handled in the service; nothing to do here.
        break;
    }
  }

  void _handleNotification(AppServerNotification n) {
    final p = n.params ?? {};

    switch (n.method) {
      case '__ws_closed__':
        _addEvent(EventEntry(
          kind: EventKind.disconnected,
          method: n.method,
          summary: 'Connection closed by server',
        ));

      case 'turn/started':
        final turn = p['turn'] as Map<String, dynamic>?;
        currentTurnStatus = 'inProgress';
        _addEvent(EventEntry(
          kind: EventKind.turnStarted,
          method: n.method,
          summary: '▶ Turn started  ${turn?['id'] ?? ''}',
          raw: p,
        ));

      case 'turn/completed':
        final turn = p['turn'] as Map<String, dynamic>?;
        currentTurnStatus = turn?['status'] as String? ?? 'completed';
        if (_agentMessageBuffer.isNotEmpty) {
          lastAgentMessage = _agentMessageBuffer.toString();
          _agentMessageBuffer.clear();
          _agentMessageItemId = null;
        }
        _addEvent(EventEntry(
          kind: EventKind.turnCompleted,
          method: n.method,
          summary: '■ Turn $currentTurnStatus',
          raw: p,
        ));

      case 'turn/diff/updated':
        lastTurnDiff = p['diff'] as String?;
        // No separate event entry; diff is shown in result panel.

      case 'item/started':
        final item = p['item'] as Map<String, dynamic>?;
        _addEvent(EventEntry(
          kind: EventKind.itemStarted,
          method: n.method,
          summary: '  ▸ ${_itemSummary(item)}',
          raw: p,
        ));

      case 'item/completed':
        final item = p['item'] as Map<String, dynamic>?;
        final status = item?['status'] as String?;
        final suffix = status != null ? '  [$status]' : '';
        _addEvent(EventEntry(
          kind: EventKind.itemCompleted,
          method: n.method,
          summary: '  ✓ ${item?['type'] ?? '?'}$suffix',
          raw: p,
        ));

      case 'item/agentMessage/delta':
        final delta = p['delta'] as String? ?? '';
        final itemId = p['itemId'] as String?;
        if (_agentMessageItemId != itemId) {
          // New agent message stream started.
          _agentMessageBuffer.clear();
          _agentMessageItemId = itemId;
        }
        _agentMessageBuffer.write(delta);
        // Update last event if it's already an agentMessageDelta for this item,
        // otherwise add a new streaming entry.
        if (events.isNotEmpty &&
            events.last.kind == EventKind.agentMessageDelta &&
            events.last.raw?['itemId'] == itemId) {
          events[events.length - 1] = EventEntry(
            kind: EventKind.agentMessageDelta,
            method: n.method,
            summary: '  💬 ${_truncate(_agentMessageBuffer.toString(), 120)}',
            raw: {'itemId': itemId},
          );
        } else {
          _addEvent(EventEntry(
            kind: EventKind.agentMessageDelta,
            method: n.method,
            summary: '  💬 ${_truncate(delta, 120)}',
            raw: {'itemId': itemId},
          ));
        }

      case 'item/commandExecution/outputDelta':
        final output = p['output'] as String? ?? '';
        if (output.trim().isNotEmpty) {
          _addEvent(EventEntry(
            kind: EventKind.commandOutput,
            method: n.method,
            summary: '  \$ ${_truncate(output.trim(), 80)}',
          ));
        }
        return; // Return early to skip the extra notifyListeners overhead.

      case '__parse_error__':
        _addEvent(EventEntry(
          kind: EventKind.error,
          method: n.method,
          summary: 'Parse error: ${p['error']}',
        ));

      default:
        // Show all other notifications in the feed for visibility.
        _addEvent(EventEntry(
          kind: EventKind.info,
          method: n.method,
          summary: '  · ${n.method}',
          raw: p,
        ));
    }

    notifyListeners();
  }

  void _handleServerRequest(AppServerServerRequest r) {
    if (r.method == 'item/commandExecution/requestApproval' ||
        r.method == 'item/fileChange/requestApproval') {
      final p = r.params ?? {};
      final isCmd = r.method.contains('commandExecution');
      pendingApproval = ApprovalRequest(
        requestId: r.id,
        kind: isCmd ? 'commandExecution' : 'fileChange',
        threadId: p['threadId'] as String? ?? '',
        turnId: p['turnId'] as String? ?? '',
        itemId: p['itemId'] as String?,
        command: (p['command'] as List?)?.cast<String>(),
        cwd: p['cwd'] as String?,
        reason: p['reason'] as String?,
      );
      _addEvent(EventEntry(
        kind: EventKind.approvalRequest,
        method: r.method,
        summary: '⚠ Approval needed: ${pendingApproval!.commandSummary}',
        raw: p,
      ));
      notifyListeners();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _addEvent(EventEntry e) => events.add(e);

  String _itemSummary(Map<String, dynamic>? item) {
    if (item == null) return '?';
    final type = item['type'] as String? ?? '?';
    switch (type) {
      case 'commandExecution':
        final cmd = (item['command'] as List?)?.cast<String>().join(' ') ?? '';
        return 'cmd: ${_truncate(cmd, 60)}';
      case 'fileChange':
        final changes = item['changes'] as List?;
        final paths =
            changes?.map((c) => (c as Map)['path']).join(', ') ?? '';
        return 'fileChange: ${_truncate(paths, 60)}';
      case 'agentMessage':
        return 'agentMessage';
      case 'reasoning':
        return 'reasoning …';
      default:
        return type;
    }
  }

  String _truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  @override
  void dispose() {
    _msgSub?.cancel();
    _msgSub = null;
    super.dispose();
  }
}
