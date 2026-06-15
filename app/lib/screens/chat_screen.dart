import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/chat_provider.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _hasLoaded = false;
  bool _showRepoBar = false;
  String _mode = 'code';

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
    // Restore last repo from preferences
    try {
      final prefs = await _loadPrefs();
      _repoCtrl.text = prefs['repo'] ?? '';
      setState(() => _mode = prefs['mode'] ?? 'code');
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
        sp.setString('last_branch', 'main'),
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
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || loading) return;
    _inputCtrl.clear();
    try {
      context.read<ChatProvider>().sendMessage(
        text,
        repo: _repoCtrl.text.trim(),
        branch: 'main',
        mode: _mode,
      );
    } catch (_) {}
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chat', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            if (_repoCtrl.text.isNotEmpty)
              Text(
                '${_repoCtrl.text.trim()} · ${_mode.toUpperCase()}',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
          ],
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

          // Error bar
          if (prov.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.red.shade900,
              child: Text(
                prov.error!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          // Input bar
          _buildInput(prov.loading),
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
      child: Row(
        children: [
          // Repo input
          Expanded(
            child: TextField(
              controller: _repoCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              onChanged: (v) => _saveRepoPrefs(),
              decoration: InputDecoration(
                hintText: 'owner/repo (empty = general chat)',
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
          const SizedBox(width: 8),
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

  Widget _buildInput(bool loading) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Row(
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
                hintText: 'Send a message...',
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
