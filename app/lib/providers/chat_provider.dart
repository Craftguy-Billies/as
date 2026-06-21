import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class ChatMessage {
  final String role; // "user" | "assistant" | "event"
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

/// Single-mode chat: everything goes through the server-side batch queue.
/// Send → enqueue on server → poll for live events + progress.
/// Survives phone close — reconnects and resumes polling.
class ChatProvider extends ChangeNotifier {
  static const _cacheKey = 'chat_messages';

  final ApiService _api;
  List<ChatMessage> _messages = [];
  bool _loading = false;
  String? _error;
  DateTime? _loadingSince;

  // Queue progress (updated from server every poll)
  int _queuePosition = 0;
  int _queueTotal = 0;
  int _pollFailures = 0;
  Timer? _pollTimer;

  ChatProvider(this._api);

  // -- Getters --
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get loading => _loading;
  String? get error => _error;
  int get queuePosition => _queuePosition;
  int get queueTotal => _queueTotal;
  bool get isProcessing => _queueTotal > 0;
  String serverRepo = '';
  String serverMode = 'code';

  // -- Init: restore from cache + server, resume batch if running --
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

    // Merge server messages (survives server restart)
    try {
      final data = await _api.getChat();
      final serverMsgs = (data['messages'] as List?)
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
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ChatProvider.loadFromCache: server merge failed: $e');
    }

    // Resume polling if a batch is running on the server
    try {
      final state = await _api.getChat();
      final batch = state?['batch'] as Map<String, dynamic>?;
      final isRunning = batch?['running'] == true;
      final total = (batch?['total'] as int?) ?? 0;
      debugPrint('ChatProvider.loadFromCache: batch running=$isRunning total=$total pos=${batch?['position']}');
      if (isRunning && total > 0) {
        _queuePosition = (batch?['position'] as int?) ?? 0;
        _queueTotal = total;
        _loading = true;
        _loadingSince = DateTime.now();
        notifyListeners();
        _startPolling(repo: state?['repo']?.toString() ?? '',
                      branch: 'main',
                      mode: state?['mode']?.toString() ?? 'code');
      }
    } catch (e) {
      debugPrint('ChatProvider.loadFromCache: batch resume failed: $e');
    }
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

    debugPrint('ChatProvider.send: START repo=$repo mode=$mode');
    _error = null;

    // Add user message to chat immediately
    final userMsg = ChatMessage(
      role: 'user',
      content: trimmed,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _messages.add(userMsg);
    await _saveToCache();
    notifyListeners();

    try {
      final result = await _api.sendChatBatch(
        prompts: [trimmed],
        repo: repo,
        branch: branch,
        mode: mode,
      );
      debugPrint('ChatProvider.send: result=$result');

      if (result['status'] == 'queued') {
        _queuePosition = (result['position'] as int?) ?? 0;
        _queueTotal = (result['total'] as int?) ?? 1;
        _pollFailures = 0;
        _loading = true;
        _loadingSince = DateTime.now();
        debugPrint('ChatProvider.send: queued pos=$_queuePosition total=$_queueTotal — polling');
        notifyListeners();
        _startPolling(repo: repo, branch: branch, mode: mode);
      } else {
        debugPrint('ChatProvider.send: unexpected status=${result['status']}');
        _error = (result['error']?.toString()) ?? 'Server did not accept the request';
        _queueTotal = 0;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('ChatProvider.send: ERROR ${ApiService.friendlyError(e)}');
      _error = ApiService.friendlyError(e);
      _queueTotal = 0;
      notifyListeners();
    }
  }

  // -- Polling: fetch messages + progress every 2 seconds --
  void _startPolling({required String repo, required String branch, required String mode}) {
    _pollTimer?.cancel();
    final pollStarted = DateTime.now();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (DateTime.now().difference(pollStarted).inMinutes >= 30) {
        _pollTimer?.cancel();
        _loading = false;
        _loadingSince = null;
        _error = 'Polling timed out (30 min). Queue may still run on server.';
        debugPrint('ChatProvider.poll: TIMEOUT');
        notifyListeners();
        return;
      }
      try {
        final state = await _api.getChat();
        if (state == null) return;
        _error = null;  // clear error on any successful poll

        // Merge server messages (events, responses) into local chat
        final serverMsgs = (state['messages'] as List?)
                ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        debugPrint('ChatProvider.poll: serverMsgs=${serverMsgs.length} localMsgs=${_messages.length}');
        if (serverMsgs.isNotEmpty) {
          final merged = <ChatMessage>[];
          final seen = <String>{};
          for (final m in [...serverMsgs, ..._messages]) {
            final key = '${m.role}:${m.content}';
            if (seen.add(key)) merged.add(m);
          }
          if (merged.length != _messages.length) {
            debugPrint('ChatProvider.poll: merged ${_messages.length}→${merged.length} messages');
            _messages = merged;
            _error = null;  // clear error when server responds successfully
            await _saveToCache();
          }
        }

        // Update progress from server
        final batch = state['batch'] as Map<String, dynamic>?;
        if (batch != null) {
          final wasLoading = _loading;
          debugPrint('ChatProvider.poll: batch running=${batch['running']} pos=${batch['position']} total=${batch['total']} wasLoading=$wasLoading');
          _loading = batch['running'] == true;
          _queuePosition = (batch['position'] as int?) ?? _queuePosition;
          _queueTotal = (batch['total'] as int?) ?? _queueTotal;

          if (wasLoading && !_loading) {
            _loadingSince = null;
            _pollTimer?.cancel();
            _queuePosition = 0;
            _queueTotal = 0;  // hide progress bar
            debugPrint('ChatProvider.poll: DONE pos=$_queuePosition total=$_queueTotal');
          }
        }

        _pollFailures = 0;
        notifyListeners();
      } catch (e) {
        debugPrint('ChatProvider.poll: fail #$_pollFailures: $e');
        _pollFailures++;
        if (_pollFailures >= 10) {
          _error = 'Lost connection to server. Queue may still be running.';
          _loading = false;
          _loadingSince = null;
          _pollTimer?.cancel();
          notifyListeners();
        }
      }
    });
  }

  // -- Cancel / Clear --
  void cancel() {
    _pollTimer?.cancel();
    _api.cancelChatBatch();
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    debugPrint('ChatProvider.cancel');
    notifyListeners();
  }

  Future<void> clearChat() async {
    _pollTimer?.cancel();
    _messages.clear();
    _error = null;
    _loading = false;
    _loadingSince = null;
    _queuePosition = 0;
    _queueTotal = 0;
    notifyListeners();

    try {
      await _api.deleteChat();
    } catch (e) {
      debugPrint('ChatProvider.clearChat: $e');
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, json.encode(_messages.map((m) => m.toJson()).toList()));
  }
}
