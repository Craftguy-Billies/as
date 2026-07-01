import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/preferences_service.dart';
import '../widgets/branch_popup.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  final _branchCtrl = TextEditingController();
  Timer? _repoDebounceTimer;  // debounce for switching repo on typing
  final _scrollCtrl = ScrollController();
  final _inputFocusNode = FocusNode();
  bool _hasLoaded = false;
  bool _showRepoBar = false;
  int _lastMsgCount = -1;  // auto-scroll to bottom when new msgs arrive
  String _activeModel = '';
  bool _showScrollToBottom = false;  // FAB visible when scrolled up
  bool _implementChecked = false;  // "Implement" checkbox — appends audit guard paragraph
  bool _testChecked = false;       // "Test & Debug" checkbox — appends test prompt
  bool _auditChecked = false;      // "Audit" checkbox — appends audit prompt

  String _lastRepo = '';  // track repo changes to auto-clear branch

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Desktop: Enter → send (via onSubmitted), Shift+Enter → newline
    // Phone:  Send button → send, no physical Enter key
    _inputFocusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          HardwareKeyboard.instance.isShiftPressed) {
        // Insert newline at cursor, prevent onSubmitted from firing
        final text = _inputCtrl.text;
        final sel = _inputCtrl.selection;
        final pos = sel.isValid ? sel.start : text.length;
        _inputCtrl.text = '${text.substring(0, pos)}\n${text.substring(pos)}';
        _inputCtrl.selection = TextSelection.collapsed(offset: pos + 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // DO NOT set _repoCtrl.text from prefs here — we want the FIRST frame
    // to show a loading spinner instead of a stale/empty repo field.
    // _init() will do the full sync and only then show the UI.

    // Listen for repo changes: when user edits repo, clear branch field.
    _repoCtrl.addListener(() {
      final currentRepo = _repoCtrl.text.trim();
      if (currentRepo != _lastRepo) {
        _lastRepo = currentRepo;
        // Clear branch when repo text changes (user typing a new repo)
        _branchCtrl.text = '';
      }
    });

    // Track scroll position to show/hide scroll-to-bottom button.
    // With reverse:true, offset=0=bottom. Show button when offset > 200.
    _scrollCtrl.addListener(() {
      final offset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
      final show = offset > 200;
      if (show != _showScrollToBottom) {
        setState(() => _showScrollToBottom = show);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        0, // reverse:true → 0 = bottom
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _init() async {
    final prov = context.read<ChatProvider>();

    // Step 1: Restore from PreferencesService synchronously (cheap, local).
    final prefs = context.read<PreferencesService>();
    final savedRepo = prefs.lastRepo;
    final savedBranch = prefs.lastBranch;
    debugPrint('[ChatScreen._init] ┌─ PERSISTENCE CHAIN ──────────────────────────────');
    debugPrint('[ChatScreen._init] │ Step1: PreferencesService → repo="$savedRepo" branch="$savedBranch"');
    // Write to controllers immediately so ANY value is better than empty.
    if (savedRepo.isNotEmpty) {
      _repoCtrl.text = savedRepo;
      _showRepoBar = true;
    }
    if (savedBranch.isNotEmpty) {
      _branchCtrl.text = savedBranch;
    }

    // Step 2: Populate ChatProvider with saved repo
    if (savedRepo.isNotEmpty) {
      prov.initRepoFromHome(savedRepo);
      debugPrint('[ChatScreen._init] │ Step2: initRepoFromHome → serverRepo="${prov.serverRepo}"');
    } else {
      debugPrint('[ChatScreen._init] │ Step2: no savedRepo, serverRepo="${prov.serverRepo}" (unchanged)');
    }

    // Step 3: Load cached messages + merge with server.
    // loadFromCache() returns the restored repo (from cache or server).
    // If server is unreachable, cached values still work.
    debugPrint('[ChatScreen._init] │ Step3: calling loadFromCache (serverRepo="${prov.serverRepo}" serverBranch="${prov.serverBranch}")');
    await prov.loadFromCache();
    debugPrint('[ChatScreen._init] │ Step3: loadFromCache done → serverRepo="${prov.serverRepo}" serverBranch="${prov.serverBranch}"');

    // Step 4: ALWAYS sync text controllers from ChatProvider.
    // serverRepo takes priority (both cache & server had a say).
    if (mounted) {
      setState(() {
        debugPrint('[ChatScreen._init] │ Step4: setState decision:');
        debugPrint('[ChatScreen._init] │   prov.serverRepo="${prov.serverRepo}" prov.serverBranch="${prov.serverBranch}"');
        debugPrint('[ChatScreen._init] │   savedRepo="$savedRepo" savedBranch="$savedBranch"');

        if (prov.serverRepo.isNotEmpty) {
          _repoCtrl.text = prov.serverRepo;
          _showRepoBar = true;
          debugPrint('[ChatScreen._init] │   → using serverRepo for _repoCtrl');
        } else if (savedRepo.isNotEmpty) {
          _repoCtrl.text = savedRepo;
          _showRepoBar = true;
          debugPrint('[ChatScreen._init] │   → falling back to savedRepo for _repoCtrl');
        } else {
          debugPrint('[ChatScreen._init] │   → no repo available, _repoCtrl stays empty');
        }
        if (prov.serverBranch.isNotEmpty) {
          _branchCtrl.text = prov.serverBranch;
          debugPrint('[ChatScreen._init] │   → using serverBranch for _branchCtrl');
        } else if (savedBranch.isNotEmpty) {
          _branchCtrl.text = savedBranch;
          debugPrint('[ChatScreen._init] │   → falling back to savedBranch for _branchCtrl');
        } else {
          debugPrint('[ChatScreen._init] │   → no branch, _branchCtrl stays empty');
        }
        _hasLoaded = true;
      });
      debugPrint('[ChatScreen._init] │ Step4: setState done, repoCtrl="${_repoCtrl.text}" branchCtrl="${_branchCtrl.text}"');
      // Persist whatever we ended up with so next boot is faster
      if ((_repoCtrl.text.isNotEmpty || prov.serverRepo.isNotEmpty) && mounted) {
        _saveRepoPrefs();
        debugPrint('[ChatScreen._init] │ Step5: saved to PreferencesService: repo="${_repoCtrl.text}" branch="${_branchCtrl.text}"');
      }
      debugPrint('[ChatScreen._init] └──────────────────────────────────────────────────');
    }

    // Load model preference + test checkbox state
    try {
      final sp = await SharedPreferences.getInstance();
      setState(() => _activeModel = sp.getString('last_model') ?? '');
      setState(() => _testChecked = sp.getBool('test_enabled') ?? false);
    } catch (e) {
      debugPrint('[ChatScreen._init] model load error: $e');
    }
  }

  Future<void> _saveRepoPrefs() async {
    try {
      context.read<PreferencesService>().saveLastPrompt(
        _repoCtrl.text.trim(),
        _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim(),
        'code',
      );
    } catch (e) {
      debugPrint('[ChatScreen._saveRepoPrefs] error: $e');
    }
  }

  /// Switch to the repo typed in the text field immediately (no send needed).
  void _switchToRepo() {
    _repoDebounceTimer?.cancel();
    final r = _repoCtrl.text.trim();
    if (r.isEmpty) return;
    final prov = context.read<ChatProvider>();
    final branch = _branchCtrl.text.trim();
    if (r != prov.serverRepo) {
      prov.switchRepo(r, 'code', branch: branch);
      debugPrint('[ChatScreen] immediate switch to repo=$r branch=$branch');
    }
  }

  /// Debounced repo switch — fires 600ms after typing stops.
  void _debounceSwitchRepo() {
    _repoDebounceTimer?.cancel();
    _repoDebounceTimer = Timer(const Duration(milliseconds: 600), _switchToRepo);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _repoCtrl.dispose();
    _branchCtrl.dispose();
    _repoDebounceTimer?.cancel();
    _scrollCtrl.dispose();
    _inputFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<ChatProvider>().refreshMessages();
    }
  }

  void _send() {
    if (!mounted) return;
    var text = _inputCtrl.text.trim();
    if (text.isEmpty) return;

    // Append "Implement" audit paragraph when checkbox is checked.
    // Reads from PreferencesService (user-editable in settings, per-device).
    if (_implementChecked) {
      final implementPrompt = context.read<PreferencesService>().implementPrompt;
      text += "\n\n===============================================================\n"
          "$implementPrompt";
    }
    // Append "Test & Debug" prompt when checkbox is checked.
    // Reads from PreferencesService (user-editable in settings, per-device).
    // Default is empty — user writes their own test/debug instructions.
    if (_testChecked) {
      final testPrompt = context.read<PreferencesService>().testPrompt;
      if (testPrompt.isNotEmpty) {
        text += "\n\n===============================================================\n"
            "$testPrompt";
      }
    }
    // Append "Audit" prompt when checkbox is checked.
    // Reads from PreferencesService (user-editable in settings, per-device).
    if (_auditChecked) {
      final auditPrompt = context.read<PreferencesService>().auditPrompt;
      text += "\n\n===============================================================\n"
          "$auditPrompt";
    }

    final repo = _repoCtrl.text.trim();
    if (repo.isEmpty) {
      debugPrint('[ChatScreen._send] BLOCKED: no repo');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a repository (owner/repo)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
      debugPrint('[ChatScreen._send] BLOCKED: invalid repo=$repo');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid repo format. Use: owner/repo'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    _inputCtrl.clear();
    // Keep checkbox state — user may want it on for the next send too
    // (they uncheck it manually when they don't need it).
    _saveRepoPrefs();

    // Empty branch defaults to 'main' so backend injects git pull for main.
    // The backend also auto-detects the default branch in _create_conversation.
    final branch = _branchCtrl.text.trim().isEmpty ? 'main' : _branchCtrl.text.trim();
    final prov = context.read<ChatProvider>();

    debugPrint('[ChatScreen._send] repo=$repo branch=$branch mode=code implement=$_implementChecked test=$_testChecked');
    prov.send(text, repo: repo, branch: branch, mode: 'code');
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
        title: Consumer2<ChatProvider, SettingsProvider>(
          builder: (_, chatProv, settings, __) {
            final activeRepo = chatProv.serverRepo.isNotEmpty
                ? chatProv.serverRepo
                : _repoCtrl.text.trim();
            final activeMode = 'code';
            final parts = <String>[];
            if (activeRepo.isNotEmpty) parts.add(activeRepo);
            if (activeRepo.isNotEmpty && chatProv.serverBranch.isNotEmpty) parts.add(chatProv.serverBranch);
            if (activeRepo.isNotEmpty) parts.add(activeMode.toUpperCase());
            // Show model from SettingsProvider (updated when model is changed in settings).
            // Fall back to SharedPreferences cache if not yet loaded from server.
            final displayModel = settings.modelName ?? _activeModel;
            if (displayModel.isNotEmpty) parts.add(displayModel);
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
          // Refresh: full re-fetch like closing and reopening the app
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
            tooltip: 'Refresh (re-fetch all state from server)',
            onPressed: () async {
              final prov = context.read<ChatProvider>();
              prov.logViewer('ChatScreen: manual refresh triggered');
              await prov.refreshFull();
              if (mounted) {
                setState(() {
                  if (_repoCtrl.text.isEmpty && prov.serverRepo.isNotEmpty) {
                    _repoCtrl.text = prov.serverRepo;
                    _showRepoBar = true;
                  }
                  if (_branchCtrl.text.isEmpty && prov.serverBranch.isNotEmpty) {
                    _branchCtrl.text = prov.serverBranch;
                  }
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Refreshed — state synced from server'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
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
      body: Stack(
        children: [
          Column(
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
                        // Build items oldest-first, then reverse for newest-at-bottom.
                        // Can't use 'final' since we reassign after grouping.
                        var items = <Widget>[];
                        if (showTyping) items.add(_buildTyping());
                        // Group consecutive events + following assistant into
                        // ONE collapsed bubble so 50 queued prompts don't flood.
                        int ii = 0;
                        while (ii < visible.length) {
                          if (visible[ii].role == 'event') {
                            final evts = <ChatMessage>[];
                            while (ii < visible.length && visible[ii].role == 'event') {
                              evts.add(visible[ii]);
                              ii++;
                            }
                            ChatMessage? aiResp;
                            if (ii < visible.length && visible[ii].role == 'assistant') {
                              aiResp = visible[ii];
                              ii++;
                            }
                            items.add(_AiWorkGroup(events: evts, response: aiResp));
                          } else {
                            items.add(_ChatBubble(msg: visible[ii]));
                            ii++;
                          }
                        }
                        items = items.reversed.toList();
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

          // Scroll-to-bottom FAB: visible when scrolled up (offset > 200).
          // Positioned above the input bar, right-aligned.
          if (_showScrollToBottom)
            Positioned(
              right: 16,
              bottom: 72,  // above input bar (~56px)
              child: GestureDetector(
                onTap: _scrollToBottom,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withAlpha(200),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(80),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.arrow_downward, color: Colors.white, size: 22),
                ),
              ),
            ),
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
                        maxLines: 1,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        textInputAction: TextInputAction.go,
                        onChanged: (_) {
                          _saveRepoPrefs();
                          _debounceSwitchRepo();
                        },
                        onSubmitted: (_) => _switchToRepo(),
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
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // Branch: free-text TextField + popup for suggestions
              BranchPopup(
                controller: _branchCtrl,
                onChanged: () => _saveRepoPrefs(),
                repo: _repoCtrl.text.trim().isNotEmpty ? _repoCtrl.text.trim() : null,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF7C3AED).withAlpha(60)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF7C3AED).withAlpha(180)),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'AI Working…',
                style: TextStyle(
                  color: Colors.white.withAlpha(160),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
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
                              ? '${prov.queueDone}/${prov.queueTotal} done'
                              : 'Processing…',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        if (prov.queueTotal > 0) ...[
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: prov.queueTotal > 0 ? prov.queueDone / prov.queueTotal : 0,
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
          // Per-prompt chips — horizontal scrollable, shows done/running/pending
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
                    final isDone = i < prov.queueDone;        // already completed
                    final isRunning = !isDone && i == prov.queuePosition;  // currently processing
                    final mode = i < prov.batchModes.length ? prov.batchModes[i] : 'code';
                    final isPlan = mode == 'plan';
                    final text = prov.batchPrompts[i];
                    final truncated = text.length > 28 ? '${text.substring(0, 28)}…' : text;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isDone
                              ? const Color(0xFF1A3A1A).withValues(alpha: 0.6)
                              : isRunning
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
                                  color: isDone ? Colors.green : isRunning ? Colors.white : Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            if (!isDone)
                              GestureDetector(
                                onTap: () => prov.cancelPrompt(i),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6),
                                  child: Icon(Icons.close, color: Colors.redAccent, size: 14),
                                ),
                              )
                            else
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.check, color: Colors.green, size: 14),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          // "Implement" checkbox — appends full-audit paragraph to prompt
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Row(
              children: [
                SizedBox(
                  height: 20,
                  width: 20,
                  child: Checkbox(
                    value: _implementChecked,
                    onChanged: (v) => setState(() => _implementChecked = v ?? false),
                    activeColor: const Color(0xFF7C3AED),
                    checkColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF4A4A5E), width: 1.5),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => setState(() => _implementChecked = !_implementChecked),
                  child: Text(
                    'Implement',
                    style: TextStyle(
                      color: _implementChecked ? const Color(0xFFA78BFA) : Colors.grey[500],
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // "Test & Debug" checkbox — appends test prompt
                SizedBox(
                  height: 20,
                  width: 20,
                  child: Checkbox(
                    value: _testChecked,
                    onChanged: (v) {
                      setState(() => _testChecked = v ?? false);
                      // Persist immediately so state survives app restart
                      context.read<PreferencesService>().setTestEnabled(v ?? false);
                    },
                    activeColor: const Color(0xFF7C3AED),
                    checkColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF4A4A5E), width: 1.5),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () {
                    final newVal = !_testChecked;
                    setState(() => _testChecked = newVal);
                    context.read<PreferencesService>().setTestEnabled(newVal);
                  },
                  child: Text(
                    'Test',
                    style: TextStyle(
                      color: _testChecked ? const Color(0xFFA78BFA) : Colors.grey[500],
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // "Audit" checkbox — appends audit prompt
                SizedBox(
                  height: 20,
                  width: 20,
                  child: Checkbox(
                    value: _auditChecked,
                    onChanged: (v) {
                      setState(() => _auditChecked = v ?? false);
                      context.read<PreferencesService>().setAuditEnabled(v ?? false);
                    },
                    activeColor: const Color(0xFF7C3AED),
                    checkColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF4A4A5E), width: 1.5),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () {
                    final newVal = !_auditChecked;
                    setState(() => _auditChecked = newVal);
                    context.read<PreferencesService>().setAuditEnabled(newVal);
                  },
                  child: Text(
                    'Audit',
                    style: TextStyle(
                      color: _auditChecked ? const Color(0xFFA78BFA) : Colors.grey[500],
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
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
                  focusNode: _inputFocusNode,
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
class _ChatBubble extends StatefulWidget {
  final ChatMessage msg;
  const _ChatBubble({required this.msg});

  @override
  State<_ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<_ChatBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    final isUser = msg.role == 'user';
    final isEvent = msg.role == 'event';
    final isError = msg.role == 'error';
    final isAssistant = msg.role == 'assistant';

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

    // ALL assistant messages collapsed by default (even short ones).
    // When 50 prompts queued, this prevents 750+ event/response lines
    // from flooding the UI. User taps any AI bubble to expand.
    final showPreview = isAssistant && !_expanded;
    final previewText = showPreview
        ? (msg.content.length > 300
            ? '${msg.content.substring(0, 300)}…'
            : msg.content)
        : msg.content;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) const SizedBox(width: 8),
          Flexible(
            child: GestureDetector(
              onTap: isAssistant && !_expanded
                  ? () => setState(() => _expanded = true)
                  : isAssistant && _expanded
                      ? () => setState(() => _expanded = false)
                      : null,
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
                        ? SelectionArea(
                            child: SelectableText(
                              msg.content,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                height: 1.45,
                              ),
                            ),
                          )
                        : SelectionArea(
                            child: MarkdownBody(
                            data: previewText,
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
                    Row(
                      children: [
                        Text(
                          _fmtTime(msg.timestamp),
                          style: TextStyle(
                            color: Colors.white.withAlpha(80),
                            fontSize: 10,
                          ),
                        ),
                        const Spacer(),
                        // Copy button for ALL messages (user + assistant)
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: msg.content));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Copied to clipboard'),
                                duration: const Duration(seconds: 1),
                                backgroundColor: isUser
                                    ? const Color(0xFF7C3AED)
                                    : const Color(0xFF1E1E2E),
                              ),
                            );
                          },
                          child: Icon(
                            Icons.copy,
                            color: Colors.white.withAlpha(80),
                            size: 14,
                          ),
                        ),
                        if (isAssistant && !_expanded)
                          Icon(Icons.chevron_right, color: Colors.white.withAlpha(40), size: 16),
                        if (isAssistant && _expanded)
                          Icon(Icons.chevron_left, color: Colors.white.withAlpha(40), size: 16),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildEvent(BuildContext context) {
    final m = widget.msg;
    // Compact inline event display — tool calls, observations, etc.
    // Backend sends text tags like [READ], [EDIT], [ERROR] instead of emoji
    Color accent;
    IconData icon;
    if (m.content.startsWith('[TERMINAL]')) { accent = const Color(0xFF00FF88); icon = Icons.terminal; }
    else if (m.content.startsWith('[READ]')) { accent = const Color(0xFF10B981); icon = Icons.menu_book; }
    else if (m.content.startsWith('[EDIT]')) { accent = const Color(0xFFF59E0B); icon = Icons.edit; }
    else if (m.content.startsWith('[UNDO]')) { accent = Colors.orangeAccent; icon = Icons.undo; }
    else if (m.content.startsWith('[SEARCH]')) { accent = const Color(0xFF3B82F6); icon = Icons.search; }
    else if (m.content.startsWith('[BROWSER]')) { accent = const Color(0xFF06B6D4); icon = Icons.public; }
    else if (m.content.startsWith('[OUT]')) { accent = Colors.grey; icon = Icons.output; }
    else if (m.content.startsWith('[WARN]')) { accent = Colors.orangeAccent; icon = Icons.warning_amber; }
    else if (m.content.startsWith('[FILE]')) { accent = const Color(0xFF10B981); icon = Icons.description; }
    else if (m.content.startsWith('[RESULTS]')) { accent = const Color(0xFF8B5CF6); icon = Icons.bar_chart; }
    else if (m.content.startsWith('[ERROR]')) { accent = Colors.redAccent; icon = Icons.error; }
    else if (m.content.startsWith('[STOP]')) { accent = Colors.grey; icon = Icons.stop_circle; }
    else if (m.content.startsWith('[MSG]')) { accent = Colors.white70; icon = Icons.chat_bubble_outline; }
    else if (m.content.startsWith('[STATUS]')) { accent = const Color(0xFF3B82F6); icon = Icons.info_outline; }
    else if (m.content.startsWith('[WORKING]')) { accent = const Color(0xFF22C55E); icon = Icons.hourglass_top; }
    else if (m.content.startsWith('[DONE]')) { accent = const Color(0xFF22C55E); icon = Icons.check_circle; }
    else { accent = Colors.grey; icon = Icons.settings; }

    // Strip text tag prefix like "[READ] " for display (icon already conveys meaning)
    final displayText = _stripTagPrefix(m.content);

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

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// Top-level helpers shared by _ChatBubbleState, _AiWorkGroupState, etc.
String _stripTagPrefix(String text) {
  if (text.isEmpty) return text;
  final m = RegExp(r'^\[[A-Z]+\]\s?').firstMatch(text);
  if (m == null) return text;
  final stripped = text.substring(m.end);
  return stripped.isEmpty ? '(no details)' : stripped;
}

String _fmtTime(int ms) {
  if (ms <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
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
                          overflow: TextOverflow.ellipsis,
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

// ---------------------------------------------------------------------------
// Collapsed AI Work Group — events + response in ONE bubble
// ---------------------------------------------------------------------------
class _AiWorkGroup extends StatefulWidget {
  final List<ChatMessage> events;
  final ChatMessage? response;
  const _AiWorkGroup({required this.events, this.response});

  @override
  State<_AiWorkGroup> createState() => _AiWorkGroupState();
}

class _AiWorkGroupState extends State<_AiWorkGroup> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Start expanded if AI is actively working (no response yet).
    _expanded = widget.response == null;
  }

  @override
  void didUpdateWidget(covariant _AiWorkGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadResponse = oldWidget.response != null;
    final hasResponse = widget.response != null;
    if (!hadResponse && hasResponse) {
      // Just finished — auto-collapse
      if (mounted) setState(() => _expanded = false);
    } else if (widget.response == null) {
      // Still working — keep expanded
      if (!_expanded && mounted) setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    final response = widget.response;
    final evtCount = events.length;
    // Get unique tags from events for the collapsed summary
    final tags = events.map((e) {
      final c = e.content;
      if (c.startsWith('[TERMINAL]')) return 'terminal';
      if (c.startsWith('[READ]')) return 'read';
      if (c.startsWith('[EDIT]')) return 'edit';
      if (c.startsWith('[BROWSER]')) return 'browser';
      if (c.startsWith('[ERROR]')) return 'error';
      if (c.startsWith('[SEARCH]')) return 'search';
      if (c.startsWith('[FILE]')) return 'file';
      return 'event';
    }).toSet().join(' · ');
    final hasResponse = response != null && response.content.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const SizedBox(width: 8),
          Flexible(
            child: GestureDetector(
              onTap: () {
                // Don't collapse while AI is actively working on THIS prompt
                if (widget.response == null) return;
                setState(() => _expanded = !_expanded);
              },
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withAlpha(15)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Always-visible header row
                    Row(
                      children: [
                        // Bigger triangle — clear expand/collapse affordance
                        AnimatedRotation(
                          turns: _expanded ? 0.25 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.chevron_right,
                            color: const Color(0xFF7C3AED),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 2),
                        // Pulsing working dot when AI is active (no response yet)
                        if (response == null)
                          _WorkingDot(),
                        Text(
                          'AI Work · $evtCount step${evtCount > 1 ? 's' : ''}',
                          style: TextStyle(
                            color: Colors.white.withAlpha(180),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),

                    // Collapsed: single-line tag summary
                    if (!_expanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          tags.isNotEmpty ? tags : '$evtCount event${evtCount > 1 ? 's' : ''}',
                          style: TextStyle(
                            color: Colors.white.withAlpha(70),
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),

                    // Expanded: show all events + response
                    if (_expanded) ...[
                      const SizedBox(height: 6),
                      ...events.map((e) => _buildEventItem(e)),
                      if (hasResponse) ...[
                        const Divider(color: Color(0xFF2A2A3E), height: 12),
                        SelectionArea(
                          child: MarkdownBody(
                            data: response!.content,
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
                              listBullet: const TextStyle(color: Color(0xFF7C3AED)),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        _fmtTime(response?.timestamp ?? events.last.timestamp),
                        style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10),
                      ),
                      if (response == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              _WorkingDot(),
                              const SizedBox(width: 4),
                              Text(
                                'Working…',
                                style: TextStyle(color: const Color(0xFF7C3AED).withAlpha(160), fontSize: 10, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventItem(ChatMessage evt) {
    final c = evt.content;
    Color iconColor;
    IconData iconData;
    if (c.startsWith('[TERMINAL]')) { iconColor = const Color(0xFF00FF88); iconData = Icons.terminal; }
    else if (c.startsWith('[READ]')) { iconColor = const Color(0xFF10B981); iconData = Icons.menu_book; }
    else if (c.startsWith('[EDIT]')) { iconColor = const Color(0xFFF59E0B); iconData = Icons.edit; }
    else if (c.startsWith('[ERROR]')) { iconColor = Colors.redAccent; iconData = Icons.error; }
    else if (c.startsWith('[SEARCH]')) { iconColor = const Color(0xFF3B82F6); iconData = Icons.search; }
    else if (c.startsWith('[BROWSER]')) { iconColor = const Color(0xFF06B6D4); iconData = Icons.public; }
    else if (c.startsWith('[FILE]')) { iconColor = const Color(0xFF10B981); iconData = Icons.description; }
    else { iconColor = Colors.grey; iconData = Icons.settings; }

    final displayText = _stripTagPrefix(c);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(iconData, size: 13, color: iconColor),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              displayText,
              style: TextStyle(color: iconColor.withAlpha(200), fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
// ---------------------------------------------------------------------------
// Working dot — pulsing animation for AI-in-progress indicator
// ---------------------------------------------------------------------------
class _WorkingDot extends StatefulWidget {
  @override
  State<_WorkingDot> createState() => _WorkingDotState();
}

class _WorkingDotState extends State<_WorkingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
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
      builder: (_, child) => Transform.scale(
        scale: 1.0 + (_ctrl.value * 0.4),  // pulse from 1.0× to 1.4×
        child: Opacity(
          opacity: 0.6 + (_ctrl.value * 0.4),  // fade 60% → 100%
          child: Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFA78BFA),  // brighter purple
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C3AED).withAlpha(100),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
