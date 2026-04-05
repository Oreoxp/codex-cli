/// A single chat message displayed in the chat view.
enum ChatRole { user, assistant }

class ChatMessage {
  final DateTime timestamp;
  final ChatRole role;
  final String text;

  const ChatMessage({
    required this.timestamp,
    required this.role,
    required this.text,
  });

  ChatMessage copyWith({String? text}) => ChatMessage(
        timestamp: timestamp,
        role: role,
        text: text ?? this.text,
      );
}
