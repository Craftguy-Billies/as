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
  bool _disposed = false;
  String? _feedError;
  int _consecutiveFailures = 0;
  static const int _maxFailures = 5;

  TaskProvider(this._api, this._prefs);

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  List<Task> get tasks => _tasks;
  List<AgentEvent> get events => _events;
  bool get loading => _loading;
  String? get error => _error;
  String? get currentTaskId => _currentTaskId;
  bool get autoScroll => _autoScroll;
  String? get feedError => _feedError;

  set autoScroll(bool v) {
    _autoScroll = v;
    _safeNotify();
  }

  Future<void> loadTasks({String? statusFilter}) async {
    _loading = true;
    _error = null;

    try {
      _tasks = await _api.listTasks(status: statusFilter);
    } catch (e) {
      _error = _api.friendlyError(e);
    }

    _loading = false;
    _safeNotify();
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
      _safeNotify();
      return task;
    } catch (e) {
      _error = _api.friendlyError(e);
      _safeNotify();
      return null;
    }
  }

  Future<void> deleteTask(String id) async {
    try {
      await _api.deleteTask(id);
      _tasks.removeWhere((t) => t.id == id);
      _safeNotify();
    } catch (e) {
      _error = _api.friendlyError(e);
      _safeNotify();
    }
  }

  Future<void> retryTask(String id) async {
    try {
      await _api.retryTask(id);
      await loadTasks();
    } catch (e) {
      _error = _api.friendlyError(e);
      _safeNotify();
    }
  }

  Future<void> deleteAllTasks() async {
    try {
      await _api.deleteAllTasks();
      _tasks.clear();
      _safeNotify();
    } catch (e) {
      _error = _api.friendlyError(e);
      _safeNotify();
    }
  }

  // --- Live Feed ---

  void startPolling(String taskId) {
    if (_currentTaskId != taskId) {
      // New task — clear and track it
      _currentTaskId = taskId;
      _events = [];
      _feedError = null;
      _consecutiveFailures = 0;
      _autoScroll = true;
      _prefs.clearLastSeenTimestamp();
    }
    // Same task — resume polling, preserve existing events
    _startPollTimer();
    _fetchEvents(); // immediate first fetch
  }

  void _startPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _fetchEvents();
    });
  }

  void resumePolling() {
    // Called when phone reopens — catch up without wiping events
    if (_currentTaskId == null) return;
    _consecutiveFailures = 0;
    _feedError = null;
    _fetchEvents(); // catch up on missed events
    _startPollTimer();
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
        _safeNotify();
      }
    } catch (_) {}
  }

  void collapseEvents() {
    if (_events.length > 30) {
      _events = _events.sublist(_events.length - 30);
      _safeNotify();
    }
  }

  Future<void> _fetchEvents() async {
    if (_currentTaskId == null) return;
    final taskId = _currentTaskId!; // snapshot for this fetch cycle
    try {
      final lastTs = _prefs.lastSeenTimestamp;
      final data = await _api.getEvents(
        taskId,
        sinceTimestamp: lastTs,
        limit: 200,
      );
      // Guard: only apply if still polling the same task
      if (_currentTaskId != taskId) return;
      final newEvents = (data['events'] as List)
          .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      final taskStatus = data['task_status'] as String;

      _consecutiveFailures = 0;
      _feedError = null;

      if (newEvents.isNotEmpty) {
        _events = [..._events, ...newEvents];
        _prefs.setLastSeenTimestamp(newEvents.last.timestamp);
      }

      // Update inline task status so list tile reflects current state
      final taskIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (taskIdx != -1 && _tasks[taskIdx].status != taskStatus) {
        _tasks[taskIdx] = _tasks[taskIdx].copyWith(status: taskStatus);
      }

      if (taskStatus == 'completed' || taskStatus == 'failed') {
        stopPolling();
        await loadTasks();
      }

      _safeNotify();
    } catch (e) {
      // Guard: only apply if still polling the same task
      if (_currentTaskId != taskId) return;
      _consecutiveFailures++;
      _feedError = _api.friendlyError(e);
      _safeNotify();
      if (_consecutiveFailures >= _maxFailures) {
        stopPolling();
      }
    }
  }

}
