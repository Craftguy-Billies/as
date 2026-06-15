import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/event.dart';

class EventCard extends StatelessWidget {
  final AgentEvent event;
  const EventCard({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    if (event.isUserMessage) return _buildUserMessage();
    if (event.isAgentMessage) return _buildAgentMessage();
    if (event.isTerminalAction) return _buildTerminalCommand();
    if (event.isFileEditAction) return _buildFileEdit();
    if (event.isSearchAction) return _buildSearchResult();
    if (event.isError) return _buildError();
    if (event.isObservation) return _buildObservation();

    // Generic fallback
    return _buildGeneric();
  }

  Widget _buildUserMessage() {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: const Radius.circular(4),
          ),
        ),
        child: Text(
          event.messageJson ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildAgentMessage() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16).copyWith(
          bottomLeft: const Radius.circular(4),
        ),
        border: Border.all(color: const Color(0xFF2A2A4E)),
      ),
      child: Text(
        event.messageJson ?? '',
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
    );
  }

  Widget _buildTerminalCommand() {
    Map<String, dynamic>? action;
    try {
      action = event.actionJson != null
          ? json.decode(event.actionJson!) as Map<String, dynamic>
          : null;
    } catch (_) {}

    final command = action?['command'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, color: Color(0xFF00FF88), size: 16),
              const SizedBox(width: 8),
              const Text(
                'Terminal',
                style: TextStyle(color: Color(0xFF00FF88), fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Builder(
                builder: (ctx) => GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: command));
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(Icons.copy, color: Colors.grey, size: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              '\$ $command',
              style: const TextStyle(
                color: Color(0xFF00FF88),
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileEdit() {
    Map<String, dynamic>? action;
    try {
      action = event.actionJson != null
          ? json.decode(event.actionJson!) as Map<String, dynamic>
          : null;
    } catch (_) {}

    final path = action?['path'] as String? ?? action?['file'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A4E)),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit, color: Color(0xFFF59E0B), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              path,
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withAlpha(30),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'editing',
              style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResult() {
    Map<String, dynamic>? action;
    try {
      action = event.actionJson != null
          ? json.decode(event.actionJson!) as Map<String, dynamic>
          : null;
    } catch (_) {}

    final query = action?['query'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A4E)),
      ),
      child: Row(
        children: [
          const Icon(Icons.public, color: Color(0xFF3B82F6), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              query,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.search, color: Colors.grey, size: 16),
        ],
      ),
    );
  }

  Widget _buildObservation() {
    // Parse observation data
    String text = '';
    final toolName = event.toolName ?? '';
    try {
      if (event.observationJson != null) {
        final obs = json.decode(event.observationJson!) as Map<String, dynamic>;
        if (toolName == 'bash' || toolName == 'terminal' || toolName == 'execute_bash_command') {
          final stdout = obs['stdout'] as String? ?? '';
          final stderr = obs['stderr'] as String? ?? '';
          final exitCode = obs['exit_code'];
          if (stdout.isNotEmpty) text = stdout;
          if (stderr.isNotEmpty) text += '\n[stderr] $stderr';
          if (exitCode != null && exitCode != 0) {
            text += '\n(exit code: $exitCode)';
          }
        } else if (toolName == 'file_editor' || toolName == 'str_replace_editor') {
          text = obs['path'] as String? ?? '';
          final diff = obs['diff'] as String?;
          final content = obs['content'] as String?;
          if (diff != null && diff.isNotEmpty) {
            text += '\n$diff';
          } else if (content != null && content.isNotEmpty) {
            text += '\n$content';
          }
        } else {
          text = event.observationJson!;
        }
      }
    } catch (_) {
      text = event.observationJson ?? '';
    }

    if (text.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A3E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.output, color: Colors.grey[500], size: 14),
              const SizedBox(width: 6),
              Text(
                toolName.isNotEmpty ? '→ $toolName' : '→ result',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            text.length > 500 ? '${text.substring(0, 500)}...' : text,
            style: const TextStyle(
              color: Color(0xFFA0A0B0),
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    String errText = 'An error occurred';
    // Extract useful error info from any available field
    final sources = [
      event.messageJson,
      event.observationJson,
      event.rawJson,
    ];
    for (final src in sources) {
      if (src != null && src.isNotEmpty) {
        errText = src.length > 300 ? '${src.substring(0, 300)}...' : src;
        break;
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3B1010),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF5B2020)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline, color: Colors.red, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              errText,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneric() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.circle, size: 6, color: Colors.grey[700]),
          const SizedBox(width: 8),
          Text(
            event.kind,
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
          if (event.toolName != null) ...[
            const SizedBox(width: 8),
            Text(
              event.toolName!,
              style: TextStyle(color: Colors.grey[700], fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
