import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/protocol.dart';

enum AppServerConnectionState { disconnected, connecting, connected, error }

/// Manages the WebSocket connection to codex app-server.
///
/// Responsibilities:
///   - Connect / disconnect lifecycle
///   - JSON-RPC initialize handshake
///   - Send client-initiated requests and match responses via pending map
///   - Send responses to server-initiated requests (approvals)
///   - Broadcast all parsed messages to [messages] stream
class AppServerService {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  final _messageController =
      StreamController<AppServerMessage>.broadcast();

  // Exposed for testing / external listening.
  Stream<AppServerMessage> get messages => _messageController.stream;

  AppServerConnectionState _state = AppServerConnectionState.disconnected;
  AppServerConnectionState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  bool get isConnected => _state == AppServerConnectionState.connected;

  /// Connect to [url] and perform the initialize handshake.
  ///
  /// Throws on connection failure or if already connected.
  Future<void> connect(String url) async {
    if (_state != AppServerConnectionState.disconnected) {
      throw StateError('Already connected or connecting');
    }
    _state = AppServerConnectionState.connecting;
    _lastError = null;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      // Wait for the channel to be ready (throws if the URL is invalid / server
      // is not reachable before the first message).
      await _channel!.ready;
    } catch (e) {
      _state = AppServerConnectionState.error;
      _lastError = e.toString();
      _channel = null;
      rethrow;
    }

    _sub = _channel!.stream.listen(
      (data) => _onRaw(data as String),
      onError: _onWsError,
      onDone: _onWsDone,
    );

    // Perform JSON-RPC initialize handshake.
    await _initialize();
    _state = AppServerConnectionState.connected;
  }

  Future<void> _initialize() async {
    await sendRequest('initialize', {
      'clientInfo': {
        'name': 'xiao_pangxie_workbench',
        'title': '小螃蟹工作台',
        'version': '0.1.0',
      },
    });
    // Acknowledge with the initialized notification (no id).
    _sendRaw({'method': 'initialized', 'params': {}});
  }

  /// Send a JSON-RPC request and return the result.
  ///
  /// Throws on JSON-RPC error or timeout.
  Future<dynamic> sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _sendRaw({'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Request $method timed out', const Duration(seconds: 30));
      },
    );
  }

  /// Send a response to a server-initiated request (e.g. approval).
  void sendResponse(dynamic requestId, Map<String, dynamic> result) {
    _sendRaw({'id': requestId, 'result': result});
  }

  void _sendRaw(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  void _onRaw(String data) {
    final AppServerMessage msg;
    try {
      msg = parseAppServerMessage(data);
    } catch (e) {
      // Malformed message — emit as raw info and continue.
      _messageController.add(AppServerNotification(
        method: '__parse_error__',
        params: {'raw': data, 'error': e.toString()},
      ));
      return;
    }

    // Resolve pending client request if this is a matching response.
    if (msg is AppServerResponse) {
      final id = msg.id;
      if (id is int && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (msg.error != null) {
          completer.completeError(
            Exception('JSON-RPC error: ${msg.error}'),
          );
        } else {
          completer.complete(msg.result);
        }
        // Still broadcast so controller can observe responses if needed.
      }
    }

    _messageController.add(msg);
  }

  void _onWsError(Object error, StackTrace st) {
    _lastError = error.toString();
    _state = AppServerConnectionState.error;
    _messageController.addError(error, st);
    _cleanup();
  }

  void _onWsDone() {
    if (_state == AppServerConnectionState.connected ||
        _state == AppServerConnectionState.connecting) {
      _state = AppServerConnectionState.disconnected;
    }
    _messageController.add(
      AppServerNotification(method: '__ws_closed__', params: {}),
    );
    _cleanup();
  }

  void _cleanup() {
    _sub?.cancel();
    _sub = null;
    // Fail all pending requests.
    for (final c in _pending.values) {
      c.completeError(StateError('WebSocket closed'));
    }
    _pending.clear();
    _channel = null;
  }

  /// List threads, optionally filtered by working directory.
  /// If [cwd] is null, returns all threads regardless of directory.
  Future<List<dynamic>> listThreads([String? cwd]) async {
    final params = <String, dynamic>{};
    if (cwd != null) params['cwd'] = cwd;
    final result = await sendRequest('thread/list', params);
    final m = result as Map<String, dynamic>;
    // app-server returns the list under 'data' (not 'threads')
    return m['data'] as List<dynamic>? ?? m['threads'] as List<dynamic>? ?? [];
  }

  /// Resume an existing thread by ID.
  Future<dynamic> resumeThread(String threadId) async {
    return await sendRequest('thread/resume', {'threadId': threadId});
  }

  /// Read thread details including turns history.
  Future<dynamic> readThread(String threadId, {bool includeTurns = false}) async {
    return await sendRequest('thread/read', {
      'threadId': threadId,
      'includeTurns': includeTurns,
    });
  }

  /// Archive (soft-delete) a thread. It won't appear in thread/list afterwards.
  Future<void> archiveThread(String threadId) async {
    await sendRequest('thread/archive', {'threadId': threadId});
  }

  /// Rename a thread on the server.
  Future<void> renameThread(String threadId, String name) async {
    await sendRequest('thread/name/set', {'threadId': threadId, 'name': name});
  }

  Future<void> disconnect() async {
    _state = AppServerConnectionState.disconnected;
    await _channel?.sink.close();
    _cleanup();
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
