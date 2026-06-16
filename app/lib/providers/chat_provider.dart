import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class ChatMessage {
  final String role; // "user" | "assistant"
  final String content;
  final int timestamp;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'timestamp': timestamp,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: (json['role'] ?? 'user').toString(),
        content: (json['content'] ?? '').toString(),
        timestamp: (json['timestamp'] ?? 0) as int,
      );
}

class ChatProvider extends ChangeNotifier {
  static const _cacheKey = 'chat_messages';

  final ApiService _api;
  List<ChatMessage> _messages = [];
  bool _loading = false;
  String? _error;
  DateTime? _loadingSince;  // safety: detect stuck loading
  String _status = '';      // live status: "Connecting...", "Agent is working..."

  // Batch queue
  final List<String> _pendingPrompts = [];
  int _queuePosition = 0;
  int _queueTotal = 0;
  int _batchPollFailures = 0;

  ChatProvider(this._api);

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get loading => _loading;
  String? get error => _error;
  String get status => _status;

  // Queue state
  List<String> get pendingPrompts => List.unmodifiable(_pendingPrompts);
  int get queuePosition => _queuePosition;
  int get queueTotal => _queueTotal;
  bool get isProcessingQueue => _queueTotal > 0 && _queuePosition < _queueTotal;

  Map<String, dynamic>? _serverState;
  Map<String, dynamic>? get serverState => _serverState;
  String _serverRepo = '';
  String get serverRepo => _serverRepo;
  String _serverMode = 'code';
  String get serverMode => _serverMode;

  Future<void> loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        final list = json.decode(raw) as List;
        if (list.isNotEmpty) {
          _messages = list
              .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList();
          notifyListeners();
        }
      } catch (_) {
        await prefs.remove(_cacheKey);
      }
    }
    // Also try loading from server (restores session if backend still has it)
    try {
      final data = await _api.getChat();
      _serverState = data;
      _serverRepo = data['repo']?.toString() ?? '';
      _serverMode = data['mode']?.toString() ?? 'code';
      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        // Merge: server messages + cache messages, deduplicated
        final merged = <ChatMessage>[];
        final seen = <String>{};
        for (final m in [...serverMsgs, ..._messages]) {
          final key = '${m.role}:${m.content}';
          if (seen.add(key)) merged.add(m);
        }
        _messages = merged;
        await _saveToCache();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ChatProvider: server message merge failed: $e');
    }

    // Resume batch polling if a batch is running on the server
    try {
      final state = await _api.getChat();
      final batch = state?['batch'] as Map<String, dynamic>?;
      final isRunning = batch?['running'] == true;
      final total = (batch?['total'] as int?) ?? 0;
      // Only resume if there are actual prompts queued (guard against stale state)
      if (isRunning && total > 0) {
        _queuePosition = (batch?['position'] as int?) ?? 0;
        _queueTotal = total;
        _loading = true;
        _loadingSince = DateTime.now();
        notifyListeners();
        _pollBatchProgress(
          repo: state?['repo']?.toString() ?? '',
          branch: 'main',
          mode: state?['mode']?.toString() ?? 'code',
        );
      }
    } catch (e) {
      debugPrint('ChatProvider: batch resume check failed: $e');
    }

    // Safety: clear stuck loading from a previous crash
    if (_loading && _loadingSince != null &&
        DateTime.now().difference(_loadingSince!) > const Duration(seconds: 210)) {
      _loading = false;
      _loadingSince = null;
    }
  }

  Timer? _livePollTimer;

  Future<void> sendMessage(
    String prompt, {
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty || _loading) return;

    _loading = true;
    _loadingSince = DateTime.now();
    _error = null;
    _status = 'Connecting to agent…';

    final userMsg = ChatMessage(
      role: 'user',
      content: trimmed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _messages.add(userMsg);
    await _saveToCache();
    notifyListeners();

    // -- Live polling: merge server events in real-time while POST is in-flight --
    _livePollTimer?.cancel();
    final _seen = <String>{};
    for (final m in _messages) {
      _seen.add('${m.role}:${m.content}');
    }
    _livePollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_loading) {
        _livePollTimer?.cancel();
        return;
      }
      try {
        final state = await _api.getChat();
        if (state == null) return;
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        var changed = false;
        for (final m in serverMsgs) {
          final key = '${m.role}:${m.content}';
          if (_seen.add(key)) {
            _messages.add(m);
            changed = true;
          }
        }
        if (changed) {
          _status = 'Agent is working…';
          await _saveToCache();
          notifyListeners();
        }
      } catch (_) {
        // Polling failures are non-fatal — POST is the source of truth
      }
    });

    try {
      final data = await _api.sendChatMessage(
        trimmed,
        repo: repo,
        branch: branch,
        mode: mode,
      );
      final response = (data['response'] ?? '').toString();
      if (response.isNotEmpty) {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: response,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      await _saveToCache();
    } catch (e) {
      _error = ApiService.friendlyError(e);
    } finally {
      _livePollTimer?.cancel();
      _loading = false;
      _loadingSince = null;
      _status = '';
      notifyListeners();
    }
  }

  /// Send all prompts to backend — processed sequentially in one conversation.
  /// Survives phone close. Polls for new messages + progress every 2 seconds.
  Future<void> enqueueBatch(List<String> prompts, {
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    final cleaned = prompts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (cleaned.isEmpty) return;

    // Don't block on _loading — batch appends should always go through
    _error = null;
    notifyListeners();

    try {
      final result = await _api.sendChatBatch(
        prompts: cleaned,
        repo: repo,
        branch: branch,
        mode: mode,
      );
      _queueTotal = (result['total'] as int?) ?? cleaned.length;
      // Don't reset position — polling already tracks it
      if (result['status'] == 'queued') {
        _queuePosition = 0;
        _batchPollFailures = 0;
        _loading = true;
        _loadingSince = DateTime.now();
        notifyListeners();
        _pollBatchProgress(repo: repo, branch: branch, mode: mode);
      }
    } catch (e) {
      _error = ApiService.friendlyError(e);
      _loading = false;
      _loadingSince = null;
      notifyListeners();
    }
  }

  Timer? _batchPollTimer;

  void _pollBatchProgress({required String repo, required String branch, required String mode}) {
    _batchPollTimer?.cancel();
    final _pollStarted = DateTime.now();
    _batchPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      // 30-minute max polling duration
      if (DateTime.now().difference(_pollStarted).inMinutes >= 30) {
        _batchPollTimer?.cancel();
        _loading = false;
        _loadingSince = null;
        _error = 'Polling timed out (30 min). Queue may still run on server.';
        notifyListeners();
        return;
      }
      try {
        final state = await _api.getChat();
        if (state == null) return;

        // Merge any new server messages into local messages
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        if (serverMsgs.isNotEmpty) {
          final merged = <ChatMessage>[];
          final seen = <String>{};
          for (final m in [...serverMsgs, ..._messages]) {
            final key = '${m.role}:${m.content}';
            if (seen.add(key)) merged.add(m);
          }
          _messages = merged;
          await _saveToCache();
        }

        // Update batch progress
        final batch = state['batch'] as Map<String, dynamic>?;
        if (batch != null) {
          _loading = batch['running'] == true;
          _queuePosition = (batch['position'] as int?) ?? 0;
          _queueTotal = (batch['total'] as int?) ?? 0;

          if (!_loading && _loadingSince != null) {
            _loadingSince = null;
            _batchPollTimer?.cancel();
          }
        }

        _batchPollFailures = 0;  // reset on every successful poll
        notifyListeners();
      } catch (_) {
        _batchPollFailures++;
        if (_batchPollFailures >= 10) {
          _error = 'Lost connection to server. Batch may still be running.';
          _loading = false;
          _loadingSince = null;
          _batchPollTimer?.cancel();
          notifyListeners();
        }
      }
    });
  }

  void cancelQueue() {
    _livePollTimer?.cancel();
    _batchPollTimer?.cancel();
    _api.cancelChatBatch(); // fire-and-forget
    _status = '';
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _livePollTimer?.cancel();
    _batchPollTimer?.cancel();
    super.dispose();
  }

  Future<void> clearChat() async {
    _livePollTimer?.cancel();
    _messages.clear();
    _error = null;
    _status = '';
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    notifyListeners();

    // Delete from server first, then clear local cache
    try {
      await _api.deleteChat();
    } catch (e) {
      debugPrint('ChatProvider.clearChat: server delete failed: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }

  Future<void> _saveToCache() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _messages.map((m) => m.toJson()).toList();
    await prefs.setString(_cacheKey, json.encode(list));
  }
}
