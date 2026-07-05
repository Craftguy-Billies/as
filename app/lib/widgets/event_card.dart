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
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: command));
                  HapticFeedback.lightImpact();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Command copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: const Icon(Icons.copy, color: Colors.grey, size: 14),
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

  Widget _buildError() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3B1010),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF5B2020)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'An error occurred',
              style: TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Render an observation event (command output, file-diff results, etc.).
  /// Observations appear right after their corresponding action in the feed,
  /// so they read naturally as inline output.
  Widget _buildObservation() {
    Map<String, dynamic>? obs;
    try {
      obs = event.observationJson != null
          ? json.decode(event.observationJson!) as Map<String, dynamic>
          : null;
    } catch (_) {}

    if (obs == null) return const SizedBox.shrink();

    final content = obs['content'] as String? ?? '';
    final extractedContent = obs['extracted_content'] as String? ?? '';
    final exitCode = obs['exit_code'];
    final displayContent = extractedContent.isNotEmpty ? extractedContent : content;

    if (displayContent.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 24, right: 12, bottom: 4),
      child: _CollapsibleOutput(
        content: displayContent,
        exitCode: exitCode is int ? exitCode : null,
        isError: exitCode is int && exitCode != 0,
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

/// A collapsible block showing terminal/file-output content.
/// When content exceeds [maxPreviewLines], a "Show more/less" toggle appears.
class _CollapsibleOutput extends StatefulWidget {
  final String content;
  final int? exitCode;
  final bool isError;

  const _CollapsibleOutput({
    required this.content,
    this.exitCode,
    this.isError = false,
  });

  @override
  State<_CollapsibleOutput> createState() => _CollapsibleOutputState();
}

class _CollapsibleOutputState extends State<_CollapsibleOutput> {
  bool _expanded = false;
  static const int maxPreviewLines = 6;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(widget.content);
    final isLong = lines.length > maxPreviewLines;
    final displayLines = isLong && !_expanded
        ? lines.take(maxPreviewLines).toList()
        : lines;
    final displayText = displayLines.join('\n');
    final trailingNewline = isLong && !_expanded && lines.length > maxPreviewLines
        ? '... (${lines.length - maxPreviewLines} more lines)'
        : null;

    return Container(
      decoration: BoxDecoration(
        color: widget.isError
            ? const Color(0xFF2A1010)
            : const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.isError
              ? const Color(0xFF5B2020)
              : const Color(0xFF222222),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: output label + optional exit code
          if (widget.exitCode != null || isLong)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  Icon(
                    widget.isError ? Icons.error : Icons.output,
                    size: 12,
                    color: widget.isError ? Colors.redAccent : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Output',
                    style: TextStyle(
                      color: widget.isError ? Colors.redAccent : Colors.grey,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (widget.exitCode != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: widget.isError
                            ? Colors.red.withAlpha(30)
                            : Colors.green.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'exit ${widget.exitCode}',
                        style: TextStyle(
                          color: widget.isError ? Colors.redAccent : const Color(0xFF00FF88),
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // Content
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: SelectableText(
              displayText,
              style: TextStyle(
                color: widget.isError ? Colors.redAccent[100] : const Color(0xFFCCCCCC),
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),

          // Trailing "more lines" hint
          if (trailingNewline != null)
            Padding(
              padding: const EdgeInsets.only(left: 10, bottom: 4),
              child: Text(
                trailingNewline,
                style: TextStyle(color: Colors.grey[600], fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ),

          // Show more/less button
          if (isLong)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey[800]!)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: Colors.grey[500],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _expanded ? 'Show less' : 'Show all (${lines.length} lines)',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
