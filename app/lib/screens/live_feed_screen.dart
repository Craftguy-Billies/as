import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../widgets/event_card.dart';
import '../widgets/status_banner.dart';

class LiveFeedScreen extends StatefulWidget {
  final String taskId;
  const LiveFeedScreen({super.key, required this.taskId});

  @override
  State<LiveFeedScreen> createState() => _LiveFeedScreenState();
}

class _LiveFeedScreenState extends State<LiveFeedScreen>
    with WidgetsBindingObserver {
  final _scrollCtrl = ScrollController();
  bool _showScrollFab = false;
  TaskProvider? _prov;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prov = context.read<TaskProvider>();
    _prov!.startPolling(widget.taskId);

    _scrollCtrl.addListener(() {
      final atBottom =
          _scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 50;
      if (atBottom) {
        _prov!.autoScroll = true;
        if (mounted) setState(() => _showScrollFab = false);
      } else if (_scrollCtrl.position.pixels <
          _scrollCtrl.position.maxScrollExtent - 200) {
        _prov!.autoScroll = false;
        if (mounted) setState(() => _showScrollFab = true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prov?.stopPolling();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final prov = context.read<TaskProvider>();
    if (state == AppLifecycleState.resumed) {
      prov.startPolling(widget.taskId);
    } else if (state == AppLifecycleState.paused) {
      prov.stopPolling();
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<TaskProvider>();
    final events = prov.events;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Live Feed', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0D0D0D),
        actions: [
          if (prov.currentTaskId != null)
            IconButton(
              icon: Icon(
                prov.autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_top,
              ),
              tooltip: prov.autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
              onPressed: () {
                prov.autoScroll = !prov.autoScroll;
                if (prov.autoScroll) _scrollToBottom();
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Status banner
          StatusBanner(taskId: widget.taskId),

          // Event feed
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (prov.feedError == null) ...[
                          const SizedBox(
                            height: 24, width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Waiting for agent...',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ] else ...[
                          const Icon(Icons.cloud_off, color: Colors.red, size: 40),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              prov.feedError!,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                              textAlign: TextAlign.center,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: events.length + 1, // +1 for "show more" at top
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        // "Show more" button
                        return events.length >= 30
                            ? Center(
                                child: TextButton.icon(
                                  onPressed: () => prov.loadMoreEvents(),
                                  icon: const Icon(Icons.expand_less, color: Colors.grey),
                                  label: const Text(
                                    'Show earlier messages',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink();
                      }
                      final event = events[i - 1];
                      return EventCard(event: event);
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: _showScrollFab
          ? FloatingActionButton.small(
              onPressed: _scrollToBottom,
              backgroundColor: const Color(0xFF7C3AED),
              child: const Icon(Icons.arrow_downward, color: Colors.white),
            )
          : null,
    );
  }
}
