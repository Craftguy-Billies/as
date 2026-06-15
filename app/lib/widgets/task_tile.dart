import 'package:flutter/material.dart';
import '../models/task.dart';

class TaskTile extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const TaskTile({
    super.key,
    required this.task,
    required this.onTap,
    required this.onDelete,
  });

  static String _safeTime(String iso) {
    if (iso.length >= 19) return iso.substring(11, 19);
    return iso;
  }

  IconData get _statusIcon {
    switch (task.status) {
      case 'queued': return Icons.hourglass_empty;
      case 'starting': return Icons.play_circle_outline;
      case 'running': return Icons.sync;
      case 'completed': return Icons.check_circle;
      case 'failed': return Icons.error;
      default: return Icons.help;
    }
  }

  Color get _statusColor {
    switch (task.status) {
      case 'queued': return Colors.grey;
      case 'starting': return Colors.amber;
      case 'running': return Colors.blue;
      case 'completed': return Colors.green;
      case 'failed': return Colors.red;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(task.id),
      direction: task.isQueued || task.isFailed
          ? DismissDirection.endToStart
          : DismissDirection.none,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: Card(
        color: const Color(0xFF1A1A2E),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                if (task.isRunning)
                  const SizedBox(
                    height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(_statusIcon, color: _statusColor, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.prompt,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: task.mode == 'plan'
                                  ? Colors.purple.withAlpha(40)
                                  : Colors.blue.withAlpha(40),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              task.mode.toUpperCase(),
                              style: TextStyle(
                                color: task.mode == 'plan' ? Colors.purpleAccent : Colors.blueAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            task.repo,
                            style: TextStyle(color: Colors.grey[600], fontSize: 11),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _safeTime(task.createdAt),
                            style: TextStyle(color: Colors.grey[700], fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey[700]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
