import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/protocol.dart';
import '../models/runtime_config.dart';
import '../models/thread_state.dart';
import '../models/user_profile.dart';
import '../services/app_server_service.dart';

/// Simple workspace model.
class Workspace {
  final String id;
  final String name;
  final String cwd;

  Workspace({required this.id, required this.name, required this.cwd});
}

/// Simple thread info model.
class ThreadInfo {
  final String id;
  final String cwd;
  /// First user message from history — used as display title after backfill.
  String? title;

  ThreadInfo({required this.id, required this.cwd, this.title});

  factory ThreadInfo.fromJson(Map<String, dynamic> json) {
    return ThreadInfo(
      id: json['id'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      title: json['name'] as String?,
    );
  }
}

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

  // ── Workspace state ──────────────────────────────────────────────────────

  final List<Workspace> workspaceList = [];
  String? currentWorkspaceId;
  final Map<String, List<ThreadInfo>> workspaceThreads = {};

  // ── Thread / Turn state ───────────────────────────────────────────────────

  String? currentThreadId;
  final Map<String, ThreadState> _threadStates = {};

  ThreadState _getOrCreateThreadState(String threadId) {
    return _threadStates.putIfAbsent(threadId, () => ThreadState(threadId: threadId));
  }

  ThreadState? get currentThreadState =>
      currentThreadId != null ? _getOrCreateThreadState(currentThreadId!) : null;

  String? get currentTurnId => currentThreadState?.currentTurnId;
  String? get currentTurnStatus => currentThreadState?.currentTurnStatus;

  bool get isInProgress => currentTurnStatus == 'inProgress';

  // ── Chat messages, approval, diff (delegated to ThreadState) ──────

  List<ChatMessage> get chatMessages => currentThreadState?.chatMessages ?? [];
  ApprovalRequest? get pendingApproval => currentThreadState?.pendingApproval;
  String? get lastTurnDiff => currentThreadState?.lastTurnDiff;
  String? get lastAgentMessage => currentThreadState?.lastAgentMessage;
  String get streamingText => currentThreadState?.streamingText ?? '';

  WorkbenchController(this._service, {this.userProfile, this.runtimeConfig}) {
    // Initialize with default workspace
    _initializeDefaultWorkspace();
  }

  void _initializeDefaultWorkspace() {
    final defaultWorkspace = Workspace(
      id: 'default',
      name: 'Default',
      cwd: runtimeConfig?.cwd ?? '/tmp',
    );
    workspaceList.add(defaultWorkspace);
    currentWorkspaceId = defaultWorkspace.id;
  }

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
      await _loadDefaultWorkspaceThreads();
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
    _threadStates.clear();
    _log('WS', 'disconnected');
    notifyListeners();
  }

  // ── Workspace management ─────────────────────────────────────────────────

  Future<void> _loadDefaultWorkspaceThreads() async {
    final wsId = currentWorkspaceId;
    if (wsId == null) return;

    final configuredCwd = (runtimeConfig?.cwd?.isNotEmpty == true)
        ? runtimeConfig!.cwd!
        : null;

    if (configuredCwd != null) {
      // User configured a cwd — use it directly.
      final wsIdx = workspaceList.indexWhere((w) => w.id == wsId);
      if (wsIdx >= 0 && workspaceList[wsIdx].cwd != configuredCwd) {
        final old = workspaceList[wsIdx];
        workspaceList[wsIdx] = Workspace(id: old.id, name: _generateWorkspaceName(configuredCwd), cwd: configuredCwd);
        _log('WORKSPACE', 'updated default workspace cwd → $configuredCwd');
      }
      await _loadWorkspaceThreads(configuredCwd);
      return;
    }

    // No cwd configured — fetch ALL threads and auto-discover workspaces.
    _log('WORKSPACE', 'no cwd configured, fetching all threads');
    try {
      final allThreads = await _service.listThreads();
      if (allThreads.isEmpty) {
        _log('WORKSPACE', 'no threads found on server');
        return;
      }

      // Group threads by cwd.
      final byCwd = <String, List<Map<String, dynamic>>>{};
      for (final t in allThreads) {
        final m = t as Map<String, dynamic>;
        final threadCwd = m['cwd'] as String? ?? '';
        if (threadCwd.isNotEmpty) {
          byCwd.putIfAbsent(threadCwd, () => []).add(m);
        }
      }

      if (byCwd.isEmpty) {
        _log('WORKSPACE', 'all threads have empty cwd');
        return;
      }

      // Replace the default workspace with the most-populated cwd.
      final sortedCwds = byCwd.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      final primaryCwd = sortedCwds.first.key;

      // Update default workspace.
      final wsIdx = workspaceList.indexWhere((w) => w.id == wsId);
      if (wsIdx >= 0) {
        workspaceList[wsIdx] = Workspace(id: wsId, name: _generateWorkspaceName(primaryCwd), cwd: primaryCwd);
      }
      workspaceThreads[wsId] = sortedCwds.first.value
          .map((m) => ThreadInfo.fromJson(m))
          .toList();
      _log('WORKSPACE', 'auto-discovered ${workspaceThreads[wsId]!.length} threads for cwd=$primaryCwd');

      // Create additional workspaces for other cwds.
      for (final entry in sortedCwds.skip(1)) {
        final extraId = 'ws_${entry.key.hashCode.abs()}';
        if (!workspaceList.any((w) => w.cwd == entry.key)) {
          workspaceList.add(Workspace(
            id: extraId,
            name: _generateWorkspaceName(entry.key),
            cwd: entry.key,
          ));
          workspaceThreads[extraId] = entry.value
              .map((m) => ThreadInfo.fromJson(m))
              .toList();
          _log('WORKSPACE', 'auto-discovered ${entry.value.length} threads for cwd=${entry.key}');
        }
      }

      notifyListeners();

      // Auto-select the most recent thread in the primary workspace.
      final loaded = workspaceThreads[wsId] ?? [];
      if (currentThreadId == null && loaded.isNotEmpty) {
        await resumeWorkspaceThread(loaded.first.id);
      }
      // Fill missing titles for all discovered workspaces.
      for (final wid in workspaceThreads.keys.toList()) {
        await _fillMissingThreadTitles(wid);
      }
    } catch (e, st) {
      _log('ERR', 'failed to discover threads\n  reason : $e\n  stack  : ${_firstLines(st, 3)}');
    }
  }

  Future<void> createWorkspace(String cwd) async {
    final id = 'ws_${DateTime.now().millisecondsSinceEpoch}';
    final name = _generateWorkspaceName(cwd);
    final workspace = Workspace(id: id, name: name, cwd: cwd);
    workspaceList.add(workspace);
    currentWorkspaceId = workspace.id;
    currentThreadId = null;
    _log('WORKSPACE', 'created  id=$id  name=$name  cwd=$cwd');
    notifyListeners();

    // Load any existing threads for this cwd first.
    await _loadWorkspaceThreads(cwd);

    // Only auto-create a new thread if no historical threads were found.
    final loaded = workspaceThreads[id] ?? [];
    if (loaded.isEmpty) {
      await _autoCreateFirstThread(cwd);
    }
  }

  String _generateWorkspaceName(String cwd) {
    final parts = cwd.replaceAll('\\', '/').split('/');
    final lastPart = parts.where((p) => p.isNotEmpty).lastOrNull;
    if (lastPart != null && lastPart.isNotEmpty) {
      return lastPart;
    }
    final workspaceCount = workspaceList.length + 1;
    return '工作区 $workspaceCount';
  }

  Future<void> _autoCreateFirstThread(String cwd) async {
    try {
      await startThread(cwd: cwd);
      _log('WORKSPACE', 'auto-created first thread for workspace');
    } catch (e) {
      _log('WARN', 'failed to auto-create first thread: $e');
    }
  }

  Future<void> switchWorkspace(String workspaceId) async {
    if (workspaceId == currentWorkspaceId) return;
    final workspace = workspaceList.firstWhere(
      (w) => w.id == workspaceId,
      orElse: () => workspaceList.first,
    );
    currentWorkspaceId = workspace.id;
    currentThreadId = null;
    _log('WORKSPACE', 'switched to  id=${workspace.id}  name=${workspace.name}  cwd=${workspace.cwd}');
    await _loadWorkspaceThreads(workspace.cwd);
    notifyListeners();
  }

  Future<void> _loadWorkspaceThreads(String cwd) async {
    final wsId = currentWorkspaceId;
    if (wsId == null) return;
    _log('WORKSPACE', 'loading threads for cwd=$cwd');
    try {
      final threads = await _service.listThreads(cwd);
      workspaceThreads[wsId] = threads
          .map((t) => ThreadInfo.fromJson(t as Map<String, dynamic>))
          .toList();
      _log('WORKSPACE', 'loaded ${workspaceThreads[wsId]!.length} threads');
      notifyListeners();
      // Auto-select the most recent thread if nothing is currently selected.
      final loaded = workspaceThreads[wsId]!;
      if (currentThreadId == null && loaded.isNotEmpty) {
        await resumeWorkspaceThread(loaded.first.id);
      }
      // Fill missing titles for threads that have no server-side name.
      await _fillMissingThreadTitles(wsId);
    } catch (e, st) {
      _log('ERR', 'failed to load threads\n  reason : $e\n  stack  : ${_firstLines(st, 3)}');
    }
  }

  /// For threads without a title, read the first user message to generate one.
  Future<void> _fillMissingThreadTitles(String wsId) async {
    final threads = workspaceThreads[wsId];
    if (threads == null) return;
    final untitled = threads.where((t) => t.title == null).toList();
    if (untitled.isEmpty) return;
    _log('WORKSPACE', 'filling titles for ${untitled.length} unnamed threads');
    for (final t in untitled) {
      try {
        final result = await _service.readThread(t.id, includeTurns: true);
        final m = result as Map<String, dynamic>;
        final threadObj = m['thread'] as Map<String, dynamic>? ?? m;
        final turns = threadObj['turns'] as List<dynamic>? ?? [];
        // Find first user message text across all turns.
        String? firstText;
        for (final turn in turns) {
          if (firstText != null) break;
          final items = (turn as Map<String, dynamic>)['items'] as List<dynamic>? ?? [];
          for (final item in items) {
            final im = item as Map<String, dynamic>;
            if (im['type'] != 'userMessage') continue;
            if (im['content'] is List) {
              firstText = (im['content'] as List)
                  .whereType<Map>()
                  .where((p) => p['type'] == 'text')
                  .map((p) => p['text'] as String? ?? '')
                  .join();
            } else if (im['text'] is String) {
              firstText = im['text'] as String;
            }
            if (firstText != null && firstText.isNotEmpty) break;
            firstText = null;
          }
        }
        if (firstText != null && firstText.isNotEmpty) {
          final runes = firstText.runes.toList();
          t.title = runes.length > 4
              ? '${String.fromCharCodes(runes.take(4))}…'
              : firstText;
        }
      } catch (e) {
        // Non-critical — leave title as null, will show truncated ID.
        _log('WARN', 'title fill failed for thread ${t.id}: $e');
      }
    }
    notifyListeners();
  }

  Future<void> resumeWorkspaceThread(String threadId) async {
    currentThreadId = threadId;
    notifyListeners();
    // thread/resume is optional — some app-server versions may not support it.
    // We continue even if it fails; turn/start with the existing threadId is sufficient.
    try {
      _log('RPC', '→ thread/resume  threadId=$threadId');
      await _service.resumeThread(threadId);
      _log('RPC', '← thread/resume OK  threadId=$threadId');
    } catch (e) {
      _log('WARN', 'thread/resume not supported or failed ($e) — continuing with backfill only');
    }
    // Back-fill history if this thread has no cached messages yet.
    final state = _getOrCreateThreadState(threadId);
    if (state.chatMessages.isEmpty) {
      await _backfillThreadHistory(threadId, state);
    }
  }

  Future<void> _backfillThreadHistory(String threadId, ThreadState state) async {
    _log('RPC', '→ thread/read (backfill)  threadId=$threadId');
    try {
      final result = await _service.readThread(threadId, includeTurns: true);
      final m = result as Map<String, dynamic>;
      // app-server wraps the thread under result['thread']
      final threadObj = m['thread'] as Map<String, dynamic>? ?? m;
      final turns = threadObj['turns'] as List<dynamic>? ?? [];
      for (final turn in turns) {
        final items = (turn as Map<String, dynamic>)['items'] as List<dynamic>? ?? [];
        for (final item in items) {
          final m = item as Map<String, dynamic>;
          final type = m['type'] as String?;
          if (type == 'userMessage') {
            // userMessage stores text in content: [{"type":"text","text":"..."}]
            String? text;
            if (m['content'] is List) {
              final parts = (m['content'] as List)
                  .whereType<Map>()
                  .where((p) => p['type'] == 'text')
                  .map((p) => p['text'] as String? ?? '')
                  .join();
              if (parts.isNotEmpty) text = parts;
            } else if (m['content'] is String) {
              text = m['content'] as String;
            }
            // Fallback: top-level text field
            if ((text == null || text.isEmpty) && m['text'] is String) {
              text = m['text'] as String;
            }
            if (text != null && text.isNotEmpty) {
              state.chatMessages.add(ChatMessage(
                timestamp: DateTime.now(),
                role: ChatRole.user,
                text: text,
              ));
            }
          } else if (type == 'agentMessage') {
            // agentMessage stores text in a top-level 'text' field,
            // NOT inside 'content' (which is used by userMessage).
            String? text;
            if (m['text'] is String) {
              text = m['text'] as String;
            }
            // Fallback: also check content array (older format)
            if ((text == null || text.isEmpty) && m['content'] is List) {
              final parts = (m['content'] as List)
                  .whereType<Map>()
                  .where((p) => p['type'] == 'text')
                  .map((p) => p['text'] as String? ?? '')
                  .join();
              if (parts.isNotEmpty) text = parts;
            }
            if ((text == null || text.isEmpty) && m['content'] is String) {
              text = m['content'] as String;
            }
            if (text != null && text.isNotEmpty) {
              state.chatMessages.add(ChatMessage(
                timestamp: DateTime.now(),
                role: ChatRole.assistant,
                text: text,
              ));
            }
          }
        }
      }
      _log('RPC', '← thread/read backfill done  turns=${turns.length}  messages=${state.chatMessages.length}');
      // Update the thread's display title from the first user message.
      _updateThreadTitle(threadId, state.chatMessages);
      notifyListeners();
    } catch (e, st) {
      _log('ERR', 'thread/read backfill failed\n  reason : $e\n  stack  : ${_firstLines(st, 3)}');
    }
  }

  Future<void> createWorkspaceThread() async {
    final workspace = workspaceList.firstWhere(
      (w) => w.id == currentWorkspaceId,
      orElse: () => workspaceList.first,
    );
    await startThread(cwd: workspace.cwd);
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
      // Track new thread in workspace threads map
      if (currentWorkspaceId != null) {
        final wsThreads = workspaceThreads.putIfAbsent(currentWorkspaceId!, () => []);
        if (!wsThreads.any((t) => t.id == currentThreadId)) {
          wsThreads.add(ThreadInfo(id: currentThreadId!, cwd: cwd));
        }
      }
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

    final effectiveCwd = (runtimeConfig?.cwd?.isNotEmpty == true)
        ? runtimeConfig!.cwd!
        : cwd;

    if (currentThreadId == null) {
      await startThread(cwd: effectiveCwd);
    }

    final state = currentThreadState!;
    state.lastAgentMessage = null;
    state.lastTurnDiff = null;
    state.agentMessageBuffer.clear();
    state.agentMessageItemId = null;

    // Add user message to chat view immediately.
    state.chatMessages.add(ChatMessage(
      timestamp: DateTime.now(),
      role: ChatRole.user,
      text: prompt,
    ));

    final policy = runtimeConfig?.approvalPolicy ?? 'unlessTrusted';
    final model = runtimeConfig?.model;
    _log('RPC',
        '→ turn/start  threadId=$currentThreadId  cwd=$effectiveCwd  '
        'approvalPolicy=$policy  model=${model ?? "(default)"}\n'
        '  prompt: "${_truncate(prompt, 200)}"');

    final params = {
      'threadId': currentThreadId,
      'input': [
        {'type': 'text', 'text': prompt}
      ],
      'approvalPolicy': policy,
      if (effectiveCwd != '/') 'cwd': effectiveCwd,
      if (model != null) 'model': model,
    };

    try {
      final result = await _service.sendRequest('turn/start', params);
      state.currentTurnId =
          (result as Map<String, dynamic>)['turn']['id'] as String;
      state.currentTurnStatus = 'inProgress';
      _log('RPC', '← turn/start OK  turnId=${state.currentTurnId}');
    } catch (e, st) {
      _log('ERR', 'turn/start failed\n  reason : $e\n  stack  : ${_firstLines(st, 4)}');
      // Remove the user message we already added — turn never started.
      if (state.chatMessages.isNotEmpty && state.chatMessages.last.role == ChatRole.user) {
        state.chatMessages.removeLast();
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
    final state = currentThreadState;
    if (state?.pendingApproval == null) return;
    _log('APPROVAL',
        '→ response  requestId=${state!.pendingApproval!.requestId}  '
        'decision=$decision  kind=${state.pendingApproval!.kind}  '
        'cmd="${state.pendingApproval!.commandSummary}"');
    _service.sendResponse(state.pendingApproval!.requestId, {'decision': decision});
    state.pendingApproval = null;
    notifyListeners();
  }

  // ── Cwd update ───────────────────────────────────────────────────────────

  void updateCwd(String newCwd) {
    final config = runtimeConfig;
    if (config == null) return;
    runtimeConfig = RuntimeConfig(
      provider: config.provider,
      endpoint: config.endpoint,
      authMethod: config.authMethod,
      apiKey: config.apiKey,
      providerBaseUrl: config.providerBaseUrl,
      model: config.model,
      approvalPolicy: config.approvalPolicy,
      cwd: newCwd.isEmpty ? null : newCwd,
    );
    _log('CWD', 'updateCwd → "${newCwd.isEmpty ? "(cleared)" : newCwd}"');
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
        final state = _getOrCreateThreadState(p['threadId'] as String? ?? currentThreadId ?? '');
        state.currentTurnId = turn?['id'] as String? ?? state.currentTurnId;
        state.currentTurnStatus = 'inProgress';
        _log('TURN', 'turn/started  id=${turn?['id']}  threadId=${p['threadId']}');

      case 'turn/completed':
        final turn = p['turn'] as Map<String, dynamic>?;
        final state = currentThreadState;
        if (state != null) {
          final prevStatus = state.currentTurnStatus;
          state.currentTurnStatus = turn?['status'] as String? ?? 'completed';
          if (state.agentMessageBuffer.isNotEmpty) {
            state.lastAgentMessage = state.agentMessageBuffer.toString();
            state.chatMessages.add(ChatMessage(
              timestamp: DateTime.now(),
              role: ChatRole.assistant,
              text: state.lastAgentMessage!,
            ));
            state.agentMessageBuffer.clear();
            state.agentMessageItemId = null;
          }
          _log('TURN',
              'turn/completed  id=${turn?['id']}  '
              'status=${state.currentTurnStatus}  (was $prevStatus)  '
              'replyLen=${state.lastAgentMessage?.length ?? 0}');
          // Update sidebar title from first user message if not set yet.
          if (currentThreadId != null) {
            _updateThreadTitle(currentThreadId!, state.chatMessages);
          }
        }

      case 'turn/diff/updated':
        final state = currentThreadState;
        if (state != null) {
          state.lastTurnDiff = p['diff'] as String?;
          final lines = state.lastTurnDiff?.split('\n').length ?? 0;
          _log('TURN', 'turn/diff/updated  $lines lines');
        }

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
        final state = currentThreadState;
        if (state != null) {
          if (state.agentMessageItemId != itemId) {
            state.agentMessageBuffer.clear();
            state.agentMessageItemId = itemId;
            _log('STREAM', 'agentMessage stream start  itemId=$itemId');
          }
          state.agentMessageBuffer.write(delta);
          // Only log every ~200 chars to avoid flooding.
          if (state.agentMessageBuffer.length % 200 < delta.length) {
            _log('STREAM',
                'agentMessage delta  itemId=$itemId  '
                'bufLen=${state.agentMessageBuffer.length}  '
                'sample="${_truncate(state.agentMessageBuffer.toString(), 60)}"');
          }
        }

      case 'item/commandExecution/outputDelta':
        final output = p['output'] as String? ?? '';
        if (output.trim().isNotEmpty) {
          _log('CMD', 'outputDelta  itemId=${p['itemId']}\n  ${output.trimRight()}');
        }
        return; // Skip notifyListeners — no UI state changed.

      case 'thread/name/updated':
        final threadId = p['threadId'] as String?;
        final name = p['name'] as String?;
        if (threadId != null && name != null) {
          for (final threads in workspaceThreads.values) {
            for (final t in threads) {
              if (t.id == threadId) { t.title = name; break; }
            }
          }
          _log('NOTIF', 'thread/name/updated  threadId=$threadId  name=$name');
        }

      case 'thread/archived':
        final threadId = p['threadId'] as String?;
        if (threadId != null) {
          for (final threads in workspaceThreads.values) {
            threads.removeWhere((t) => t.id == threadId);
          }
          _threadStates.remove(threadId);
          if (currentThreadId == threadId) currentThreadId = null;
          _log('NOTIF', 'thread/archived  threadId=$threadId');
        }

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
      final state = _getOrCreateThreadState(p['threadId'] as String? ?? '');
      state.pendingApproval = ApprovalRequest(
        requestId: r.id,
        kind: isCmd ? 'commandExecution' : 'fileChange',
        threadId: p['threadId'] as String? ?? '',
        turnId: p['turnId'] as String? ?? '',
        itemId: p['itemId'] as String?,
        command: (p['command'] as List?)?.cast<String>(),
        cwd: p['cwd'] as String?,
        reason: p['reason'] as String?,
        diffSnapshot: state.lastTurnDiff,
      );
      _log('APPROVAL',
          'requestApproval  id=${r.id}  kind=${state.pendingApproval!.kind}\n'
          '  cmd    : ${state.pendingApproval!.commandSummary}\n'
          '  cwd    : ${state.pendingApproval!.cwd}\n'
          '  reason : ${state.pendingApproval!.reason ?? "(none)"}');
      notifyListeners();
    } else {
      _log('WARN',
          'unhandled server request  method=${r.method}  id=${r.id}  '
          'params=${_summarizeMap(r.params ?? {})}');
    }
  }

  // ── Thread title helpers ──────────────────────────────────────────────────

  /// Remove a workspace and archive all its threads on the server.
  Future<void> removeWorkspace(String workspaceId) async {
    if (workspaceId == 'default') return; // protect default
    // Archive all threads in this workspace so they don't reappear on restart.
    final threads = workspaceThreads[workspaceId] ?? [];
    for (final t in threads) {
      try {
        await _service.archiveThread(t.id);
      } catch (e) {
        _log('WARN', 'failed to archive thread ${t.id}: $e');
      }
      _threadStates.remove(t.id);
    }
    workspaceList.removeWhere((w) => w.id == workspaceId);
    workspaceThreads.remove(workspaceId);
    if (currentWorkspaceId == workspaceId) {
      currentWorkspaceId = workspaceList.firstOrNull?.id;
      currentThreadId = null;
    }
    _log('WORKSPACE', 'removed workspace $workspaceId (archived ${threads.length} threads)');
    notifyListeners();
  }

  /// Archive a thread on the server and remove it from local state.
  Future<void> archiveThread(String workspaceId, String threadId) async {
    _log('RPC', '→ thread/archive  threadId=$threadId');
    try {
      await _service.archiveThread(threadId);
      _log('RPC', '← thread/archive OK');
    } catch (e) {
      _log('WARN', 'thread/archive failed ($e) — removing locally only');
    }
    workspaceThreads[workspaceId]?.removeWhere((t) => t.id == threadId);
    _threadStates.remove(threadId);
    if (currentThreadId == threadId) {
      currentThreadId = null;
    }
    notifyListeners();
  }

  /// Rename a thread on the server and update local state.
  Future<void> renameThread(String threadId, String newName) async {
    _log('RPC', '→ thread/name/set  threadId=$threadId  name=$newName');
    try {
      await _service.renameThread(threadId, newName);
      _log('RPC', '← thread/name/set OK');
    } catch (e) {
      _log('WARN', 'thread/name/set failed ($e) — updating locally only');
    }
    for (final threads in workspaceThreads.values) {
      for (final t in threads) {
        if (t.id == threadId) {
          t.title = newName;
          break;
        }
      }
    }
    notifyListeners();
  }

  void _updateThreadTitle(String threadId, List<ChatMessage> messages) {
    final firstUser = messages.where((m) => m.role == ChatRole.user).firstOrNull;
    if (firstUser == null) return;
    for (final threads in workspaceThreads.values) {
      for (final t in threads) {
        if (t.id == threadId) {
          // Don't overwrite a server-persisted or user-set name.
          if (t.title != null) return;
          final runes = firstUser.text.runes.toList();
          t.title = runes.length > 4
              ? '${String.fromCharCodes(runes.take(4))}…'
              : firstUser.text;
          return;
        }
      }
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
