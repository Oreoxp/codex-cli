import 'package:flutter/material.dart';

import '../controllers/workbench_controller.dart';
import '../models/event_entry.dart';

/// Scrolling list of event entries received from app-server.
class EventList extends StatefulWidget {
  final WorkbenchController controller;

  const EventList({super.key, required this.controller});

  @override
  State<EventList> createState() => _EventListState();
}

class _EventListState extends State<EventList> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(EventList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll to bottom when new events arrive.
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
    final events = widget.controller.events;

    if (events.isEmpty) {
      return const Center(
        child: Text(
          'No events yet.\nConnect and send a prompt.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: events.length,
      itemBuilder: (context, index) => _EventTile(event: events[index]),
    );
  }
}

class _EventTile extends StatelessWidget {
  final EventEntry event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final color = _colorForKind(event.kind);
    final ts = _formatTime(event.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              ts,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.grey,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              event.summary,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontFamily: 'monospace',
                fontWeight: event.isApproval || event.isError
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForKind(EventKind kind) {
    switch (kind) {
      case EventKind.connected:
        return Colors.green;
      case EventKind.disconnected:
        return Colors.orange;
      case EventKind.turnStarted:
        return Colors.blue;
      case EventKind.turnCompleted:
        return Colors.blueAccent;
      case EventKind.itemStarted:
        return Colors.teal;
      case EventKind.itemCompleted:
        return Colors.teal.shade200;
      case EventKind.agentMessageDelta:
        return Colors.white;
      case EventKind.commandOutput:
        return Colors.grey.shade400;
      case EventKind.approvalRequest:
        return Colors.yellow.shade700;
      case EventKind.approvalResolved:
        return Colors.green.shade400;
      case EventKind.error:
        return Colors.red;
      case EventKind.info:
        return Colors.grey.shade500;
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}
