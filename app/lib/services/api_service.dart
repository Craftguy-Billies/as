import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/task.dart';
import '../models/event.dart';

class ApiService {
  String? _baseUrl;

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  static const defaultUrl = 'http://34.44.82.227:8080';
  String get _url => _baseUrl ?? defaultUrl;

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
    throw Exception('Failed to create prompt: ${resp.statusCode} ${resp.body}');
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
    throw Exception('Failed to list tasks: ${resp.statusCode}');
  }

  Future<Task> getTask(String id) async {
    final resp = await http.get(Uri.parse('$_url/api/tasks/$id'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode == 200) {
      return Task.fromJson(json.decode(resp.body));
    }
    throw Exception('Task not found');
  }

  Future<void> deleteTask(String id) async {
    final resp = await http.delete(Uri.parse('$_url/api/tasks/$id'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Failed to delete task');
    }
  }

  Future<void> deleteAllTasks({String status = 'all'}) async {
    final resp = await http.delete(
      Uri.parse('$_url/api/tasks').replace(queryParameters: {'status': status}),
    ).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Failed to clear history');
    }
  }

  // --- Chat ---

  Future<Map<String, dynamic>> sendChatMessage(String prompt) async {
    final resp = await http
        .post(
          Uri.parse('$_url/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'prompt': prompt}),
        )
        .timeout(const Duration(seconds: 200));
    if (resp.statusCode != 200) {
      final detail = _tryParseError(resp.body);
      throw Exception(detail ?? 'Chat failed (${resp.statusCode})');
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getChat() async {
    final resp = await http
        .get(Uri.parse('$_url/api/chat'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Failed to load chat history');
    }
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<void> deleteChat() async {
    final resp = await http
        .delete(Uri.parse('$_url/api/chat'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw Exception('Failed to clear chat: ${resp.statusCode}');
    }
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
    throw Exception('Failed to get events: ${resp.statusCode}');
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
      throw Exception('Failed to register push token: ${resp.statusCode}');
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
      throw Exception('Failed to update LLM config: ${resp.statusCode}');
    }
  }

  Future<Map<String, dynamic>?> getLlmConfig() async {
    try {
      final resp = await http.get(Uri.parse('$_url/api/config/llm'));
      if (resp.statusCode == 200) return json.decode(resp.body);
    } catch (_) {}
    return null;
  }
}
