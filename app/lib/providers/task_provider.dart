import 'dart:async';
import 'package:flutter/material.dart';
import '../models/task.dart';
import '../models/event.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';

class TaskProvider extends ChangeNotifier {
  final ApiService _api;
  final PreferencesService _prefs;

  List<Task> _tasks = [];
  bool _loading = false;
  String? _error;

  // Live feed state
  List<AgentEvent> _events = [];
  String? _currentTaskId;
  Timer? _pollTimer;
  bool _autoScroll = true;

  TaskProvider(this._api, this._prefs);

  List<Task> get tasks => _tasks;
  List<AgentEvent> get events => _events;
  bool get loading => _loading;
  String? get error => _error;
  String? get currentTaskId => _currentTaskId;
  bool get autoScroll => _autoScroll;

  set autoScroll(bool v) {
    _autoScroll = v;
    notifyListeners();
  }

  Future<void> loadTasks({String? statusFilter}) async {
    _loading = true;
    _error = null;

    try {
      _tasks = await _api.listTasks(status: statusFilter);
    } catch (e) {
      _error = e.toString();
    }

    _loading = false;
    notifyListeners();
  }

  Future<Task?> createPrompt({
    required String prompt,
    required String repo,
    String branch = 'main',
    String mode = 'code',
  }) async {
    _error = null;
    try {
      final task = await _api.createPrompt(
        prompt: prompt,
        repo: repo,
        branch: branch,
        mode: mode,
      );
      _tasks.insert(0, task);
      notifyListeners();
      return task;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> deleteTask(String id) async {
    try {
      await _api.deleteTask(id);
      _tasks.removeWhere((t) => t.id == id);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // --- Live Feed ---

  void startPolling(String taskId) {
    _currentTaskId = taskId;
    _events = [];
    _autoScroll = true;
    _fetchEvents();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchEvents();
    });
    // notifyListeners() called by _fetchEvents() when data arrives
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void loadMoreEvents() async {
    if (_currentTaskId == null) return;
    try {
      final olderEvents = await _api.fetchEvents(
        _currentTaskId!,
        limit: 50,
        offset: _events.length,
      );
      if (olderEvents.isNotEmpty) {
        _events = [...olderEvents, ..._events];
        notifyListeners();
      }
    } catch (_) {}
  }

  void collapseEvents() {
    if (_events.length > 30) {
      _events = _events.sublist(_events.length - 30);
      notifyListeners();
    }
  }

  Future<void> _fetchEvents() async {
    if (_currentTaskId == null) return;
    try {
      final lastTs = _prefs.lastSeenTimestamp;
      final data = await _api.getEvents(
        _currentTaskId!,
        sinceTimestamp: lastTs,
        limit: 200,
      );
      final newEvents = (data['events'] as List)
          .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      final taskStatus = data['task_status'] as String;

      if (newEvents.isNotEmpty) {
        _events = [..._events, ...newEvents];
        // Update last seen timestamp
        _prefs.setLastSeenTimestamp(
          newEvents.last.timestamp,
        );
        notifyListeners();
      }

      // Check if task completed
      if (taskStatus == 'completed' || taskStatus == 'failed') {
        stopPolling();
        // Refresh task list
        await loadTasks();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
