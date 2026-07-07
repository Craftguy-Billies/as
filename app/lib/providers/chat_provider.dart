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
  bool _batchSeenRunning = false;  // poll saw batch.running at least once
  Timer? _pollTimer;
  int _lastNotifiedHash = 0;  // avoid redundant rebuilds

  // Conversation tracking: detect when server creates a new conversation
  String? _lastConversationId;
  bool _conversationChanged = false;
  String? _conversationChangeReason;
  bool _skipNextConvChangeMsg = false;  // true after manual newConversation()

  // Pending message tracking: user messages queued but not yet confirmed by server
  final Set<String> _pendingUserContents = {};
  // Count of server-confirmed user contents: used to skip local copies
  // without accidentally deduping identical messages (e.g., two "hi!"s)
  final Map<String, int> _confirmedUserContents = {};
  // Deferred user message bubbles: only shown when agent starts processing that
  // position (queuePosition reaches the message's index). Added by send(), shown
  // in poll tick when position advances.
  // List of (content, send-timestamp) pairs — preserves order and handles duplicates.
  final List<(String, int)> _deferred = [];
  int _lastPositionShown = -1;  // highest queuePosition whose user msg was inserted

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
  String? get lastConversationId => _lastConversationId;
  bool get conversationChanged => _conversationChanged;
  String? get conversationChangeReason => _conversationChangeReason;

  /// Call after UI has displayed the conversation change banner
  void acknowledgeConversationChange() {
    _conversationChanged = false;
    _conversationChangeReason = null;
    _notify();
  }

  /// Check if a user message is still pending (queued, not yet processed by server)
  bool isMessagePending(String content) => _pendingUserContents.contains(content);
  List<Map<String, dynamic>> _savedRepos = [];
  List<Map<String, dynamic>> get savedRepos => _savedRepos;

  List<String> _branches = [];
  List<String> get branches => _branches;
  bool get branchesAttempted => _branchesAttempted;
  bool _branchesAttempted = false;  // differentiate "loading" from "empty"

  // Lazy message loading: show latest N first, "load earlier" button at top.
  // Set high (1000) so a single user turn with 500+ ZIP-streamed events shows
  // fully. "Load earlier" only appears for multi-turn conversation history.
  final _pageSize = 1000;
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
    // Include all message content hashes to detect actual data changes,
    // not just the last message. Prevents stale UI when messages are
    // re-ordered or duplicates appear mid-list.
    int msgHash = 0;
    for (final m in msgs) {
      msgHash = msgHash ^ Object.hash(m.role, m.content, m.timestamp, m.id);
    }
    final hash = Object.hash(
      msgHash,
      msgs.length,
      _loading,
      _error,
      _queuePosition,
      _queueTotal,
      _queueDone,
      _showFromIndex,
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
        // Restore deferred user messages (survives app restart)
        if (data is Map<String, dynamic>) {
          final deferredRaw = data['deferred'] as List?;
          if (deferredRaw != null) {
            _deferred.clear();
            for (final d in deferredRaw) {
              if (d is Map<String, dynamic>) {
                _deferred.add((
                  (d['content'] ?? '').toString(),
                  (d['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
                ));
              }
            }
          }
          final pendingRaw = data['pendingUserContents'] as List?;
          if (pendingRaw != null) {
            _pendingUserContents.clear();
            for (final p in pendingRaw) {
              _pendingUserContents.add(p.toString());
            }
          }
          _lastPositionShown = (data['lastPositionShown'] as int?) ?? -1;
          logViewer('ChatProvider.loadFromCache: restored ${_deferred.length} deferred msgs, lastPosShown=$_lastPositionShown, ${_pendingUserContents.length} pending');
        }
      } catch (_) {
        await prefs.remove(_cacheKey);
      }
    }

    // --- Phase B: Fetch saved repos from server (for reference only) ---
    // Previously this also set serverRepo as fallback, but that leaks
    // cross-device: if Device A used repoA and Device B has no local cache,
    // Phase B would set Device B's serverRepo to repoA, making Device B
    // see repoA's messages and batch queue. Each device must independently
    // choose its repo.
    try {
      _savedRepos = await _api.getChatRepos();
      logViewer('ChatProvider.loadFromCache: loaded ${_savedRepos.length} repos from server (reference only)');
      if (_savedRepos.isNotEmpty) {
        logViewer('ChatProvider.loadFromCache: first savedRepo=${_savedRepos.first['repo']} branch=${_savedRepos.first['branch']}');
      }
    } catch (e) {
      logViewer('ChatProvider.loadFromCache: repo fetch failed: $e');
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
        // Secondary dedup: assistant messages with identical content but
        // different server IDs (e.g. from KV write failure + rspt recovery)
        // should not appear twice. Track role:content separately from id.
        final seenAssistantContent = <String>{};
        for (final m in serverMsgs) {
          // Content-based dedup for assistant messages (same root cause
          // as poll merge — KV eventual consistency).
          if (m.role == 'assistant' && m.content.isNotEmpty) {
            final contentKey = 'asst_content:${m.content}';
            if (seen.contains(contentKey)) continue;
            seen.add(contentKey);
          }
          // Content-based dedup for user messages: send() adds user
          // messages immediately; when the server returns them via poll,
          // the local copy would be added again (Phase 2 sees different
          // dedupKey: no id vs server id). Prevent duplicate by tracking
          // content alongside dedupKey.
          if (m.role == 'user' && m.content.isNotEmpty) {
            final userKey = 'user_content:${m.content}';
            if (seen.contains(userKey)) continue;
            seen.add(userKey);
          }
          if (seen.add(m.dedupKey)) {
            // Content-based dedup for assistant messages: if the same
            // response text was already added with a different server ID,
            // skip this duplicate.
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
            merged.add(m);
          }
        }
        for (final m in _messages) {
          // Skip stale heartbeats — same reason as poll merge.
          if (m.role == 'event' && m.content.contains('[STATUS]')) {
            continue;
          }
          // Skip user messages already covered by server messages (content-based).
          if (m.role == 'user' && m.content.isNotEmpty &&
              seen.contains('user_content:${m.content}')) {
            continue;
          }
          if (seen.add(m.dedupKey)) {
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
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

    // --- Phase D: Resume polling if batch exists (running OR queued) ---
    try {
      final state = await _api.getChat(repo: serverRepo, mode: serverMode);
      final batch = state?['batch'] as Map<String, dynamic>?;
      final total = (batch?['total'] as int?) ?? 0;
      logViewer('ChatProvider.loadFromCache: batch total=$total pos=${batch?['position']} running=${batch?['running']}');
      // Resume polling whenever there's a queue, regardless of isRunning.
      // The batch may be queued but not yet running (worker hasn't picked it
      // up) — the poll callback handles completion detection.
      if (total > 0) {
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

    logViewer('ChatProvider.send: START repo=$repo branch=$branch mode=$mode msg="${trimmed.length > 80 ? '${trimmed.substring(0, 80)}...' : trimmed}"');
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
      if (status == 'queued' || status == 'appended') {
        _pollFailures = 0;
        _loading = true;
        _loadingSince = DateTime.now();
        _pendingUserContents.add(trimmed);
        _deferred.add((trimmed, DateTime.now().millisecondsSinceEpoch));
        // Queue position from server — 0 for new batch, non-0 if appended
        _queuePosition = (result['position'] as int?) ?? 0;
        _queueTotal = (result['total'] as int?) ?? 1;
        // NEVER show user message immediately — always defer until the poll
        // tick confirms the server has received and is processing this message.
        // This prevents "sent" appearing before the queue actually processes it,
        // and prevents the message from disappearing on refresh.
        logViewer('ChatProvider.send: deferred user msg (total=$_queueTotal status=$status) — will show when agent reaches it');
        // Do NOT save cache here — deferred messages haven't been confirmed by
        // the server yet. The poll tick calls _saveToCache() after the merge,
        // which is when messages are properly deduped and confirmed.
        logViewer('ChatProvider.send: queued pos=$_queuePosition total=$_queueTotal — polling');
        _notify();
        // Only start a new poll if one isn't already running. Calling
        // _startPolling on an active batch resets _batchSeenRunning and
        // re-creates the timer, delaying completion detection by 15s.
        if (_pollTimer?.isActive != true) {
          _startPolling(repo: repo, branch: branch, mode: mode);
        }
      } else {
        logViewer('ChatProvider.send: unexpected status=$status');
        _error = (result['error']?.toString()) ?? 'Server did not accept the request';
        // Keep existing queue state if a batch was already running.
        if (_queueTotal == 0) {
          _queuePosition = 0;
          _queueTotal = 0;
          _queueDone = 0;
        }
        _notify();
      }
    } catch (e) {
      logViewer('ChatProvider.send: ERROR ${ApiService.friendlyError(e)}');
      _error = ApiService.friendlyError(e);
      // Only reset queue state if there was NO batch running before the error.
      // If a batch was already running, this was an append failure — the batch
      // continues on the server and we should keep showing progress in the UI.
      if (_queueTotal == 0) {
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
      }
      _notify();
    }
  }

  // -- Polling: fetch messages + progress with exponential backoff --
  void _startPolling({required String repo, required String branch, required String mode}) {
    _pollTimer?.cancel();
    _batchSeenRunning = false;  // new batch, new detection cycle
    _pollFailures = 0;  // reset failure counter for new poll cycle
    final gen = ++_pollGeneration;
    final pollStarted = DateTime.now();
    Duration _delay = const Duration(seconds: 2); // starts at 2s, grows on failure
    logViewer('ChatProvider.poll: timer STARTED (gen=$gen repo=$repo branch=$branch)');

    void tick() async {
      if (gen != _pollGeneration) return; // stale: repo switched or chat cleared

      // Overall poll timeout — batch runs on server independently, so this
      // only stops the local UI updates. 120 minutes covers even very long agents.
      if (DateTime.now().difference(pollStarted).inMinutes >= 120) {
        _pollTimer?.cancel();
        _loading = false;
        _loadingSince = null;
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
        _error = 'Polling timed out (2h). Queue may still run on server.';
        logViewer('ChatProvider.poll: TIMEOUT');
        _notify();
        return;
      }
      try {
        final state = await _api.getChat(repo: repo, mode: mode);
        if (gen != _pollGeneration) return; // stale after await
        if (state == null) return;
        _error = null;  // clear error on any successful poll

        // Detect conversation changes — insert a centered system message
        final newConvId = state['conversation_id']?.toString();
        final convChange = state['conversation_change'] as Map<String, dynamic>?;
        if (newConvId != null && newConvId.isNotEmpty &&
            _lastConversationId != newConvId) {
          if (_skipNextConvChangeMsg) {
            _skipNextConvChangeMsg = false;
          } else {
            final serverReason = convChange?['reason']?.toString();
            final serverAt = convChange?['at']?.toString();
            final reason = serverReason ?? 'Server started a new conversation';
            // Use server timestamp so system message sorts correctly relative
            // to server messages, avoiding device-clock skew issues.
            final sysTs = serverAt != null
                ? DateTime.tryParse(serverAt)?.millisecondsSinceEpoch
                : null;
            _messages.add(ChatMessage(
              role: 'system', content: reason,
              timestamp: sysTs ?? DateTime.now().millisecondsSinceEpoch,
            ));
            logViewer('ChatProvider.poll: NEW CONVERSATION system msg: $reason');
          }
        }
        _lastConversationId = newConvId;

        // Fetch queue progress BEFORE merge so deferred user messages
        // are inserted BEFORE the merge sorts by timestamp. Otherwise
        // _messages.add() appends after merge and the user bubble lands
        // after system/AI messages (wrong order).
        var batch = state['batch'] as Map<String, dynamic>?;
        if (batch != null) {
          _queuePosition = (batch['position'] as int?) ?? _queuePosition;
          _queueTotal = (batch['total'] as int?) ?? _queueTotal;
          _queueDone = (batch['done'] as int?) ?? _queuePosition;

          // Insert deferred user messages when position advances.
          _lastPositionShown ??= -1;
          while (_lastPositionShown < _queuePosition && _lastPositionShown + 1 < _deferred.length) {
            final idx = _lastPositionShown + 1;
            final (content, sendTs) = _deferred[idx];
            final alreadyInChat = _messages.any((m) => m.role == 'user' && m.content == content);
            if (!alreadyInChat) {
              _messages.add(ChatMessage(
                role: 'user', content: content,
                timestamp: sendTs,
              ));
              logViewer('ChatProvider.poll: inserted deferred user msg #$idx: "$content" (ts=$sendTs)');
            } else {
              logViewer('ChatProvider.poll: user msg #$idx already in chat, skipping');
            }
            _lastPositionShown = idx;
          }
        }

        // Merge server messages (events, responses) into local chat
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        logViewer('ChatProvider.poll: serverMsgs=${serverMsgs.length} localMsgs=${_messages.length} convId=$newConvId pendingUserMsgs=${_pendingUserContents.length}');
        if (serverMsgs.isNotEmpty) {
          final merged = <ChatMessage>[];
          _confirmedUserContents.clear();
          final seen = <String>{};
          // Secondary dedup: assistant messages with identical content but
          // different server IDs (e.g. from KV write failure + rspt recovery)
          // should not appear twice.
          final seenAssistantContent = <String>{};
          int dedupServerId = 0;
          int dedupServerAsstContent = 0;
          int dedupServerUserContent = 0;
          int dedupClientSeen = 0;
          // Phase 1: server messages (canonical, have IDs).
          for (final m in serverMsgs) {
            // Filter heartbeat/STATUS events from server — the worker may
            // still push them in some code paths; filtering here ensures
            // they never appear as chat bubbles regardless of worker version.
            if (m.role == 'event' && m.content.contains('[STATUS]')) {
              continue;
            }
            // Content-based dedup for assistant messages: KV eventual
            // consistency can cause the same response text to be pushed
            // twice with different IDs. Keeping only the first occurrence
            // prevents duplicate assistant bubbles in the UI.
            if (m.role == 'assistant' && m.content.isNotEmpty) {
              final contentKey = 'asst_content:${m.content}';
              if (seen.contains(contentKey)) { dedupServerAsstContent++; continue; }
              seen.add(contentKey);
            }
            // Content-based dedup for user messages: send() adds user
            // messages immediately; when the server returns them via poll,
            // the local copy would be added again (Phase 2 sees different
            // dedupKey: no id vs server id). Track confirmed contents
            // with a count to handle identical messages correctly.
            // Also clear from pending set — server has confirmed this message.
            if (m.role == 'user' && m.content.isNotEmpty) {
              if (_pendingUserContents.remove(m.content)) {
                logViewer('ChatProvider.poll: server confirmed pending msg, remaining=${_pendingUserContents.length}');
              }
              _confirmedUserContents.update(m.content, (v) => v + 1, ifAbsent: () => 1);
            }
            if (seen.add(m.dedupKey)) {
              if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
                continue;
              }
              merged.add(m);
            } else { dedupServerId++; }
          }
          // Phase 2: client messages only if not covered by server
          for (final m in _messages) {
            // Skip stale heartbeats from local cache — the worker sends
            // fresh ones during running phase and filters them when a
            // response arrives. Without this, heartbeats from a previous
            // running phase survive in the local cache and reappear after
            // auto-refresh even though the agent has already completed.
            if (m.role == 'event' && m.content.contains('[STATUS]') &&
                (m.content.contains('Working') || m.content.contains('working'))) {
              continue;
            }
            // Skip user messages already covered by server messages.
            // Use count-based tracking so identical messages (e.g., two "hi!"s)
            // each get one local copy skipped — not both deduped by content.
            if (m.role == 'user' && m.content.isNotEmpty) {
              final cnt = _confirmedUserContents[m.content] ?? 0;
              if (cnt > 0) {
                _confirmedUserContents[m.content] = cnt - 1;
                continue;
              }
            }
            if (seen.add(m.dedupKey)) {
              if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
                continue;
              }
              merged.add(m);
            } else { dedupClientSeen++; }
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
            logViewer('ChatProvider.poll: merged ${_messages.length}→${merged.length} messages '
                      '(dedup: id=${dedupServerId} asstContent=${dedupServerAsstContent} '
                      'userContent=${dedupServerUserContent} clientSeen=${dedupClientSeen})');
            _messages = merged;
            _resetShowIndex();  // re-clamp after possible trim
            _error = null;
            await _saveToCache();
          }
        }

        // Update progress from server
        if (batch != null) {
          final wasLoading = _loading;
          final isRunning = batch['running'] == true;
          final batchRepo = (batch['repo']?.toString() ?? '').trim();
          // Only show loading when the running batch is for THIS repo.
          // _batch_running is a global flag — a batch on repo B should NOT
          // show a spinner on repo A's poll.
          final relevantToMe = !isRunning || batchRepo.isEmpty || batchRepo == repo;
          logViewer('ChatProvider.poll: batch running=$isRunning pos=${batch['position']} '
                    'total=${batch['total']} done=${batch['done']} repo=$batchRepo '
                    'myRepo=$repo relevant=$relevantToMe wasLoading=$wasLoading queueTotal=$_queueTotal');

          // CRITICAL: Do NOT set _loading=false when the batch hasn't started yet.
          // send() returned {status:'queued'} → _queueTotal > 0 but _batch_running
          // is still False because the worker hasn't picked it up. If we set
          // _loading=false and cancel the timer here, the batch runs invisibly.
          if (relevantToMe) {
            if (_loading != isRunning) {
              logViewer('ChatProvider.poll: _loading ${_loading}→$isRunning (relevantToMe=$relevantToMe)');
            }
            _loading = isRunning;
          }

          // Parse prompt list for per-prompt cancel UI
          final prompts = batch['prompts'] as List?;
          if (prompts != null) {
            _batchPrompts = prompts.map((e) => e.toString()).toList();
          }
          final modes = batch['modes'] as List?;
          if (modes != null) {
            _batchModes = modes.map((e) => e.toString()).toList();
          }

          // Track whether this batch was ever seen as "running". Completion is
          // detected when isRunning goes False after having been True.
          if (isRunning && _queueTotal > 0) {
            _batchSeenRunning = true;
            logViewer('ChatProvider.poll: batch seen running');
          }

          // Stop polling when batch completes.
          // CONDITIONS (all must be true):
          //   1. !isRunning — server says no batch active
          //   2. _queueTotal > 0 — we queued prompts (poll was started for a reason)
          //   3. EITHER:
          //      a. _batchSeenRunning — we witnessed the batch in the running state
          //      b. poll age > 15s — send was long enough ago that the batch must
          //         have finished (handles the 2-second window where a fast batch
          //         runs and completes between two poll iterations without ever
          //         being seen as "running" by the Flutter side)
          if (!isRunning && _queueTotal > 0) {
            final pollAge = DateTime.now().difference(pollStarted);
            if (_batchSeenRunning || pollAge.inSeconds > 15) {
              _loadingSince = null;
              _pollTimer?.cancel();
              _loading = false;
              _queuePosition = 0;
              _queueTotal = 0;
              _queueDone = 0;
              _batchSeenRunning = false;
              _pendingUserContents.clear();  // prevent stale entries across batch cycles
              _confirmedUserContents.clear();
              _deferred.clear();
              _lastPositionShown = -1;
              _saveToCache();  // persist cleared deferred state
              logViewer('ChatProvider.poll: batch completed — stopped '
                        '(seenRunning=$_batchSeenRunning pollAge=${pollAge.inSeconds}s wasLoading=$wasLoading)');
            } else {
              logViewer('ChatProvider.poll: batch not yet started — keeping poll '
                        '(pollAge=${pollAge.inSeconds}s queueTotal=$_queueTotal)');
            }
          } else if (!isRunning && _queueTotal <= 0) {
            // No queue ever — nothing to wait for
            _loadingSince = null;
            _pollTimer?.cancel();
            _loading = false;
            logViewer('ChatProvider.poll: no batch — stopped');
          }
        }

        _pollFailures = 0;
        _delay = const Duration(seconds: 2); // reset backoff on success
        _notify();
      } catch (e) {
        _pollFailures++;
        logViewer('ChatProvider.poll: fail #$_pollFailures (next in ${_delay.inSeconds}s): $e');
        if (_pollFailures >= 30) {
          _error = 'Lost connection to server (${_pollFailures} attempts). Queue may still be running.';
          _loading = false;
          _loadingSince = null;
          _pollTimer?.cancel();
          _notify();
          return; // don't reschedule
        }
        // Exponential backoff with jitter: 2→4→8→16→30→60, capped at 60s
        final secs = (_delay.inSeconds * 2).clamp(2, 60);
        _delay = Duration(seconds: secs);
      }
      // Self-rescheduling: schedule next poll after the current delay
      if (gen == _pollGeneration) {
        _pollTimer = Timer(_delay, tick);
      }
    }

    tick(); // start immediately
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

    // No guard needed — backend stores state per-repo (independent queues).
    // A batch running on repo A is unaffected by switching to repo B.
    // The user can switch back to see repo A's results when ready.

    serverRepo = repo;
    serverBranch = branch;
    serverMode = mode;
    _branches = [];  // clear immediately to avoid stale flash from previous repo
    _branchesAttempted = false;
    _pollTimer?.cancel();
    _queuePosition = 0;
    _queueTotal = 0;
    _queueDone = 0;
    _loading = true;  // show loading while fetching new repo's data
    _loadingSince = DateTime.now();
    _notify();
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
      _loading = false;
      _loadingSince = null;
      await _saveToCache();
      logViewer('ChatProvider.switchRepo: loaded ${_messages.length} msgs for repo=$repo branch=$serverBranch');

      // If this repo has a running batch (started by another device), resume polling
      final batch = state['batch'] as Map<String, dynamic>?;
      final batchTotal = (batch?['total'] as int?) ?? 0;
      if (batchTotal > 0) {
        _queuePosition = (batch?['position'] as int?) ?? 0;
        _queueTotal = batchTotal;
        _queueDone = (batch?['done'] as int?) ?? 0;
        final bPrompts = batch?['prompts'] as List?;
        if (bPrompts != null) _batchPrompts = bPrompts.map((e) => e.toString()).toList();
        final bModes = batch?['modes'] as List?;
        if (bModes != null) _batchModes = bModes.map((e) => e.toString()).toList();
        _loading = true;
        _loadingSince = DateTime.now();
        _startPolling(repo: serverRepo, branch: serverBranch, mode: serverMode);
        logViewer('ChatProvider.switchRepo: resumed polling for batch (total=$batchTotal pos=$_queuePosition done=$_queueDone)');
      }
    } catch (e) {
      logViewer('ChatProvider.switchRepo: failed to fetch messages: $e');
      _loading = false;
      _loadingSince = null;
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

      // Detect conversation changes — insert a centered system message
      final newConvId = data['conversation_id']?.toString();
      final convChange = data['conversation_change'] as Map<String, dynamic>?;
      if (newConvId != null && newConvId.isNotEmpty &&
          _lastConversationId != newConvId) {
        if (_skipNextConvChangeMsg) {
          _skipNextConvChangeMsg = false;
        } else {
          final serverReason = convChange?['reason']?.toString();
          final reason = serverReason ?? 'Server started a new conversation';
          _messages.add(ChatMessage(
            role: 'system', content: reason,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ));
          logViewer('ChatProvider.refreshMessages: NEW CONVERSATION system msg: $reason');
        }
      }
      _lastConversationId = newConvId;

      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      logViewer('ChatProvider.refreshMessages: serverMsgs=${serverMsgs.length} localMsgs=${_messages.length} convId=$newConvId pendingUserMsgs=${_pendingUserContents.length}');
      if (serverMsgs.isNotEmpty) {
        final merged = <ChatMessage>[];
        _confirmedUserContents.clear();
        final seen = <String>{};
        final seenAssistantContent = <String>{};
        for (final m in serverMsgs) {
          // Content-based dedup for assistant messages (same root cause
          // as poll merge — KV eventual consistency).
          if (m.role == 'assistant' && m.content.isNotEmpty) {
            final contentKey = 'asst_content:${m.content}';
            if (seen.contains(contentKey)) continue;
            seen.add(contentKey);
          }
          // Content-based dedup for user messages: send() adds user
          // messages immediately; prevent duplicates when server returns them.
          // Also clear from pending set — server has confirmed this message.
          if (m.role == 'user' && m.content.isNotEmpty) {
            if (_pendingUserContents.remove(m.content)) {
              logViewer('ChatProvider.refreshMessages: server confirmed pending msg, remaining=${_pendingUserContents.length}');
            }
            _confirmedUserContents.update(m.content, (v) => v + 1, ifAbsent: () => 1);
          }
          if (seen.add(m.dedupKey)) {
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
            merged.add(m);
          }
        }
        for (final m in _messages) {
          // Skip stale heartbeats — same reason as poll merge.
          if (m.role == 'event' && m.content.contains('[STATUS]')) {
            continue;
          }
          // Skip user messages already covered by server messages.
          // Use count-based tracking so identical messages (e.g., two "hi!"s)
          // each get one local copy skipped — not both deduped by content.
          if (m.role == 'user' && m.content.isNotEmpty) {
            final cnt = _confirmedUserContents[m.content] ?? 0;
            if (cnt > 0) {
              _confirmedUserContents[m.content] = cnt - 1;
              continue;
            }
          }
          if (seen.add(m.dedupKey)) {
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
            merged.add(m);
          }
        }
        merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messages = merged;
        await _saveToCache();
        _resetShowIndex();
        _notify();
      }

      // Update batch state from server. Critical when the poll timer was
      // suspended (e.g. app backgrounded) and never detected completion.
      // Without this, _loading and _queueTotal stay stuck at old values
      // even though the batch finished — the UI shows "agent is working"
      // indefinitely.
      final batch = data['batch'] as Map<String, dynamic>?;
      if (batch != null) {
        final isRunning = batch['running'] == true;
        final total = (batch['total'] as int?) ?? 0;
        _queuePosition = (batch['position'] as int?) ?? 0;
        _queueTotal = total;
        _queueDone = (batch['done'] as int?) ?? _queuePosition;

        // CRITICAL: Do NOT cancel polling when total > 0 but isRunning is false.
        // This happens when the batch was just queued but the worker hasn't
        // picked it up yet. The poll callback handles completion detection
        // with _batchSeenRunning + pollAge guards — but those guards can't
        // fire if we kill the timer here.
        if (_queueTotal > 0) {
          // Batch is already complete on the server — don't restart polling.
          // Otherwise polling shows "agent working" for up to 15s needlessly.
          final done = _queueDone;
          final isRunning = batch['running'] == true;
          if ((done >= total || _queuePosition >= total) && !isRunning) {
            _queuePosition = 0;
            _queueTotal = 0;
            _queueDone = 0;
            _loading = false;
            _loadingSince = null;
            _batchSeenRunning = false;
            _pollTimer?.cancel();
            logViewer('ChatProvider.refreshMessages: batch already complete — not restarting poll');
          } else {
            // Queue exists — ensure polling runs regardless of isRunning.
            _loading = true;
            _loadingSince ??= DateTime.now();
            _startPolling(repo: serverRepo, branch: serverBranch, mode: serverMode);
          }
        } else {
          _loading = false;
          _pollTimer?.cancel();
          _loadingSince = null;
          _batchSeenRunning = false;
        }
        final prompts = batch['prompts'] as List?;
        if (prompts != null) {
          _batchPrompts = prompts.map((e) => e.toString()).toList();
        }
        final modes = batch['modes'] as List?;
        if (modes != null) {
          _batchModes = modes.map((e) => e.toString()).toList();
        }
      } else {
        // Server returned no batch state (queue was fully processed and
        // GC'd). Reset local batch tracking to prevent stuck loading.
        _queuePosition = 0;
        _queueTotal = 0;
        _queueDone = 0;
        _loading = false;
        _loadingSince = null;
        _batchSeenRunning = false;
        _batchPrompts = [];
        _batchModes = [];
        _pollTimer?.cancel();
      }

      // Recover from "Lost connection" error if the API call succeeded.
      if (_error?.contains('Lost connection') == true) {
        _error = null;
        _pollFailures = 0;
        // Restart polling if there's still a queue to process
        if (_queueTotal > 0) {
          _startPolling(repo: serverRepo, branch: serverBranch, mode: serverMode);
        }
      }
      _notify();
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

      // Step 2: Update repo/branch from server.
      // Only trust server's repo when our local one is empty — prevents
      // overwriting the user's explicitly chosen repo (same guard as
      // refreshMessages at line 212).
      final serverRp = data['repo']?.toString();
      if (serverRp != null && serverRp.isNotEmpty && serverRepo.isEmpty) {
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
        final seenAssistantContent = <String>{};
        for (final m in serverMsgs) {
          // Content-based dedup for assistant messages (same root cause
          // as poll merge — KV eventual consistency).
          if (m.role == 'assistant' && m.content.isNotEmpty) {
            final contentKey = 'asst_content:${m.content}';
            if (seen.contains(contentKey)) continue;
            seen.add(contentKey);
          }
          // Content-based dedup for user messages: send() adds user
          // messages immediately; prevent duplicates when server returns them.
          if (m.role == 'user' && m.content.isNotEmpty) {
            final userKey = 'user_content:${m.content}';
            if (seen.contains(userKey)) continue;
            seen.add(userKey);
          }
          if (seen.add(m.dedupKey)) {
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
            merged.add(m);
          }
        }
        for (final m in _messages) {
          // Skip stale heartbeats from local cache — same reason as poll merge.
          if (m.role == 'event' && m.content.contains('[STATUS]')) {
            continue;
          }
          // Skip user messages already covered by server messages (content-based).
          if (m.role == 'user' && m.content.isNotEmpty &&
              seen.contains('user_content:${m.content}')) {
            continue;
          }
          if (seen.add(m.dedupKey)) {
            if (m.role == 'assistant' && !seenAssistantContent.add('assistant:${m.content}')) {
              continue;
            }
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
        final isRunning = batch['running'] == true;
        final total = (batch['total'] as int?) ?? 0;
        _queuePosition = (batch['position'] as int?) ?? 0;
        _queueTotal = total;
        _queueDone = (batch['done'] as int?) ?? _queuePosition;

        // CRITICAL: Do NOT cancel polling when total > 0 but isRunning is false.
        // Same reasoning as refreshMessages — the poll callback's completion
        // detection guards need the timer to stay alive.
        if (_queueTotal > 0) {
          _loading = true;
          _loadingSince ??= DateTime.now();
          _startPolling(repo: serverRepo, branch: serverBranch, mode: serverMode);
        } else {
          _loading = false;
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
    // Cancel only the CURRENT running task, advance to next queued task.
    // Server handles advancement; next poll syncs authoritative state.
    logViewer('ChatProvider.cancel: skipping current task #$_queuePosition');
    try {
      await _api.cancelPrompt(_queuePosition, repo: serverRepo);
    } catch (e) {
      logViewer('ChatProvider.cancel: $e');
    }
    _notify();  // next poll syncs state from server
  }

  /// Cancel a single prompt at [index] in the batch queue.
  /// Let server handle removal; next poll syncs authoritative state.
  Future<void> cancelPrompt(int index) async {
    if (index < 0 || index >= _batchPrompts.length) return;
    logViewer('ChatProvider.cancelPrompt: #$index "${_batchPrompts[index].length > 60 ? "${_batchPrompts[index].substring(0, 60)}..." : _batchPrompts[index]}"');

    try {
      final result = await _api.cancelPrompt(index, repo: serverRepo);
      if (result != null && result.containsKey('error')) {
        logViewer('ChatProvider.cancelPrompt error: ${result['error']}');
      }
    } catch (e) {
      logViewer('ChatProvider.cancelPrompt exception: $e');
    }
    _notify();  // next periodic poll (~2s) will sync authoritative state
  }

  /// Start a fresh conversation — keeps chat history, clears server conv state.
  Future<void> newConversation() async {
    if (serverRepo.isEmpty) {
      logViewer('ChatProvider.newConversation: no repo selected, skipping');
      return;
    }
    _pollTimer?.cancel();
    _pollGeneration++;  // invalidate in-flight tick (prevents old conv_id leak)
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    _queueDone = 0;
    _pendingUserContents.clear();
    _confirmedUserContents.clear();
    _deferred.clear();
    _lastPositionShown = -1;
    _error = null;
    // Insert a centered system message immediately for instant feedback
    _messages.add(ChatMessage(
      role: 'system',
      content: '🔄 You started a new conversation',
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    _skipNextConvChangeMsg = true;
    _lastConversationId = null;
    _notify();

    try {
      await _api.newConversation(repo: serverRepo);
      logViewer('ChatProvider.newConversation: server confirmed');
    } catch (e) {
      logViewer('ChatProvider.newConversation: $e');
    }
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
    _pendingUserContents.clear();
    _confirmedUserContents.clear();
    _deferred.clear();
    _lastPositionShown = -1;
    _lastConversationId = null;
    _conversationChanged = false;
    _conversationChangeReason = null;
    _skipNextConvChangeMsg = false;
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
      final deferredList = _deferred.map((d) => {
        'content': d.$1,
        'timestamp': d.$2,
      }).toList();
      final payload = json.encode({
        'messages': _messages.map((m) => m.toJson()).toList(),
        'repo': serverRepo,
        'branch': serverBranch,
        'mode': serverMode,
        'deferred': deferredList,
        'pendingUserContents': _pendingUserContents.toList(),
        'lastPositionShown': _lastPositionShown,
        'queuePosition': _queuePosition,
        'queueTotal': _queueTotal,
        'queueDone': _queueDone,
      });
      await prefs.setString(_cacheKey, payload);
    } catch (_) {
      // silently ignore — SharedPreferences may fail if disk full
    }
  }
}
