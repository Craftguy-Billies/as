import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../models/task.dart';

class StatusBanner extends StatelessWidget {
  final String taskId;
  const StatusBanner({super.key, required this.taskId});

  String _formatTime(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso.length >= 19 ? iso.substring(11, 19) : iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<TaskProvider>();
    Task? task;
    try {
      task = prov.tasks.firstWhere((t) => t.id == taskId);
    } catch (_) {}

    final status = task?.status ?? 'queued';
    final mode = task?.mode ?? 'code';
    final errorMsg = task?.errorMessage;

    IconData icon;
    String text;
    Color color;

    switch (status) {
      case 'queued':
        icon = Icons.hourglass_empty;
        text = 'Queued...';
        color = Colors.grey;
      case 'starting':
        icon = Icons.play_circle_outline;
        text = mode == 'plan' ? '📋 Planning...' : '⚡ Starting agent...';
        color = Colors.amber;
      case 'running':
        icon = Icons.sync;
        text = mode == 'plan' ? '🔨 Implementing plan...' : '⚡ Agent is working...';
        color = Colors.blue;
      case 'completed':
        icon = Icons.check_circle;
        text = '✅ Completed';
        color = Colors.green;
      case 'failed':
        icon = Icons.error;
        text = errorMsg != null && errorMsg.isNotEmpty
            ? '❌ $errorMsg'
            : '❌ Failed';
        color = Colors.red;
      default:
        icon = Icons.help;
        text = status;
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF121212),
      child: Row(
        children: [
          status == 'running'
              ? const SizedBox(
                  height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                )
              : Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w500),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          if (task?.completedAt != null)
            Text(
              _formatTime(task!.completedAt),
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
        ],
      ),
    );
  }
}
