import 'package:flutter/material.dart';
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
      _branchCtrl.text = prefs['branch'] ?? 'main';
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
      'branch': sp.getString('last_branch') ?? 'main',
      'mode': sp.getString('last_mode') ?? 'code',
    };
  }

  Future<void> _saveRepoPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await Future.wait([
        sp.setString('last_repo', _repoCtrl.text.trim()),
        sp.setString('last_branch', _branchCtrl.text.trim().isEmpty ? 'main' : _branchCtrl.text.trim()),
        sp.setString('last_mode', _mode),
      ]);
    } catch (_) {}
  }

  void _setMode(String m) {
    setState(() => _mode = m);
    _saveRepoPrefs();
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

    final branch = _branchCtrl.text.trim().isEmpty ? 'main' : _branchCtrl.text.trim();
    final prov = context.read<ChatProvider>();

    debugPrint('ChatScreen._send: mode=$_mode repo=$repo');
    prov.send(text, repo: repo, branch: branch, mode: _mode);
  }

  void _scrollDown() {
    if (_scrollCtrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<ChatProvider>();
    final msgs = prov.messages;

    // Auto-scroll when new messages arrive (post-build, not during build)
    if (msgs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
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
          if (_showRepoBar) _buildRepoBar(),

          // Messages
          Expanded(
            child: _hasLoaded
                ? (msgs.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: msgs.length + (prov.loading ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= msgs.length) return _buildTyping();
                          return _ChatBubble(msg: msgs[i]);
                        },
                      ))
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

  Widget _buildRepoBar() {
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
              // Repo input
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _repoCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: (_) => _saveRepoPrefs(),
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
              const SizedBox(width: 6),
              // Branch input
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _branchCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: (_) => _saveRepoPrefs(),
                  decoration: InputDecoration(
                    hintText: 'main',
                    hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF1A1A2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Plan / Code mode toggle
              InkWell(
                onTap: () => _setMode(_mode == 'code' ? 'plan' : 'code'),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _mode == 'plan'
                        ? const Color(0xFF7C3AED).withValues(alpha: 0.2)
                        : const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _mode == 'plan'
                          ? const Color(0xFF7C3AED).withValues(alpha: 0.5)
                          : const Color(0xFF2A2A2A),
                    ),
                  ),
                  child: Text(
                    _mode == 'plan' ? 'Plan' : 'Code',
                    style: TextStyle(
                      color: _mode == 'plan' ? const Color(0xFF7C3AED) : Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
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
                  color: loading ? const Color(0xFF7C3AED).withValues(alpha: 0.5) : const Color(0xFF7C3AED),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: loading ? null : _send,
                    customBorder: const CircleBorder(),
                    child: Center(
                      child: loading
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

    if (isEvent) return _buildEvent(context);

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
                  Text(
                    msg.content,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      height: 1.45,
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
    Color accent;
    IconData icon;
    if (msg.content.startsWith('💬')) { accent = Colors.white70; icon = Icons.chat_bubble_outline; }
    else if (msg.content.startsWith('💻')) { accent = const Color(0xFF00FF88); icon = Icons.terminal; }
    else if (msg.content.startsWith('📝')) { accent = const Color(0xFFF59E0B); icon = Icons.edit; }
    else if (msg.content.startsWith('🔍')) { accent = const Color(0xFF3B82F6); icon = Icons.search; }
    else if (msg.content.startsWith('🌐')) { accent = const Color(0xFF06B6D4); icon = Icons.public; }
    else if (msg.content.startsWith('📤')) { accent = Colors.grey; icon = Icons.output; }
    else if (msg.content.startsWith('📄')) { accent = const Color(0xFF10B981); icon = Icons.description; }
    else if (msg.content.startsWith('📊')) { accent = const Color(0xFF8B5CF6); icon = Icons.bar_chart; }
    else if (msg.content.startsWith('❌')) { accent = Colors.redAccent; icon = Icons.error; }
    else if (msg.content.startsWith('⚠')) { accent = Colors.orangeAccent; icon = Icons.warning_amber; }
    else if (msg.content.startsWith('🔵')) { accent = const Color(0xFF3B82F6); icon = Icons.play_circle_outline; }
    else if (msg.content.startsWith('🟢')) { accent = const Color(0xFF22C55E); icon = Icons.play_circle; }
    else if (msg.content.startsWith('✅')) { accent = const Color(0xFF22C55E); icon = Icons.check_circle; }
    else if (msg.content.startsWith('⏹️')) { accent = Colors.grey; icon = Icons.stop_circle; }
    else if (msg.content.startsWith('📋')) { accent = Colors.grey; icon = Icons.code; }
    else { accent = Colors.grey; icon = Icons.settings; }

    // All events get full visibility — debuggable
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
              msg.content,
              style: TextStyle(
                color: accent.withAlpha(200),
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
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

