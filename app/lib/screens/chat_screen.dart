import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/chat_provider.dart';
import '../providers/task_provider.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  final _branchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _hasLoaded = false;
  bool _showRepoBar = false;
  int _lastMsgCount = -1;  // auto-scroll to bottom when new msgs arrive
  String _mode = 'code';
  String _activeModel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    try {
      final prov = context.read<ChatProvider>();
      await prov.loadFromCache();
    } catch (_) {}
    if (mounted) setState(() => _hasLoaded = true);
    // Restore last repo/branch/mode from preferences
    try {
      final prefs = await _loadPrefs();
      _repoCtrl.text = prefs['repo'] ?? '';
      _branchCtrl.text = prefs['branch'] ?? '';
      setState(() {
        _mode = prefs['mode'] ?? 'code';
        // Auto-show repo bar if a repo was previously configured
        if ((prefs['repo'] ?? '').isNotEmpty) _showRepoBar = true;
      });
    } catch (_) {}
    // Load model from server
    try {
      final sp = await SharedPreferences.getInstance();
      setState(() => _activeModel = sp.getString('last_model') ?? '');
    } catch (_) {}
  }

  Future<Map<String, String?>> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    return {
      'repo': sp.getString('last_repo') ?? '',
      'branch': sp.getString('last_branch') ?? '',
      'mode': sp.getString('last_mode') ?? 'code',
    };
  }

  Future<void> _saveRepoPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await Future.wait([
        sp.setString('last_repo', _repoCtrl.text.trim()),
        sp.setString('last_branch', _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim()),
        sp.setString('last_mode', _mode),
      ]);
    } catch (_) {}
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _repoCtrl.dispose();
    _branchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    if (!mounted) return;
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;

    final repo = _repoCtrl.text.trim();
    if (repo.isNotEmpty && !RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid repo format. Use: owner/repo'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    _inputCtrl.clear();
    _saveRepoPrefs();

    final branch = _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim();
    final prov = context.read<ChatProvider>();

    debugPrint('ChatScreen._send: mode=$_mode repo=$repo');
    prov.send(text, repo: repo, branch: branch, mode: _mode);
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<ChatProvider>();
    final msgs = prov.messages;

    // With reverse:true ListView, offset 0 = bottom. Auto-scroll to
    // bottom when new messages arrive (count changes).
    if (msgs.isNotEmpty && _hasLoaded && msgs.length != _lastMsgCount) {
      _lastMsgCount = msgs.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            0, // reverse:true → 0 = bottom
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (_, chatProv, __) {
            final activeRepo = chatProv.serverRepo.isNotEmpty
                ? chatProv.serverRepo
                : _repoCtrl.text.trim();
            final activeMode = chatProv.serverMode.isNotEmpty
                ? chatProv.serverMode
                : _mode;
            final parts = <String>[];
            if (activeRepo.isNotEmpty) parts.add(activeRepo);
            if (activeRepo.isNotEmpty && chatProv.serverBranch.isNotEmpty) parts.add(chatProv.serverBranch);
            if (activeRepo.isNotEmpty) parts.add(activeMode.toUpperCase());
            if (_activeModel.isNotEmpty) parts.add(_activeModel);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Chat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                if (parts.isNotEmpty)
                  Text(
                    parts.join(' · '),
                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  ),
              ],
            );
          },
        ),
        backgroundColor: const Color(0xFF0D0D0D),
        actions: [
          // Debug log viewer (mobile-visible)
          IconButton(
            icon: const Icon(Icons.bug_report, color: Colors.white70, size: 20),
            tooltip: 'Debug logs',
            onPressed: () {
              final prov = context.read<ChatProvider>();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ClientLogScreen(prov: prov)),
              );
            },
          ),
          // Task log (VIBECODER_LOG.md)
          IconButton(
            icon: const Icon(Icons.checklist, color: Colors.white70, size: 20),
            tooltip: 'Task log',
            onPressed: () => _showTaskLog(context),
          ),
          // Refresh from server
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
            tooltip: 'Refresh messages',
            onPressed: () => context.read<ChatProvider>().refreshMessages(),
          ),
          // Repo/mode toggle
          IconButton(
            icon: Icon(
              _showRepoBar ? Icons.code_off : Icons.code,
              color: _repoCtrl.text.isNotEmpty ? const Color(0xFF7C3AED) : Colors.grey,
            ),
            tooltip: _showRepoBar ? 'Hide repo settings' : 'Repo & mode',
            onPressed: () => setState(() => _showRepoBar = !_showRepoBar),
          ),
          // Always show clear — user needs to reset conversation even when empty
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'New conversation',
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Repo bar (collapsible)
          if (_showRepoBar) _buildRepoBar(prov),

          // Messages — reverse:true renders from bottom natively.
          // Item 0 = bottom of screen. Newest messages at index 0,
          // "Load earlier" button at the end (top of screen).
          Expanded(
            child: _hasLoaded
                ? (msgs.isEmpty
                    ? _buildEmpty()
                    : Builder(builder: (ctx) {
                        final visible = msgs.sublist(prov.showFromIndex);
                        final hasMore = prov.hasMoreMessages;
                        final showTyping = prov.loading;
                        final items = <Widget>[];
                        if (showTyping) items.add(_buildTyping());
                        for (final m in visible.reversed) {
                          items.add(_ChatBubble(msg: m));
                        }
                        if (hasMore) {
                          items.add(Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Center(
                              child: TextButton.icon(
                                onPressed: () => prov.loadMoreMessages(),
                                icon: const Icon(Icons.expand_less, color: Color(0xFF7C3AED), size: 18),
                                label: const Text(
                                  'Load earlier messages',
                                  style: TextStyle(color: Color(0xFF7C3AED), fontSize: 13),
                                ),
                              ),
                            ),
                          ));
                        }
                        return ListView.builder(
                          reverse: true,
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          itemCount: items.length,
                          itemBuilder: (_, i) => items[i],
                        );
                      }))
                : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),

          // Error bar - show full error, no truncation
          if (prov.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.red.shade900,
              child: Text(
                prov.error!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),

          // Input bar
          _buildInput(prov),
        ],
      ),
    );
  }

  Widget _buildRepoBar(ChatProvider prov) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Repo input + saved repos dropdown
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _repoCtrl,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        onChanged: (_) => _saveRepoPrefs(),
                        onSubmitted: (_) {
                          final r = _repoCtrl.text.trim();
                          if (r.isNotEmpty) prov.switchRepo(r, _mode, branch: _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim());
                        },
                        decoration: InputDecoration(
                          hintText: 'owner/repo',
                          hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                          filled: true,
                          fillColor: const Color(0xFF1A1A2E),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          isDense: true,
                        ),
                      ),
                    ),
                    // Saved repos dropdown
                    if (prov.savedRepos.isNotEmpty)
                      PopupMenuButton<Map<String, dynamic>>(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.grey, size: 18),
                        tooltip: 'Saved repos',
                        onSelected: (r) {
                          final repo = r['repo']?.toString() ?? '';
                          final mode = r['mode']?.toString() ?? 'code';
                          _repoCtrl.text = repo == '(none)' ? '' : repo;
                          _saveRepoPrefs();
                          if (repo.isNotEmpty) {
                            _mode = mode;
                            prov.switchRepo(repo, mode, branch: _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim());
                          }
                        },
                        itemBuilder: (_) => prov.savedRepos.map((r) {
                          final repo = r['repo']?.toString() ?? '';
                          final mode = r['mode']?.toString() ?? 'code';
                          final count = (r['message_count'] as int?) ?? 0;
                          return PopupMenuItem(
                            value: r,
                            height: 36,
                            child: Text(
                              '${repo == "(none)" ? "No repo" : repo} [$mode • $count msgs]',
                              style: const TextStyle(fontSize: 12, color: Colors.white70),
                            ),
                          );
                        }).toList(),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // Branch: free-text TextField + popup for suggestions
              Consumer<ChatProvider>(
                builder: (_, prov, __) {
                  final branches = prov.branches;
                  final filtered = branches.isEmpty
                      ? <String>[]
                      : branches.where((b) {
                          final t = _branchCtrl.text.trim();
                          return t.isEmpty || b.toLowerCase().contains(t.toLowerCase());
                        }).toList();
                  return Container(
                    width: 90,
                    height: 30,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _branchCtrl,
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            onChanged: (_) => _saveRepoPrefs(),
                            decoration: InputDecoration(
                              hintText: 'main',
                              hintStyle: TextStyle(color: Colors.grey[700], fontSize: 11),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.only(left: 6, bottom: 2),
                              isDense: true,
                            ),
                          ),
                        ),
                        PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          iconSize: 0,
                          offset: const Offset(0, 30),
                          color: const Color(0xFF1A1A2E),
                          constraints: const BoxConstraints(maxWidth: 140, maxHeight: 250),
                          child: const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 18),
                          onSelected: (v) {
                            _branchCtrl.text = v;
                            _saveRepoPrefs();
                          },
                          itemBuilder: (_) {
                            if (filtered.isEmpty) {
                              return [const PopupMenuItem(value: '', enabled: false, child: Text('No branches', style: TextStyle(color: Colors.white54, fontSize: 12)))];
                            }
                            return filtered.map((b) => PopupMenuItem(value: b, child: Text(b, style: const TextStyle(color: Colors.white, fontSize: 12)))).toList();
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 6),
              // Mode label (code-only, plan mode hidden)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Text(
                  'Code',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          // Task queue mini-preview
          const SizedBox(height: 6),
          Consumer<TaskProvider>(
            builder: (_, tp, __) {
              final active = tp.tasks.where((t) => t.isRunning || t.isQueued).toList();
              if (active.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () => _showTaskSheet(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.queue_play_next, size: 14, color: Colors.grey[500]),
                      const SizedBox(width: 6),
                      Text('${active.length} task${active.length > 1 ? 's' : ''} in queue',
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                      const Spacer(),
                      Icon(Icons.keyboard_arrow_up, size: 16, color: Colors.grey[600]),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showTaskSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TaskQueueSheet(),
    );
  }

  void _showTaskLog(BuildContext context) {
    final prov = context.read<ChatProvider>();
    prov.fetchTaskLog();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TaskLogSheet(),
    );
  }
  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey[700]),
          const SizedBox(height: 16),
          Text(
            'Token-efficient chat mode',
            style: TextStyle(color: Colors.grey[500], fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Reuses conversation — much cheaper than tasks',
            style: TextStyle(color: Colors.grey[700], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildTyping() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _TypingIndicator(),
      ),
    );
  }

  Widget _buildInput(ChatProvider prov) {
    final loading = prov.loading;
    final processing = prov.isProcessing;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Queue progress bar — always visible when processing
          if (processing)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: const Color(0xFF1A1A2E),
              child: Row(
                children: [
                  const Icon(Icons.queue_play_next, color: Color(0xFF7C3AED), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prov.queueTotal > 0
                              ? 'Processing ${prov.queuePosition}/${prov.queueTotal}'
                              : 'Processing…',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        if (prov.queueTotal > 0) ...[
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: prov.queuePosition / prov.queueTotal,
                              backgroundColor: const Color(0xFF2A2A2A),
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF7C3AED)),
                              minHeight: 3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => prov.cancel(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Cancel', style: TextStyle(color: Colors.red, fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
          // Per-prompt cancel chips — horizontal scrollable
          if (processing && prov.batchPrompts.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: const Color(0xFF16162A),
              child: SizedBox(
                height: 36,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: prov.batchPrompts.length,
                  itemBuilder: (_, i) {
                    final isRunning = i == prov.queuePosition - 1;  // position is 1-based display
                    final mode = i < prov.batchModes.length ? prov.batchModes[i] : 'code';
                    final isPlan = mode == 'plan';
                    final text = prov.batchPrompts[i];
                    final truncated = text.length > 28 ? '${text.substring(0, 28)}…' : text;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isRunning
                              ? const Color(0xFF312E81).withValues(alpha: 0.6)
                              : const Color(0xFF2A2A3E),
                          borderRadius: BorderRadius.circular(8),
                          border: isRunning
                              ? Border.all(color: const Color(0xFF7C3AED), width: 1)
                              : Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isPlan
                                      ? Colors.amber.withValues(alpha: 0.2)
                                      : Colors.cyan.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  isPlan ? 'PL' : 'CD',
                                  style: TextStyle(
                                    color: isPlan ? Colors.amber : Colors.cyan,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                truncated,
                                style: TextStyle(
                                  color: isRunning ? Colors.white : Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => prov.cancelPrompt(i),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.close, color: Colors.redAccent, size: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          // Input row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Send a message…',
                    hintStyle: TextStyle(color: Colors.grey[700]),
                    filled: true,
                    fillColor: const Color(0xFF1A1A2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 44,
                width: 44,
                child: Material(
                  color: const Color(0xFF7C3AED),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: _send,
                    customBorder: const CircleBorder(),
                    child: Center(
                      child: processing
                          ? const Icon(Icons.add_rounded, color: Colors.white, size: 20)
                          : loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Clear Chat', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Delete all messages? The conversation will reset on the server.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<ChatProvider>().clearChat();
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat bubble
// ---------------------------------------------------------------------------
class _ChatBubble extends StatelessWidget {
  final ChatMessage msg;
  const _ChatBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    final isEvent = msg.role == 'event';
    final isError = msg.role == 'error';

    if (isEvent) return _buildEvent(context);

    if (isError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 14),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                msg.content,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13, height: 1.45),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF7C3AED) : const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(4),
                  bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  isUser
                      ? SelectableText(
                          msg.content,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            height: 1.45,
                          ),
                        )
                      : SelectionArea(
                          child: MarkdownBody(
                          data: msg.content,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.45),
                            code: TextStyle(
                              color: const Color(0xFFA78BFA),
                              backgroundColor: Colors.white.withAlpha(20),
                              fontSize: 13,
                              fontFamily: 'monospace',
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: const Color(0xFF0D0D1A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            blockquoteDecoration: BoxDecoration(
                              border: const Border(left: BorderSide(color: Color(0xFF7C3AED), width: 3)),
                              color: const Color(0xFF7C3AED).withAlpha(20),
                            ),
                            a: const TextStyle(color: Color(0xFFA78BFA)),
                            h1: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                            h2: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                            h3: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                            listBullet: const TextStyle(color: Color(0xFF7C3AED)),
                          ),
                        ),
                      ),
                  const SizedBox(height: 4),
                  Text(
                    _fmtTime(msg.timestamp),
                    style: TextStyle(
                      color: Colors.white.withAlpha(80),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildEvent(BuildContext context) {
    // Compact inline event display — tool calls, observations, etc.
    // Backend sends text tags like [READ], [EDIT], [ERROR] instead of emoji
    Color accent;
    IconData icon;
    if (msg.content.startsWith('[TERMINAL]')) { accent = const Color(0xFF00FF88); icon = Icons.terminal; }
    else if (msg.content.startsWith('[READ]')) { accent = const Color(0xFF10B981); icon = Icons.menu_book; }
    else if (msg.content.startsWith('[EDIT]')) { accent = const Color(0xFFF59E0B); icon = Icons.edit; }
    else if (msg.content.startsWith('[UNDO]')) { accent = Colors.orangeAccent; icon = Icons.undo; }
    else if (msg.content.startsWith('[SEARCH]')) { accent = const Color(0xFF3B82F6); icon = Icons.search; }
    else if (msg.content.startsWith('[BROWSER]')) { accent = const Color(0xFF06B6D4); icon = Icons.public; }
    else if (msg.content.startsWith('[OUT]')) { accent = Colors.grey; icon = Icons.output; }
    else if (msg.content.startsWith('[WARN]')) { accent = Colors.orangeAccent; icon = Icons.warning_amber; }
    else if (msg.content.startsWith('[FILE]')) { accent = const Color(0xFF10B981); icon = Icons.description; }
    else if (msg.content.startsWith('[RESULTS]')) { accent = const Color(0xFF8B5CF6); icon = Icons.bar_chart; }
    else if (msg.content.startsWith('[ERROR]')) { accent = Colors.redAccent; icon = Icons.error; }
    else if (msg.content.startsWith('[STOP]')) { accent = Colors.grey; icon = Icons.stop_circle; }
    else if (msg.content.startsWith('[MSG]')) { accent = Colors.white70; icon = Icons.chat_bubble_outline; }
    else if (msg.content.startsWith('[STATUS]')) { accent = const Color(0xFF3B82F6); icon = Icons.info_outline; }
    else if (msg.content.startsWith('[WORKING]')) { accent = const Color(0xFF22C55E); icon = Icons.hourglass_top; }
    else if (msg.content.startsWith('[DONE]')) { accent = const Color(0xFF22C55E); icon = Icons.check_circle; }
    else { accent = Colors.grey; icon = Icons.settings; }

    // Strip text tag prefix like "[READ] " for display (icon already conveys meaning)
    final displayText = _stripTagPrefix(msg.content);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 12, color: accent),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              displayText,
              maxLines: 15,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent.withAlpha(200),
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Strip text tag prefix like "[READ] " or "[EDIT] " for display.
  /// The icon already conveys the meaning; we only show the description.
  static String _stripTagPrefix(String text) {
    if (text.isEmpty) return text;
    final m = RegExp(r'^\[[A-Z]+\]\s?').firstMatch(text);
    if (m == null) return text;
    final stripped = text.substring(m.end);
    return stripped.isEmpty ? '(no details)' : stripped;
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ---------------------------------------------------------------------------
// Typing indicator
// ---------------------------------------------------------------------------
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Opacity(
        opacity: 0.4 + (_ctrl.value * 0.6),
        child: child,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(0),
            const SizedBox(width: 4),
            _dot(1),
            const SizedBox(width: 4),
            _dot(2),
          ],
        ),
      ),
    );
  }

  Widget _dot(int i) {
    return Container(
      height: 6,
      width: 6,
      decoration: BoxDecoration(
        color: Colors.grey[500],
        shape: BoxShape.circle,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Task queue bottom sheet
// ---------------------------------------------------------------------------
class _TaskLogSheet extends StatefulWidget {
  @override
  State<_TaskLogSheet> createState() => _TaskLogSheetState();
}

class _TaskLogSheetState extends State<_TaskLogSheet> {
  int? _expandedIndex;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) {
        return Consumer<ChatProvider>(
          builder: (_, prov, __) {
            final entries = prov.taskLog;
            if (entries.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[700]),
                    const SizedBox(height: 12),
                    Text(
                      'No task log yet',
                      style: TextStyle(color: Colors.grey[500], fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Completed tasks appear here automatically',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[700], fontSize: 12),
                    ),
                  ],
                ),
              );
            }
            // Latest first, filter entries older than 3 days
            final now = DateTime.now();
            final filtered = entries.where((e) {
              final ts = e['timestamp']?.toString() ?? '';
              if (ts.isEmpty) return true;
              try {
                final t = DateTime.parse(ts);
                return now.difference(t).inHours < 72;
              } catch (_) {
                return true;
              }
            }).toList().reversed.toList();
            if (filtered.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[700]),
                    const SizedBox(height: 12),
                    Text(
                      'No recent tasks',
                      style: TextStyle(color: Colors.grey[500], fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tasks from the last 3 days appear here',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[700], fontSize: 12),
                    ),
                  ],
                ),
              );
            }
            return ListView.builder(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(16),
              itemCount: filtered.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.checklist, color: Color(0xFF7C3AED), size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Task Log  ·  ${filtered.length} done',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final e = filtered[i - 1];
                final status = (e['status'] ?? '').toString();
                final isOK = status.contains('[OK]') || status.toLowerCase().contains('success');
                final isFail = status.contains('[FAIL]') || status.toLowerCase().contains('failed');
                final isExpanded = _expandedIndex == (i - 1);
                return GestureDetector(
                  onTap: () => setState(() {
                    _expandedIndex = isExpanded ? null : (i - 1);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isOK
                            ? Colors.green.withValues(alpha: 0.3)
                            : isFail
                                ? Colors.red.withValues(alpha: 0.3)
                                : Colors.grey.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Row 1: status icon + AI report
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                isOK
                                    ? Icons.check_circle_outline
                                    : isFail
                                        ? Icons.cancel_outlined
                                        : Icons.warning_amber_outlined,
                                size: 18,
                                color: isOK
                                    ? Colors.green
                                    : isFail
                                        ? Colors.redAccent
                                        : Colors.orange,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                (e['details'] ?? e['summary'] ?? '').toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: isExpanded ? null : 4,
                                overflow: isExpanded ? null : TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        // Expanded section: full request + status
                        AnimatedCrossFade(
                          firstChild: const SizedBox(width: double.infinity),
                          secondChild: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Status line
                                Row(
                                  children: [
                                    Icon(
                                      isOK
                                          ? Icons.check_circle
                                          : isFail
                                              ? Icons.cancel
                                              : Icons.warning_amber,
                                      size: 14,
                                      color: isOK
                                          ? Colors.green
                                          : isFail
                                              ? Colors.redAccent
                                              : Colors.orange,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      status,
                                      style: TextStyle(
                                        color: isOK
                                            ? Colors.green
                                            : isFail
                                                ? Colors.redAccent
                                                : Colors.orange,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                // Full request
                                if ((e['request'] ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Your request:',
                                    style: TextStyle(color: Colors.grey[600], fontSize: 10),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    e['request']!,
                                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                                  ),
                                ],
                                if ((e['files'] ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(Icons.insert_drive_file_outlined, size: 12, color: Colors.grey[600]),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          e['files']!,
                                          style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          crossFadeState: isExpanded
                              ? CrossFadeState.showSecond
                              : CrossFadeState.showFirst,
                          duration: const Duration(milliseconds: 200),
                        ),
                        // Timestamp + tap hint
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!isExpanded)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text(
                                  'Tap to expand',
                                  style: TextStyle(color: Colors.grey[800], fontSize: 9),
                                ),
                              ),
                            Text(
                              e['timestamp'] ?? '',
                              style: TextStyle(color: Colors.grey[700], fontSize: 10),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _TaskQueueSheet extends StatelessWidget {
  const _TaskQueueSheet();

  @override
  Widget build(BuildContext context) {
    final tasks = context.watch<TaskProvider>().tasks;
    final active = tasks.where((t) => t.status == 'running' || t.status == 'starting' || t.status == 'queued').toList();
    final done = tasks.where((t) => t.status == 'completed' || t.status == 'failed').toList();
    
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[600],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.queue_play_next, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                const Text('Task Queue', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${tasks.length} total', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
              ],
            ),
          ),
          const Divider(color: Color(0xFF2A2A2A)),
          // Task list
          Flexible(
            child: tasks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No tasks yet', style: TextStyle(color: Colors.grey[600])),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: tasks.length,
                    itemBuilder: (_, i) {
                      final t = tasks[i];
                      final isActive = t.status == 'running' || t.status == 'starting' || t.status == 'queued';
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          t.status == 'completed' ? Icons.check_circle : 
                          t.status == 'failed' ? Icons.error :
                          t.status == 'running' ? Icons.sync : Icons.hourglass_empty,
                          size: 18,
                          color: t.status == 'completed' ? Colors.green :
                                 t.status == 'failed' ? Colors.red :
                                 t.status == 'running' ? const Color(0xFF7C3AED) : Colors.grey,
                        ),
                        title: Text(
                          t.prompt.length > 60 ? '${t.prompt.substring(0, 60)}...' : t.prompt,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${t.status} · ${t.repo}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.pushNamed(context, '/tasks/${t.id}');
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// -- In-app client log viewer (visible on mobile builds) --
class ClientLogScreen extends StatelessWidget {
  final ChatProvider prov;
  const ClientLogScreen({super.key, required this.prov});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Debug Logs', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 20),
            tooltip: 'Clear logs',
            onPressed: () {
              // Navigate to refresh — logs clear on provider rebuild
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: prov,
        builder: (context, _) {
          final logs = prov.logLines;
          if (logs.isEmpty) {
            return const Center(
              child: Text('No logs yet', style: TextStyle(color: Colors.white38)),
            );
          }
          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, i) {
              final line = logs[i];
              Color color = Colors.white54;
              if (line.contains('ERROR') || line.contains('fail') || line.contains('TIMEOUT')) {
                color = Colors.redAccent;
              } else if (line.contains('START') || line.contains('DONE') || line.contains('complete')) {
                color = Colors.greenAccent;
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    height: 1.4,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

