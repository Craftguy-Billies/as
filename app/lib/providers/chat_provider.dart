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

  ChatProvider(this._api);

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get loading => _loading;
  String? get error => _error;

  Future<void> loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        final list = json.decode(raw) as List;
        _messages = list
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      } catch (_) {
        await prefs.remove(_cacheKey);
      }
    }
    // Also try loading from server (restores session if backend still has it)
    try {
      final data = await _api.getChat();
      final serverMsgs = (data['messages'] as List?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (serverMsgs.isNotEmpty) {
        // Merge: server messages + cache messages, deduplicated
        final merged = <ChatMessage>[];
        final seen = <String>{};
        for (final m in [...serverMsgs, ..._messages]) {
          final key = '${m.role}:${m.content}:${m.timestamp}';
          if (seen.add(key)) merged.add(m);
        }
        _messages = merged;
        await _saveToCache();
        notifyListeners();
      }
    } catch (_) {}

    // Safety: clear stuck loading from a previous crash
    if (_loading && _loadingSince != null &&
        DateTime.now().difference(_loadingSince!) > const Duration(seconds: 210)) {
      _loading = false;
      _loadingSince = null;
    }
  }

  Future<void> sendMessage(
    String prompt, {
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    if (prompt.trim().isEmpty || _loading) return;

    _loading = true;
    _loadingSince = DateTime.now();
    _error = null;

    final userMsg = ChatMessage(
      role: 'user',
      content: prompt.trim(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _messages.add(userMsg);
    await _saveToCache(); // persist user message immediately (survives crash)
    notifyListeners();

    try {
      final data = await _api.sendChatMessage(
        prompt.trim(),
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
      await _saveToCache(); // persist full conversation after success
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      _loadingSince = null;
      notifyListeners();
    }
  }

  Future<void> clearChat() async {
    _messages.clear();
    _error = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    notifyListeners();

    try {
      await _api.deleteChat();
    } catch (_) {}
  }

  Future<void> _saveToCache() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _messages.map((m) => m.toJson()).toList();
    await prefs.setString(_cacheKey, json.encode(list));
  }
}
