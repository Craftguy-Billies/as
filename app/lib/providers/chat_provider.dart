import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class ChatMessage {
  final int? id; // server-side unique ID (null for client-only messages)
  final String role; // "user" | "assistant" | "event"
  final String content;
  final int timestamp;

  const ChatMessage({
    this.id,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'role': role,
        'content': content,
        'timestamp': timestamp,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as int?,
        role: (json['role'] ?? 'user').toString(),
        content: (json['content'] ?? '').toString(),
        timestamp: (json['timestamp'] ?? 0) as int,
      );

  // Dedup: server msgs by ID, client msgs by role:content.
  // Server messages go first (canonical), client fills gaps.
  String get dedupKey => id != null ? 'id:$id' : '$role:$content';
}

/// Single-mode chat: everything goes through the server-side batch queue.
/// Send → enqueue on server → poll for live events + progress.
/// Survives phone close — reconnects and resumes polling.
class ChatProvider extends ChangeNotifier {
  static const _cacheKey = 'chat_session';

  final ApiService _api;
  List<ChatMessage> _messages = [];
  bool _loading = false;
  String? _error;
  DateTime? _loadingSince;

  // Queue progress (updated from server every poll)
  int _queuePosition = 0;
  int _queueTotal = 0;
  int _queueDone = 0;  // number of completed prompts
  int _pollFailures = 0;
  int _pollGeneration = 0;
  Timer? _pollTimer;
  int _lastNotifiedHash = 0;  // avoid redundant rebuilds

  ChatProvider(this._api);

  // -- Getters --
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get loading => _loading;
  String? get error => _error;
  int get queuePosition => _queuePosition;
  int get queueTotal => _queueTotal;
  int get queueDone => _queueDone;
  bool get isProcessing => _queueTotal > 0;
  String serverRepo = '';
  String serverBranch = '';
  String serverMode = 'code';
  List<Map<String, dynamic>> _savedRepos = [];
  List<Map<String, dynamic>> get savedRepos => _savedRepos;

  List<String> _branches = [];
  List<String> get branches => _branches;
  bool get branchesAttempted => _branchesAttempted;
  bool _branchesAttempted = false;  // differentiate "loading" from "empty"

  // Lazy message loading: show latest N first, "load earlier" button at top
  // Set high because each user turn spawns ~10-15 internal events ([MSG], [START],
  // [TOOL], etc.) which all count as separate items in _messages.
  final _pageSize = 200;
  int _showFromIndex = 0;  // index into _messages to start displaying from
  int get showFromIndex => _showFromIndex;
  bool get hasMoreMessages => _showFromIndex > 0;

  /// Show [_pageSize] more older messages (decrease start index).
  void loadMoreMessages() {
    if (_showFromIndex <= 0) return;
    _showFromIndex = (_showFromIndex - _pageSize).clamp(0, _messages.length);
    _notify();
  }

  void _resetShowIndex() {
    _showFromIndex = (_messages.length - _pageSize).clamp(0, _messages.length);
    _notify();
  }

  // Batch queue prompt list for per-prompt cancel UI
  List<String> _batchPrompts = [];
  List<String> _batchModes = [];   // "plan" or "code" per prompt
  List<String> get batchPrompts => _batchPrompts;
  List<String> get batchModes => _batchModes;

  // -- In-app log buffer (visible on mobile where debugPrint is hidden) --
  final List<String> _logLines = [];
  List<String> get logLines => List.unmodifiable(_logLines);
  static const _maxLogs = 500;

  void logViewer(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19); // HH:mm:ss
    _logLines.add('[$ts] $msg');
    while (_logLines.length > _maxLogs) {
      _logLines.removeAt(0);
    }
    debugPrint(msg);
    _notify();
  }

  /// notifyListeners only when state actually changed (avoid 2s poll rebuilds)
  void _notify() {
    final msgs = _messages;
    final hash = Object.hash(
      msgs.length,
      _loading,
      _error,
      _queuePosition,
      _queueTotal,
      _queueDone,
      _showFromIndex,
      msgs.isEmpty ? 0 : msgs.last.timestamp,
      msgs.isEmpty ? 0 : msgs.first.timestamp,
      msgs.isEmpty ? '' : msgs.last.content,
    );
    if (hash != _lastNotifiedHash) {
      _lastNotifiedHash = hash;
      notifyListeners();
    }
  }

  // -- Init: restore from cache + server, resume batch if running --
  /// Returns the restored repo so callers can sync text controllers.
  /// Returns the restored repo so callers can sync text controllers.
  Future<String> loadFromCache() async {
    logViewer('ChatProvider.loadFromCache: START serverRepo=$serverRepo');

    // --- Phase A: Restore from local SharedPreferences cache ---
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        final data = json.decode(raw);
        if (data is Map<String, dynamic>) {
          final msgs = data['messages'];
          if (msgs is List && msgs.isNotEmpty) {
            _messages = msgs
                .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList();
            _resetShowIndex();
          }
          final cachedRepo = (data['repo']?.toString()) ?? '';
          final cachedMode = (data['mode']?.toString()) ?? '';
          final cachedBranch = (data['branch']?.toString()) ?? '';
          if (cachedRepo.isNotEmpty) {
            serverRepo = cachedRepo;
            logViewer('ChatProvider.loadFromCache: repo= $cachedRepo (from cache)');
          }
          if (cachedMode.isNotEmpty) serverMode = cachedMode;
          if (cachedBranch.isNotEmpty) {
            serverBranch = cachedBranch;
            logViewer('ChatProvider.loadFromCache: branch= $cachedBranch (from cache)');
          }
        } else if (data is List && data.isNotEmpty) {
          _messages = data
              .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList();
          _resetShowIndex();
          logViewer('ChatProvider.loadFromCache: legacy cache, ${_messages.length} msgs');
        }
      } catch (_) {
        await prefs.remove(_cacheKey);
      }
    }

    // --- Phase B: Fetch saved repos from server (BEFORE server merge) ---
    // This way, if local cache is empty but server has repos, we can use
    // the most recent one as the key for the server merge that follows.
    try {
      _savedRepos = await _api.getChatRepos();
      logViewer('ChatProvider.loadFromCache: loaded ${_savedRepos.length} repos from server');
      if (_savedRepos.isNotEmpty) {
        logViewer('ChatProvider.loadFromCache: first savedRepo=${_savedRepos.first['repo']} branch=${_savedRepos.first['branch']}');
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: repo fetch failed: $e');
    }

    // Phase B fallback: if serverRepo is still empty, use most recent
    // saved repo from server (sorted by last_timestamp desc).
    if (serverRepo.isEmpty && _savedRepos.isNotEmpty) {
      for (final r in _savedRepos) {
        final rp = r['repo']?.toString();
        if (rp != null && rp.isNotEmpty && rp != '(none)') {
          serverRepo = rp;
          serverBranch = r['branch']?.toString() ?? serverBranch;
          logViewer('ChatProvider.loadFromCache: repo= $serverRepo (from savedRepos fallback) branch=$serverBranch');
          break;
        }
      }
    }

    // --- Phase C: Merge server messages ---
    // Now serverRepo is set from cache, savedRepos, or empty (truly first use).
    try {
      final data = await _api.getChat(repo: serverRepo, mode: serverMode);
      // Only trust data['repo'] when we did NOT explicitly request a repo.
      // This prevents cross-device overwrite: if Device A switched to repo B,
      // the server's _conversation_repo is B. But Device B requested repo A's
      // messages — we should keep Device B's serverRepo as A, not switch to B.
      if (serverRepo.isEmpty) {
        final serverRp = data['repo']?.toString();
        if (serverRp != null && serverRp.isNotEmpty) {
          serverRepo = serverRp;
          logViewer('ChatProvider.loadFromCache: repo= $serverRp (from server fallback)');
        }
      }
      if (serverRepo.isEmpty) {
        final key = data['current_repo_key']?.toString();
        if (key != null && key.isNotEmpty && key != '(none)') {
          serverRepo = key;
          logViewer('ChatProvider.loadFromCache: repo= $key (from current_repo_key)');
        }
      }
      // Branch is NOT repo-specific — data['branch'] is the server's
      // _conversation_branch which reflects the LAST conversation on ANY repo.
      // Only use it as fallback when local branch is empty.
      final serverBr = data['branch']?.toString();
      if (serverBr != null && serverBr.isNotEmpty && serverBranch.isEmpty) {
        serverBranch = serverBr;
        logViewer('ChatProvider.loadFromCache: branch= $serverBr (from server fallback)');
      }
      await _saveToCache();

      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        final merged = <ChatMessage>[];
        final seen = <String>{};
        for (final m in serverMsgs) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        for (final m in _messages) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages = merged;
        await _saveToCache();
        _resetShowIndex();
        _notify();
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: server merge failed (using cache): $e');
    }

    // --- Phase D: Resume polling if batch running ---
    try {
      final state = await _api.getChat(repo: serverRepo, mode: serverMode);
      final batch = state?['batch'] as Map<String, dynamic>?;
      final isRunning = batch?['running'] == true;
      final total = (batch?['total'] as int?) ?? 0;
      logViewer('ChatProvider.loadFromCache: batch running=$isRunning total=$total pos=${batch?['position']}');
      if (isRunning && total > 0) {
        _queuePosition = (batch?['position'] as int?) ?? 0;
        _queueTotal = total;
        _loading = true;
        _loadingSince = DateTime.now();
        _notify();
        _startPolling(repo: state?['repo']?.toString() ?? '',
                      branch: state?['branch']?.toString() ?? '',
                      mode: state?['mode']?.toString() ?? 'code');
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: batch resume failed: $e');
    }

    // Auto-fetch branches
    fetchBranches();
    return serverRepo;
  }

  // -- Send: queue prompt(s) on server, then poll for progress --
  Future<void> send(
    String prompt, {
    String repo = '',
    String branch = '',
    String mode = 'code',
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;

    // VALIDATE: No messages without a valid repo
    final effectiveRepo = repo.isNotEmpty ? repo : serverRepo;
    if (effectiveRepo.isEmpty) {
      logViewer('ChatProvider.send: BLOCKED — no repo selected');
      _error = 'Select a repository (owner/repo) before sending messages';
      _notify();
      return;
    }
    final repoRegex = RegExp(r'^[\w.-]+/[\w.-]+$');
    if (!repoRegex.hasMatch(effectiveRepo)) {
      logViewer('ChatProvider.send: BLOCKED — invalid repo format: $effectiveRepo');
      _error = 'Invalid repo format: $effectiveRepo. Use: owner/repo';
      _notify();
      return;
    }

    logViewer('ChatProvider.send: START repo=$repo branch=$branch mode=$mode');
    _error = null;

    // If repo or branch changed, switch to new conversation history
    // ONE CHAT PER REPO: branch changes keep same chat, only repo changes create new chat.
    if ((repo.isNotEmpty && repo != serverRepo) || 
        (repo.isEmpty && effectiveRepo != serverRepo)) {
      final newRepo = repo.isNotEmpty ? repo : serverRepo;
      logViewer('ChatProvider.send: repo changed to $newRepo — switching chat');
      serverRepo = newRepo;
      serverBranch = branch.isNotEmpty ? branch : serverBranch;
      serverMode = mode;
      _messages.clear();
      _showFromIndex = 0;
      _queuePosition = 0;
      _queueTotal = 0;
      _queueDone = 0;
      _pollTimer?.cancel();
      await _saveToCache();
      _notify();
      if (newRepo.isNotEmpty) {
        fetchBranches();
      }
      // Fetch messages for the new repo from server
      try {
        final state = await _api.getChat(repo: newRepo, mode: serverMode);
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        _messages = serverMsgs;
        _resetShowIndex();
        await _saveToCache();
      } catch (e) {
        logViewer('ChatProvider.send: failed to fetch new repo msgs: $e');
      }
    } else if (branch.isNotEmpty && branch != serverBranch) {
      // Branch switch on same repo — do NOT clear messages (one chat per repo)
      logViewer('ChatProvider.send: branch switch on same repo: $branch');
      serverBranch = branch;
      await _saveToCache();
    } else if (mode != serverMode) {
      serverMode = mode;
      await _saveToCache();
    }

    try {
      final result = await _api.sendChatBatch(
        prompts: [trimmed],
        repo: repo,
        branch: branch,
        mode: mode,
      );
      logViewer('ChatProvider.send: result=$result');

      final status = result['status']?.toString() ?? '';
      if (status == 'queued') {
        // DO NOT add user message to chat — it's in the queue.
        // The poll picks it up once the server processes it.
        _queuePosition = (result['position'] as int?) ?? 0;
        _queueTotal = (result['total'] as int?) ?? 1;
        _pollFailures = 0;
        _loading = true;
        _loadingSince = DateTime.now();
        logViewer('ChatProvider.send: queued pos=$_queuePosition total=$_queueTotal — polling');
        _notify();
        _startPolling(repo: repo, branch: branch, mode: mode);
      } else if (status == 'appended') {
        // Appended to running batch — poll will pick it up
        _queueTotal = (result['total'] as int?) ?? _queueTotal;
        _loading = true;
        logViewer('ChatProvider.send: appended to batch (total=$_queueTotal)');
        _notify();
      } else {
        logViewer('ChatProvider.send: unexpected status=$status');
        _error = (result['error']?.toString()) ?? 'Server did not accept the request';
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
        _notify();
      }
    } catch (e) {
      logViewer('ChatProvider.send: ERROR ${ApiService.friendlyError(e)}');
      _error = ApiService.friendlyError(e);
      _queuePosition = 0;
      _queueTotal = 0;
      _queueDone = 0;
      _notify();
    }
  }

  // -- Polling: fetch messages + progress every 2 seconds --
  void _startPolling({required String repo, required String branch, required String mode}) {
    _pollTimer?.cancel();
    final gen = ++_pollGeneration;
    final pollStarted = DateTime.now();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (gen != _pollGeneration) return; // stale: repo switched or chat cleared
      if (DateTime.now().difference(pollStarted).inMinutes >= 30) {
        _pollTimer?.cancel();
        _loading = false;
        _loadingSince = null;
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
        _error = 'Polling timed out (30 min). Queue may still run on server.';
        logViewer('ChatProvider.poll: TIMEOUT');
        _notify();
        return;
      }
      try {
        final state = await _api.getChat(repo: repo, mode: mode);
        if (gen != _pollGeneration) return; // stale after await
        if (state == null) return;
        _error = null;  // clear error on any successful poll

        // Merge server messages (events, responses) into local chat
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        logViewer('ChatProvider.poll: serverMsgs=${serverMsgs.length} localMsgs=${_messages.length}');
        if (serverMsgs.isNotEmpty) {
          final merged = <ChatMessage>[];
          final seen = <String>{};
          // Phase 1: server messages (canonical, have IDs).
          for (final m in serverMsgs) {
            if (seen.add(m.dedupKey)) {
              merged.add(m);
            }
          }
          // Phase 2: client messages only if not covered by server
          for (final m in _messages) {
            if (seen.add(m.dedupKey)) {
              merged.add(m);
            }
          }
          // Sort by timestamp so messages appear chronologically
          merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          // Trim to prevent unbounded memory growth
          if (merged.length > 2000) {
            merged.removeRange(0, merged.length - 1500);
          }
          if (merged.length != _messages.length ||
              _messages.isEmpty ||
              merged.last.timestamp != _messages.last.timestamp) {
            logViewer('ChatProvider.poll: merged ${_messages.length}→${merged.length} messages');
            _messages = merged;
            _resetShowIndex();  // re-clamp after possible trim
            _error = null;
            await _saveToCache();
          }
        }

        // Update progress from server
        final batch = state['batch'] as Map<String, dynamic>?;
        if (batch != null) {
          final wasLoading = _loading;
          final isRunning = batch['running'] == true;
          logViewer('ChatProvider.poll: batch running=$isRunning pos=${batch['position']} total=${batch['total']} done=${batch['done']} wasLoading=$wasLoading');
          _loading = isRunning;
          _queuePosition = (batch['position'] as int?) ?? _queuePosition;
          _queueTotal = (batch['total'] as int?) ?? _queueTotal;
          _queueDone = (batch['done'] as int?) ?? _queuePosition;

          // Parse prompt list for per-prompt cancel UI
          final prompts = batch['prompts'] as List?;
          if (prompts != null) {
            _batchPrompts = prompts.map((e) => e.toString()).toList();
          }
          final modes = batch['modes'] as List?;
          if (modes != null) {
            _batchModes = modes.map((e) => e.toString()).toList();
          }

          // Stop polling when batch completes — regardless of wasLoading.
          // Handles: cancel during poll, batch finishing between polls, etc.
          if (!isRunning) {
            _loadingSince = null;
            _pollTimer?.cancel();
            _queuePosition = 0;
            _queueTotal = 0;  // hide progress bar
            logViewer('ChatProvider.poll: batch not running — stopped (wasLoading=$wasLoading)');
          }
        }

        _pollFailures = 0;
        _notify();
      } catch (e) {
        logViewer('ChatProvider.poll: fail #$_pollFailures: $e');
        _pollFailures++;
        if (_pollFailures >= 10) {
          _error = 'Lost connection to server. Queue may still be running.';
          _loading = false;
          _loadingSince = null;
          _pollTimer?.cancel();
          _notify();
        }
      }
    });
  }

  // -- Repo management --
  /// Called from home screen init: set repo and fetch branches without
  /// clearing messages or touching poll state (no conversation yet).
  void initRepoFromHome(String repo) {
    if (repo.isEmpty) return;
    logViewer('ChatProvider.initRepoFromHome: repo=$repo (current=$serverRepo)');
    if (repo == serverRepo) return;
    serverRepo = repo;
    fetchBranches();
  }

  Future<void> switchRepo(String repo, String mode, {String branch = ''}) async {
    logViewer('ChatProvider.switchRepo: repo=$repo branch=$branch (was repo=$serverRepo branch=$serverBranch)');
    if (repo == serverRepo && mode == serverMode && branch == serverBranch) {
      // Same context — but branches may be stale on cold start
      if (_branches.isEmpty && repo.isNotEmpty) {
        fetchBranches();
      }
      return;
    }
    serverRepo = repo;
    serverBranch = branch;
    serverMode = mode;
    _branches = [];  // clear immediately to avoid stale flash from previous repo
    _branchesAttempted = false;
    _pollTimer?.cancel();
    _queuePosition = 0;
    _queueTotal = 0;
    _queueDone = 0;
    _loading = false;
    _loadingSince = null;
    // Fetch messages for this repo from server
    try {
      final state = await _api.getChat(repo: repo, mode: mode);
      // Do NOT overwrite serverBranch from server response — the user
      // explicitly typed a branch (or empty). The server's
      // _conversation_branch reflects the LAST conversation on ANY repo,
      // not the one the user wants for THIS repo.
      // Only fallback if user didn't provide a branch AND we have no
      // saved branch for this repo.
      final serverBr = state['branch']?.toString() ?? '';
      if (branch.isEmpty && serverBr.isNotEmpty) {
        serverBranch = serverBr;
        logViewer('ChatProvider.switchRepo: fallback branch="$serverBr" from server');
      } else {
        logViewer('ChatProvider.switchRepo: keeping user branch="$branch" (server had "$serverBr")');
      }
      final serverMsgs = (state['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      _messages = serverMsgs;
      _resetShowIndex();  // re-clamp for new repo's message count
      _error = null;
      await _saveToCache();
      logViewer('ChatProvider.switchRepo: loaded ${_messages.length} msgs for repo=$repo branch=$serverBranch');
    } catch (e) {
      logViewer('ChatProvider.switchRepo: failed to fetch messages: $e');
    }
    _notify();
    // Refresh repo list (new repo might appear later after messages)
    refreshRepos();
    // Load branch list for this repo
    fetchBranches();
  }

  Future<void> refreshRepos() async {
    try {
      _savedRepos = await _api.getChatRepos();
      _notify();
    } catch (e) {
      logViewer('ChatProvider.refreshRepos: $e');
    }
  }

  Future<void> refreshMessages() async {
    try {
      final data = await _api.getChat(repo: serverRepo, mode: serverMode);
      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        final merged = <ChatMessage>[];
        final seen = <String>{};
        for (final m in serverMsgs) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        for (final m in _messages) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages = merged;
        await _saveToCache();
        _resetShowIndex();
        _notify();
      }
    } catch (e) {
      logViewer('ChatProvider.refreshMessages: $e');
    }
  }

  Future<void> fetchBranches({String? repo}) async {
    // Allow caller to specify a repo (e.g. BranchPopup passes the text field
    // value). When null, fall back to serverRepo.
    final targetRepo = repo?.trim() ?? serverRepo;
    if (targetRepo.isEmpty) {
      _branchesAttempted = true;
      return;
    }
    try {
      _branches = await _api.getBranches(targetRepo);
      _branchesAttempted = true;
      logViewer('ChatProvider.fetchBranches: ${_branches.length} branches for $targetRepo');
      _notify();
    } catch (e) {
      _branchesAttempted = true;
      _branches = [];
      logViewer('ChatProvider.fetchBranches: $e');
      _notify();
    }
  }

  // -- Full refresh: same as closing and reopening the app --
  /// Re-fetches everything from server: messages, batch state, branches, repos.
  /// Does NOT clear local messages (merges with server).
  Future<void> refreshFull() async {
    logViewer('ChatProvider.refreshFull: START repo=$serverRepo');
    final previousRepo = serverRepo;
    final previousBranch = serverBranch;

    try {
      // Step 1: Re-fetch server state for this repo
      final data = await _api.getChat(repo: serverRepo, mode: serverMode);
      logViewer('ChatProvider.refreshFull: got server state');

      // Step 2: Update repo/branch from server
      final serverRp = data['repo']?.toString();
      if (serverRp != null && serverRp.isNotEmpty) {
        serverRepo = serverRp;
      }
      final serverBr = data['branch']?.toString();
      if (serverBr != null && serverBr.isNotEmpty) {
        serverBranch = serverBr;
      }

      // Step 3: Merge messages
      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        final merged = <ChatMessage>[];
        final seen = <String>{};
        for (final m in serverMsgs) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        for (final m in _messages) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages = merged;
        _resetShowIndex();
      }

      // Step 4: Update batch state
      final batch = data['batch'] as Map<String, dynamic>?;
      if (batch != null) {
        _queuePosition = (batch['position'] as int?) ?? 0;
        _queueTotal = (batch['total'] as int?) ?? 0;
        _queueDone = (batch['done'] as int?) ?? _queuePosition;
        _loading = _queueTotal > 0;
        if (_loading) {
          _loadingSince ??= DateTime.now();
          _startPolling(repo: serverRepo, branch: serverBranch, mode: serverMode);
        } else {
          _pollTimer?.cancel();
          _loadingSince = null;
        }
        // Parse prompts for cancel UI
        final prompts = batch['prompts'] as List?;
        if (prompts != null) {
          _batchPrompts = prompts.map((e) => e.toString()).toList();
        }
        final modes = batch['modes'] as List?;
        if (modes != null) {
          _batchModes = modes.map((e) => e.toString()).toList();
        }
      } else {
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
        _loading = false;
        _loadingSince = null;
        _batchPrompts = [];
        _batchModes = [];
        _pollTimer?.cancel();
      }

      // Step 5: Refresh branches and repos
      fetchBranches();
      try {
        _savedRepos = await _api.getChatRepos();
      } catch (_) {}

      await _saveToCache();
      _error = null;
      _notify();
      logViewer('ChatProvider.refreshFull: DONE repo=$serverRepo msgs=${_messages.length} batch=$_queueTotal');
    } catch (e) {
      logViewer('ChatProvider.refreshFull ERROR: $e');
      _error = 'Refresh failed: ${ApiService.friendlyError(e)}';
      _notify();
    }
  }

  /// Alias for external callers (e.g. chat screen refresh button)
  Future<void> refresh() => refreshFull();

  // -- Cancel / Clear --
  Future<void> cancel() async {
    _pollTimer?.cancel();
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    _queueDone = 0;
    _batchPrompts = [];
    _batchModes = [];
    _notify();

    // Await server cancel — if it fails, show error but UI already reset
    try {
      final ok = await _api.cancelChatBatch();
      if (!ok) {
        logViewer('ChatProvider.cancel: server unreachable, batch may still run');
      }
    } catch (e) {
      logViewer('ChatProvider.cancel: $e');
    }
  }

  /// Cancel a single prompt at [index] in the batch queue.
  /// Let server handle removal; next poll syncs authoritative state.
  Future<void> cancelPrompt(int index) async {
    if (index < 0 || index >= _batchPrompts.length) return;
    logViewer('ChatProvider.cancelPrompt: #$index "${_batchPrompts[index].length > 60 ? "${_batchPrompts[index].substring(0, 60)}..." : _batchPrompts[index]}"');

    try {
      final result = await _api.cancelPrompt(index);
      if (result != null && result.containsKey('error')) {
        logViewer('ChatProvider.cancelPrompt error: ${result['error']}');
      }
    } catch (e) {
      logViewer('ChatProvider.cancelPrompt exception: $e');
    }
    _notify();  // next periodic poll (~2s) will sync authoritative state
  }

  Future<void> clearChat() async {
    _pollTimer?.cancel();
    _messages.clear();
    _showFromIndex = 0;
    _error = null;
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    _queueDone = 0;
    _notify();

    try {
      await _api.deleteChat();
    } catch (e) {
      logViewer('ChatProvider.clearChat: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _saveToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = json.encode({
        'messages': _messages.map((m) => m.toJson()).toList(),
        'repo': serverRepo,
        'branch': serverBranch,
        'mode': serverMode,
      });
      await prefs.setString(_cacheKey, payload);
    } catch (_) {
      // silently ignore — SharedPreferences may fail if disk full
    }
  }
}
