import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/protocol.dart';
import '../models/runtime_config.dart';
import '../models/user_profile.dart';
import '../services/app_server_service.dart';

/// Central state holder for the workbench.
///
/// All debug/protocol events are written to the console via [_log].
/// The UI only surfaces chat messages, approval requests, and diffs.
class WorkbenchController extends ChangeNotifier {
  final AppServerService _service;
  StreamSubscription<AppServerMessage>? _msgSub;

  // ── User profile ──────────────────────────────────────────────────────────

  UserProfile? userProfile;
  RuntimeConfig? runtimeConfig;

  // ── Connection ────────────────────────────────────────────────────────────

  AppServerConnectionState get connectionState => _service.state;
  bool get isConnected => _service.isConnected;
  String? get lastError => _service.lastError;

  // ── Thread / Turn state ───────────────────────────────────────────────────

  String? currentThreadId;
  String? currentTurnId;
  String? currentTurnStatus; // inProgress | completed | interrupted | failed

  bool get isInProgress => currentTurnStatus == 'inProgress';

  // ── Chat messages ─────────────────────────────────────────────────────────

  /// Committed chat messages (user + assistant turns). Shown in the chat view.
  final List<ChatMessage> chatMessages = [];

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

  /// In-progress streaming text (agent message being assembled mid-turn).
  String get streamingText => _agentMessageBuffer.toString();

  WorkbenchController(this._service, {this.userProfile, this.runtimeConfig});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> connect(String url) async {
    _log('WS', 'connect start → $url');
    notifyListeners();

    _msgSub?.cancel();
    _msgSub = _service.messages.listen(
      _handleMessage,
      onError: (Object e, StackTrace st) {
        _log('ERR', 'WebSocket stream error\n  error : $e\n  stack : ${_firstLines(st, 3)}');
        notifyListeners();
      },
    );

    try {
      await _service.connect(url);
      _log('WS', 'connect success → $url');
      await _applyProviderConfig();
    } catch (e, st) {
      _log('ERR', 'connect failed → $url\n'
          '  reason : $e\n'
          '  stack  : ${_firstLines(st, 4)}');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _log('WS', 'disconnect requested  thread=$currentThreadId');
    await _service.disconnect();
    _msgSub?.cancel();
    _msgSub = null;
    currentThreadId = null;
    currentTurnId = null;
    currentTurnStatus = null;
    pendingApproval = null;
    _agentMessageBuffer.clear();
    _agentMessageItemId = null;
    _log('WS', 'disconnected');
    notifyListeners();
  }

  // ── Thread management ─────────────────────────────────────────────────────

  Future<void> startThread({required String cwd}) async {
    final policy = runtimeConfig?.approvalPolicy ?? 'unlessTrusted';
    _log('RPC', '→ thread/start  cwd=$cwd  approvalPolicy=$policy');
    try {
      final result = await _service.sendRequest('thread/start', {
        'cwd': cwd,
        'approvalPolicy': policy,
      });
      currentThreadId =
          (result as Map<String, dynamic>)['thread']['id'] as String;
      _log('RPC', '← thread/start OK  threadId=$currentThreadId');
      notifyListeners();
    } catch (e, st) {
      _log('ERR', 'thread/start failed\n  reason : $e\n  stack  : ${_firstLines(st, 4)}');
      rethrow;
    }
  }

  // ── Turn management ───────────────────────────────────────────────────────

  Future<void> startTurn(String prompt, {String cwd = '/'}) async {
    if (!isConnected) {
      _log('WARN', 'startTurn called while disconnected — ignored');
      return;
    }

    if (currentThreadId == null) {
      await startThread(cwd: cwd);
    }

    lastAgentMessage = null;
    lastTurnDiff = null;
    _agentMessageBuffer.clear();
    _agentMessageItemId = null;

    // Add user message to chat view immediately.
    chatMessages.add(ChatMessage(
      timestamp: DateTime.now(),
      role: ChatRole.user,
      text: prompt,
    ));

    final policy = runtimeConfig?.approvalPolicy ?? 'unlessTrusted';
    final model = runtimeConfig?.model;
    _log('RPC',
        '→ turn/start  threadId=$currentThreadId  cwd=$cwd  '
        'approvalPolicy=$policy  model=${model ?? "(default)"}\n'
        '  prompt: "${_truncate(prompt, 200)}"');

    final params = {
      'threadId': currentThreadId,
      'input': [
        {'type': 'text', 'text': prompt}
      ],
      'approvalPolicy': policy,
      if (cwd != '/') 'cwd': cwd,
      if (model != null) 'model': model,
    };

    try {
      final result = await _service.sendRequest('turn/start', params);
      currentTurnId =
          (result as Map<String, dynamic>)['turn']['id'] as String;
      currentTurnStatus = 'inProgress';
      _log('RPC', '← turn/start OK  turnId=$currentTurnId');
    } catch (e, st) {
      _log('ERR', 'turn/start failed\n  reason : $e\n  stack  : ${_firstLines(st, 4)}');
      // Remove the user message we already added — turn never started.
      if (chatMessages.isNotEmpty && chatMessages.last.role == ChatRole.user) {
        chatMessages.removeLast();
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> interruptTurn() async {
    if (currentThreadId == null || currentTurnId == null) return;
    _log('RPC', '→ turn/interrupt  threadId=$currentThreadId  turnId=$currentTurnId');
    try {
      await _service.sendRequest('turn/interrupt', {
        'threadId': currentThreadId,
        'turnId': currentTurnId,
      });
      _log('RPC', '← turn/interrupt OK');
    } catch (e, st) {
      _log('ERR', 'turn/interrupt failed\n  reason : $e\n  stack  : ${_firstLines(st, 3)}');
    }
  }

  // ── Approval ──────────────────────────────────────────────────────────────

  void respondToApproval(String decision) {
    if (pendingApproval == null) return;
    _log('APPROVAL',
        '→ response  requestId=${pendingApproval!.requestId}  '
        'decision=$decision  kind=${pendingApproval!.kind}  '
        'cmd="${pendingApproval!.commandSummary}"');
    _service.sendResponse(pendingApproval!.requestId, {'decision': decision});
    pendingApproval = null;
    notifyListeners();
  }

  // ── Provider config injection ─────────────────────────────────────────────

  Future<void> _applyProviderConfig() async {
    final config = runtimeConfig;
    if (config == null) return;
    if (config.authMethod != 'API Key') return;
    final baseUrl = config.providerBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return;

    const providerId = 'workbench_custom';
    final providerEntry = <String, dynamic>{
      'name': 'Custom Provider',
      'base_url': baseUrl,
      'wire_api': 'responses',
      'requires_openai_auth': false,
    };
    final apiKey = config.apiKey;
    if (apiKey != null && apiKey.isNotEmpty) {
      providerEntry['experimental_bearer_token'] = apiKey;
    }

    _log('RPC',
        '→ config/batchWrite  providerId=$providerId  baseUrl=$baseUrl  '
        'hasApiKey=${apiKey != null && apiKey.isNotEmpty}');
    try {
      await _service.sendRequest('config/batchWrite', {
        'edits': [
          {
            'keyPath': 'model_providers.$providerId',
            'value': providerEntry,
            'mergeStrategy': 'replace',
          },
          {
            'keyPath': 'model_provider',
            'value': providerId,
            'mergeStrategy': 'replace',
          },
        ],
        'reloadUserConfig': true,
      });
      _log('RPC', '← config/batchWrite OK  provider=$providerId now active');
    } catch (e, st) {
      _log('ERR',
          'config/batchWrite failed  providerId=$providerId  baseUrl=$baseUrl\n'
          '  reason : $e\n'
          '  stack  : ${_firstLines(st, 4)}');
    }
  }

  // ── Message dispatch ──────────────────────────────────────────────────────

  void _handleMessage(AppServerMessage msg) {
    switch (msg) {
      case AppServerNotification n:
        _handleNotification(n);
      case AppServerServerRequest r:
        _handleServerRequest(r);
      case AppServerResponse _:
        // Already resolved by AppServerService pending map — no action needed.
        break;
    }
  }

  void _handleNotification(AppServerNotification n) {
    final p = n.params ?? {};

    switch (n.method) {
      case '__ws_closed__':
        _log('WS', 'connection closed by server');

      case '__parse_error__':
        _log('ERR',
            'message parse error\n'
            '  error : ${p['error']}\n'
            '  raw   : ${p['raw']}');

      case 'turn/started':
        final turn = p['turn'] as Map<String, dynamic>?;
        currentTurnId = turn?['id'] as String? ?? currentTurnId;
        currentTurnStatus = 'inProgress';
        _log('TURN', 'turn/started  id=${turn?['id']}  threadId=${p['threadId']}');

      case 'turn/completed':
        final turn = p['turn'] as Map<String, dynamic>?;
        final prevStatus = currentTurnStatus;
        currentTurnStatus = turn?['status'] as String? ?? 'completed';
        if (_agentMessageBuffer.isNotEmpty) {
          lastAgentMessage = _agentMessageBuffer.toString();
          chatMessages.add(ChatMessage(
            timestamp: DateTime.now(),
            role: ChatRole.assistant,
            text: lastAgentMessage!,
          ));
          _agentMessageBuffer.clear();
          _agentMessageItemId = null;
        }
        _log('TURN',
            'turn/completed  id=${turn?['id']}  '
            'status=$currentTurnStatus  (was $prevStatus)  '
            'replyLen=${lastAgentMessage?.length ?? 0}');

      case 'turn/diff/updated':
        lastTurnDiff = p['diff'] as String?;
        final lines = lastTurnDiff?.split('\n').length ?? 0;
        _log('TURN', 'turn/diff/updated  $lines lines');

      case 'item/started':
        final item = p['item'] as Map<String, dynamic>?;
        _log('ITEM', 'item/started  type=${item?['type']}  id=${item?['id']}  '
            'detail=${_itemDetail(item)}');

      case 'item/completed':
        final item = p['item'] as Map<String, dynamic>?;
        _log('ITEM',
            'item/completed  type=${item?['type']}  id=${item?['id']}  '
            'status=${item?['status']}  detail=${_itemDetail(item)}');

      case 'item/agentMessage/delta':
        final delta = p['delta'] as String? ?? '';
        final itemId = p['itemId'] as String?;
        if (_agentMessageItemId != itemId) {
          _agentMessageBuffer.clear();
          _agentMessageItemId = itemId;
          _log('STREAM', 'agentMessage stream start  itemId=$itemId');
        }
        _agentMessageBuffer.write(delta);
        // Only log every ~200 chars to avoid flooding.
        if (_agentMessageBuffer.length % 200 < delta.length) {
          _log('STREAM',
              'agentMessage delta  itemId=$itemId  '
              'bufLen=${_agentMessageBuffer.length}  '
              'sample="${_truncate(_agentMessageBuffer.toString(), 60)}"');
        }

      case 'item/commandExecution/outputDelta':
        final output = p['output'] as String? ?? '';
        if (output.trim().isNotEmpty) {
          _log('CMD', 'outputDelta  itemId=${p['itemId']}\n  ${output.trimRight()}');
        }
        return; // Skip notifyListeners — no UI state changed.

      // ── Server-reported errors (LLM call failures, retries, etc.) ──────────
      case 'error':
        final err = p['error'];
        final willRetry = p['willRetry'];
        final errStr = err is Map
            ? 'code=${err['code']}  message=${err['message']}'
            : err?.toString() ?? '(no error field)';
        _log('ERR',
            'server error notification\n'
            '  error    : $errStr\n'
            '  willRetry: $willRetry\n'
            '  threadId : ${p['threadId']}\n'
            '  turnId   : ${p['turnId']}');

      default:
        // Print all kv pairs so unknown notifications are readable.
        final kv = p.entries.map((e) => '${e.key}=${e.value}').join('  ');
        _log('NOTIF', '${n.method}  $kv');
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
      _log('APPROVAL',
          'requestApproval  id=${r.id}  kind=${pendingApproval!.kind}\n'
          '  cmd    : ${pendingApproval!.commandSummary}\n'
          '  cwd    : ${pendingApproval!.cwd}\n'
          '  reason : ${pendingApproval!.reason ?? "(none)"}');
      notifyListeners();
    } else {
      _log('WARN',
          'unhandled server request  method=${r.method}  id=${r.id}  '
          'params=${_summarizeMap(r.params ?? {})}');
    }
  }

  // ── Logging helpers ───────────────────────────────────────────────────────

  /// Emit a structured log line to the flutter run terminal.
  ///
  /// Format: `[TAG HH:mm:ss.mmm] <message>`
  /// Each logical line is printed separately so long messages aren't truncated.
  static void _log(String tag, String message) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final prefix = '[${tag.padRight(6)} $ts]';
    // Split on newlines so each line gets the prefix and debugPrint
    // doesn't silently truncate mid-message.
    final lines = message.split('\n');
    debugPrint('$prefix ${lines.first}');
    for (final line in lines.skip(1)) {
      debugPrint('${' ' * prefix.length} $line');
    }
  }

  /// Returns first [n] non-empty lines from a stack trace.
  static String _firstLines(StackTrace st, int n) {
    final lines = st.toString().split('\n').where((l) => l.trim().isNotEmpty);
    return lines.take(n).join('\n    ');
  }

  String _itemDetail(Map<String, dynamic>? item) {
    if (item == null) return '?';
    final type = item['type'] as String? ?? '?';
    switch (type) {
      case 'commandExecution':
        final cmd =
            (item['command'] as List?)?.cast<String>().join(' ') ?? '';
        return 'cmd="${_truncate(cmd, 80)}"';
      case 'fileChange':
        final changes = item['changes'] as List?;
        final paths =
            changes?.map((c) => (c as Map)['path']).join(', ') ?? '';
        return 'paths="${_truncate(paths, 80)}"';
      case 'agentMessage':
        return 'agentMessage';
      case 'reasoning':
        return 'reasoning';
      default:
        return type;
    }
  }

  String _summarizeMap(Map<String, dynamic> m) {
    if (m.isEmpty) return '{}';
    return m.entries.map((e) => '${e.key}=${e.value}').join('  ');
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
