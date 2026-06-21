import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/task.dart';
import '../models/event.dart';
import 'preferences_service.dart';

class ApiService {
  String? _baseUrl;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  static const defaultUrl = PreferencesService.defaultUrl;
  String get _url => _baseUrl ?? defaultUrl;

  /// Wrap network errors in user-friendly messages
  static String friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socketexception') || s.contains('connection refused') || s.contains('connection abort')) {
      return 'Cannot reach server. Check your internet connection and server URL.';
    }
    if (s.contains('timeout') || s.contains('timed out')) {
      return 'Request timed out. The server may be overloaded — try again.';
    }
    if (s.contains('handshake') || s.contains('certificate') || s.contains('tls')) {
      return 'Secure connection failed. Check your server URL (use http:// for local servers).';
    }
    final msg = e.toString();
    // Trim to first line and remove 'Exception: ' prefix
    final clean = msg.split('\n').first.replaceAll(RegExp(r'^(Exception|Error):\s*'), '');
    return clean.isEmpty ? 'Something went wrong. Please try again.' : clean;
  }

  Future<bool> testConnection() async {
    try {
      final resp = await http
          .get(Uri.parse('$_url/api/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> health() async {
    try {
      final resp = await http
          .get(Uri.parse('$_url/api/health'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) return json.decode(resp.body);
    } catch (_) {}
    return null;
  }

  Future<Task> createPrompt({
    required String prompt,
    required String repo,
    String branch = 'main',
    String mode = 'code',
  }) async {
    final resp = await http.post(
      Uri.parse('$_url/api/prompts'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'prompt': prompt,
        'repo': repo,
        'branch': branch,
        'mode': mode,
      }),
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 201) {
      return Task.fromJson(json.decode(resp.body));
    }
    throw Exception(_parseError(resp.statusCode, resp.body));
  }

  Future<List<Task>> listTasks({String? status, int limit = 50}) async {
    final params = <String, String>{'limit': limit.toString()};
    if (status != null) params['status'] = status;
    final uri = Uri.parse('$_url/api/tasks').replace(queryParameters: params);
    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body);
      return (data['tasks'] as List)
          .map((t) => Task.fromJson(t as Map<String, dynamic>))
          .toList();
    }
    throw Exception(_parseError(resp.statusCode, resp.body));
  }

  Future<Task> getTask(String id) async {
    final resp = await http.get(Uri.parse('$_url/api/tasks/$id'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode == 200) {
      return Task.fromJson(json.decode(resp.body));
    }
    throw Exception(_parseError(resp.statusCode, resp.body));
  }

  Future<void> deleteTask(String id) async {
    final resp = await http.delete(Uri.parse('$_url/api/tasks/$id'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  Future<void> retryTask(String id) async {
    final resp = await http.post(Uri.parse('$_url/api/tasks/$id/retry'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  Future<void> deleteAllTasks({String status = 'all'}) async {
    final resp = await http.delete(
      Uri.parse('$_url/api/tasks').replace(queryParameters: {'status': status}),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  // --- Chat ---

  Future<Map<String, dynamic>> sendChatMessage(
    String prompt, {
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_url/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'prompt': prompt,
            'repo': repo,
            'branch': branch,
            'mode': mode,
          }),
        )
        .timeout(const Duration(seconds: 310));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  /// Send all prompts at once — backend queues them, processes in background.
  /// Returns immediately. Poll getChat() to track progress and new messages.
  Future<Map<String, dynamic>> sendChatBatch({
    required List<String> prompts,
    String repo = '',
    String branch = 'main',
    String mode = 'code',
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_url/api/chat/batch'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'prompts': prompts,
            'repo': repo,
            'branch': branch,
            'mode': mode,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<bool> cancelChatBatch() async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_url/api/chat/batch/cancel'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> getChat({String repo = '', String mode = ''}) async {
    final uri = repo.isNotEmpty
        ? Uri.parse('$_url/api/chat?repo=${Uri.encodeComponent(repo)}&mode=${Uri.encodeComponent(mode)}')
        : Uri.parse('$_url/api/chat');
    final resp = await http
        .get(uri)
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getChatRepos() async {
    final resp = await http
        .get(Uri.parse('$_url/api/chat/repos'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
    final data = json.decode(resp.body) as Map<String, dynamic>;
    return (data['repos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<void> deleteChat() async {
    final resp = await http
        .delete(Uri.parse('$_url/api/chat'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  /// Extract a human-readable error from an API response body.
  /// FastAPI returns {"detail": "..."} for validation/HTTP errors.
  String _parseError(int statusCode, String body) {
    try {
      final d = json.decode(body) as Map<String, dynamic>;
      final detail = d['detail']?.toString();
      if (detail != null && detail.isNotEmpty) return detail;
    } catch (_) {}
    // Fallback: return first 200 chars of body, or just the status code
    final clean = body.trim();
    if (clean.isNotEmpty && clean.length <= 200) return '$statusCode: $clean';
    if (clean.isNotEmpty) return '$statusCode: ${clean.substring(0, 200)}...';
    return 'HTTP $statusCode';
  }

  String? _tryParseError(String body) {
    try {
      final d = json.decode(body) as Map<String, dynamic>;
      return d['detail']?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> getEvents(
    String taskId, {
    String? sinceTimestamp,
    int limit = 50,
    int offset = 0,
  }) async {
    final params = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (sinceTimestamp != null) params['since_timestamp'] = sinceTimestamp;
    final uri =
        Uri.parse('$_url/api/tasks/$taskId/events').replace(queryParameters: params);
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 200) {
      return json.decode(resp.body) as Map<String, dynamic>;
    }
    throw Exception(_parseError(resp.statusCode, resp.body));
  }

  Future<List<AgentEvent>> fetchEvents(
    String taskId, {
    String? sinceTimestamp,
    int limit = 50,
    int offset = 0,
  }) async {
    final data = await getEvents(
      taskId,
      sinceTimestamp: sinceTimestamp,
      limit: limit,
      offset: offset,
    );
    return (data['events'] as List)
        .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> registerFcmToken(String token) async {
    final resp = await http.post(
      Uri.parse('$_url/api/fcm-token'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'token': token}),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  Future<void> updateLlmConfig({
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    final resp = await http.put(
      Uri.parse('$_url/api/config/llm'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'api_key': apiKey,
        'model': model,
        'base_url': baseUrl,
      }),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  Future<Map<String, dynamic>?> getLlmConfig() async {
    try {
      final resp = await http.get(Uri.parse('$_url/api/config/llm'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) return json.decode(resp.body);
    } catch (_) {}
    return null;
  }

  Future<void> updateGitConfig({
    required String name,
    required String email,
  }) async {
    final resp = await http.put(
      Uri.parse('$_url/api/config/git'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': name, 'email': email}),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.statusCode, resp.body));
    }
  }

  Future<Map<String, dynamic>?> getGitConfig() async {
    try {
      final resp = await http.get(Uri.parse('$_url/api/config/git'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) return json.decode(resp.body);
    } catch (_) {}
    return null;
  }
}
