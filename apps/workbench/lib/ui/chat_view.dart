import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';
import '../models/chat_message.dart';

/// Chat-style message list.  Displays committed messages plus a streaming
/// "thinking" bubble while a turn is in progress.
class ChatView extends StatefulWidget {
  final WorkbenchController controller;

  const ChatView({super.key, required this.controller});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final msgs = ctrl.chatMessages;
    final streaming = ctrl.streamingText;
    final showStreaming = ctrl.isInProgress && streaming.isNotEmpty;

    if (msgs.isEmpty && !ctrl.isInProgress) {
      return const Center(
        child: Text(
          'Send a prompt to get started.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final itemCount = msgs.length + (showStreaming ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: itemCount,
      itemBuilder: (context, i) {
        if (i < msgs.length) {
          return _ChatBubble(message: msgs[i]);
        }
        // Streaming assistant bubble.
        return _ChatBubble(
          message: ChatMessage(
            timestamp: DateTime.now(),
            role: ChatRole.assistant,
            text: streaming,
          ),
          isStreaming: true,
        );
      },
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isStreaming;

  const _ChatBubble({required this.message, this.isStreaming = false});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final bgColor = isUser
        ? const Color(0xFF1E4A8C)
        : const Color(0xFF2A2A2A);
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final ts = _fmt(message.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!isUser) ...[
                const CircleAvatar(
                  radius: 10,
                  backgroundColor: Color(0xFF444444),
                  child: Icon(Icons.smart_toy, size: 12, color: Colors.white60),
                ),
                const SizedBox(width: 6),
                Text(
                  'Assistant',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (isStreaming) ...[
                  const SizedBox(width: 6),
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                ],
              ],
              if (isUser)
                Text(
                  'You',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: isUser
                      ? const Radius.circular(12)
                      : const Radius.circular(2),
                  bottomRight: isUser
                      ? const Radius.circular(2)
                      : const Radius.circular(12),
                ),
              ),
              child: SelectableText(
                message.text,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            ts,
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}
