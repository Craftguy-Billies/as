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
  bool get isProcessing => _queueTotal > 0;
  String serverRepo = '';
  String serverBranch = 'main';
  String serverMode = 'code';
  List<Map<String, dynamic>> _savedRepos = [];
  List<Map<String, dynamic>> get savedRepos => _savedRepos;

  List<String> _branches = [];
  List<String> get branches => _branches;
  bool get branchesAttempted => _branchesAttempted;
  bool _branchesAttempted = false;  // differentiate "loading" from "empty"

  List<Map<String, dynamic>> _taskLog = [];
  List<Map<String, dynamic>> get taskLog => _taskLog;
  String _taskLogRepo = '';

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
  Future<void> loadFromCache() async {
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
          serverRepo = (data['repo']?.toString()) ?? '';
          serverMode = (data['mode']?.toString()) ?? 'code';
        } else if (data is List && data.isNotEmpty) {
          // Legacy cache format (plain list)
          _messages = data
              .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList();
          _resetShowIndex();
        }
      } catch (_) {
        await prefs.remove(_cacheKey);
      }
    }

    // Merge server messages (survives server restart)
    try {
      final data = await _api.getChat(repo: serverRepo, mode: serverMode);
      // Restore branch from server state
      final serverBr = data['branch']?.toString();
      if (serverBr != null && serverBr.isNotEmpty) {
        serverBranch = serverBr;
      }
      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        final merged = <ChatMessage>[];
        final seen = <String>{};
        final serverContentKeys = <String>{};
        // Phase 1: server messages first (canonical, have IDs)
        for (final m in serverMsgs) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
            serverContentKeys.add('${m.role}:${m.content}');
          }
        }
        // Phase 2: client messages only if not already covered by server
        for (final m in _messages) {
          final ck = '${m.role}:${m.content}';
          if (!serverContentKeys.contains(ck) && seen.add(m.dedupKey)) {
            merged.add(m);
          }
        }
        merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages = merged;
        await _saveToCache();
        _resetShowIndex();
        _notify();  // always notify after merge, even if batch not running
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: server merge failed: $e');
    }

    // Resume polling if a batch is running on the server
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
                      branch: 'main',
                      mode: state?['mode']?.toString() ?? 'code');
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: batch resume failed: $e');
    }

    // Fetch saved repos
    try {
      _savedRepos = await _api.getChatRepos();
      logViewer('ChatProvider.loadFromCache: loaded ${_savedRepos.length} repos');
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: repo fetch failed: $e');
    }

    // Auto-fetch task log
    fetchTaskLog();
    // Auto-fetch branches (cold start: _branches is empty)
    fetchBranches();
  }

  // -- Send: queue prompt(s) on server, then poll for progress --
  Future<void> send(
    String prompt, {
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;

    logViewer('ChatProvider.send: START repo=$repo branch=$branch mode=$mode');
    _error = null;

    // If repo or branch changed, switch to new conversation history
    // Mode switch on same repo+branch → keep messages (plan then code = one chat)
    if (repo != serverRepo || branch != serverBranch) {
      final repoChanged = repo != serverRepo;
      serverRepo = repo;
      serverBranch = branch;
      serverMode = mode;
      _messages.clear();
      _showFromIndex = 0;
      _queuePosition = 0;
      _queueTotal = 0;
      _pollTimer?.cancel();
      await _saveToCache();
      _notify();
      // Fetch branches if repo changed (send() is often the first place serverRepo gets set)
      if (repoChanged && repo.isNotEmpty) {
        fetchBranches();
      }
    } else if (mode != serverMode) {
      serverMode = mode;
      await _saveToCache();
    }

    // Add user message to chat immediately
    final userMsg = ChatMessage(
      role: 'user',
      content: trimmed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _messages.add(userMsg);
    await _saveToCache();
    _resetShowIndex();

    try {
      final result = await _api.sendChatBatch(
        prompts: [trimmed],
        repo: repo,
        branch: branch,
        mode: mode,
      );
      logViewer('ChatProvider.send: result=$result');

      if (result['status'] == 'queued') {
        _queuePosition = (result['position'] as int?) ?? 0;
        _queueTotal = (result['total'] as int?) ?? 1;
        _pollFailures = 0;
        _loading = true;
        _loadingSince = DateTime.now();
        logViewer('ChatProvider.send: queued pos=$_queuePosition total=$_queueTotal — polling');
        _notify();
        _startPolling(repo: repo, branch: branch, mode: mode);
      } else if (result['status'] == 'appended') {
        // Appended to running batch — poll active, just update total
        _queueTotal = (result['total'] as int?) ?? _queueTotal;
        _loading = true;
        logViewer('ChatProvider.send: appended to batch (total=$_queueTotal)');
        _notify();
      } else {
        logViewer('ChatProvider.send: unexpected status=${result['status']}');
        _error = (result['error']?.toString()) ?? 'Server did not accept the request';
        _queueTotal = 0;
        _notify();
      }
    } catch (e) {
      logViewer('ChatProvider.send: ERROR ${ApiService.friendlyError(e)}');
      _error = ApiService.friendlyError(e);
      _queueTotal = 0;
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
          final serverContentKeys = <String>{};
          // Phase 1: server messages (canonical, have IDs)
          for (final m in serverMsgs) {
            if (seen.add(m.dedupKey)) {
              merged.add(m);
              serverContentKeys.add('${m.role}:${m.content}');
            }
          }
          // Phase 2: client messages only if not covered by server
          for (final m in _messages) {
            final ck = '${m.role}:${m.content}';
            if (!serverContentKeys.contains(ck) && seen.add(m.dedupKey)) {
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
          logViewer('ChatProvider.poll: batch running=${batch['running']} pos=${batch['position']} total=${batch['total']} wasLoading=$wasLoading');
          _loading = batch['running'] == true;
          _queuePosition = (batch['position'] as int?) ?? _queuePosition;
          _queueTotal = (batch['total'] as int?) ?? _queueTotal;

          // Parse prompt list for per-prompt cancel UI
          final prompts = batch['prompts'] as List?;
          if (prompts != null) {
            _batchPrompts = prompts.map((e) => e.toString()).toList();
          }
          final modes = batch['modes'] as List?;
          if (modes != null) {
            _batchModes = modes.map((e) => e.toString()).toList();
          }

          if (wasLoading && !_loading) {
            _loadingSince = null;
            _pollTimer?.cancel();
            _queuePosition = 0;
            _queueTotal = 0;  // hide progress bar
            logViewer('ChatProvider.poll: DONE pos=$_queuePosition total=$_queueTotal');
            fetchTaskLog();  // refresh task log after batch completes
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
    if (repo.isEmpty || repo == serverRepo) return;
    serverRepo = repo;
    fetchBranches();
  }

  Future<void> switchRepo(String repo, String mode, {String branch = 'main'}) async {
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
    _loading = false;
    _loadingSince = null;
    // Fetch messages for this repo from server
    try {
      final state = await _api.getChat(repo: repo, mode: mode);
      // Restore branch from server state if available
      final serverBr = state['branch']?.toString();
      if (serverBr != null && serverBr.isNotEmpty) {
        serverBranch = serverBr;
      }
      final serverMsgs = (state['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      _messages = serverMsgs;
      _resetShowIndex();  // re-clamp for new repo's message count
      _error = null;
      await _saveToCache();
    } catch (e) {
      logViewer('ChatProvider.switchRepo: failed to fetch messages: $e');
    }
    _notify();
    // Refresh repo list (new repo might appear later after messages)
    refreshRepos();
    // Load task log for this repo
    fetchTaskLog();
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
        final serverContentKeys = <String>{};
        for (final m in serverMsgs) {
          if (seen.add(m.dedupKey)) {
            merged.add(m);
            serverContentKeys.add('${m.role}:${m.content}');
          }
        }
        for (final m in _messages) {
          final ck = '${m.role}:${m.content}';
          if (!serverContentKeys.contains(ck) && seen.add(m.dedupKey)) {
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

  Future<void> fetchTaskLog() async {
    if (serverRepo.isEmpty) return;
    try {
      _taskLog = await _api.getTaskLog(serverRepo);
      _taskLogRepo = serverRepo;
      logViewer('ChatProvider.fetchTaskLog: ${_taskLog.length} entries for $serverRepo');
      _notify();
    } catch (e) {
      logViewer('ChatProvider.fetchTaskLog: $e');
    }
  }

  Future<void> fetchBranches() async {
    if (serverRepo.isEmpty) {
      _branchesAttempted = true;  // nothing to load
      return;
    }
    try {
      _branches = await _api.getBranches(serverRepo);
      _branchesAttempted = true;
      logViewer('ChatProvider.fetchBranches: ${_branches.length} branches for $serverRepo');
      _notify();
    } catch (e) {
      _branchesAttempted = true;
      _branches = [];
      logViewer('ChatProvider.fetchBranches: $e');
      _notify();
    }
  }

  // -- Cancel / Clear --
  Future<void> cancel() async {
    _pollTimer?.cancel();
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
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
