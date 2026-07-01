import 'dart:async';
import 'package:flutter/material.dart';
import '../models/task.dart';
import '../models/event.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';
import '../services/notification_service.dart';

class TaskProvider extends ChangeNotifier {
  final ApiService _api;
  final PreferencesService _prefs;
  NotificationService? _notificationService;

  List<Task> _tasks = [];
  bool _loading = false;
  bool _refreshing = false;
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

  // De-duplicate notifications for the same task
  final Set<String> _notifiedTasks = {};

  TaskProvider(this._api, this._prefs);

  void setNotificationService(NotificationService ns) {
    _notificationService = ns;
  }

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
  bool get refreshing => _refreshing;
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
      _error = ApiService.friendlyError(e);
    }

    _loading = false;
    _safeNotify();
  }

  /// Pull-to-refresh: same as loadTasks but uses _refreshing flag
  /// so the UI doesn't replace the list with a full-screen spinner.
  Future<void> refreshTasks() async {
    _refreshing = true;
    _error = null;
    _safeNotify();

    try {
      _tasks = await _api.listTasks();
      // Check for already-completed tasks and notify if new
      for (final task in _tasks) {
        if ((task.isCompleted || task.isFailed) && !_notifiedTasks.contains(task.id)) {
          _notifiedTasks.add(task.id);
          _fireNotificationForTask(task);
        }
      }
    } catch (e) {
      _error = ApiService.friendlyError(e);
    }

    _refreshing = false;
    _safeNotify();
  }

  Future<Task?> createPrompt({
    required String prompt,
    required String repo,
    String branch = '',
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
      _error = ApiService.friendlyError(e);
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
      _error = ApiService.friendlyError(e);
      _safeNotify();
    }
  }

  Future<void> retryTask(String id) async {
    try {
      await _api.retryTask(id);
      await loadTasks();
    } catch (e) {
      _error = ApiService.friendlyError(e);
      _safeNotify();
    }
  }

  Future<void> deleteAllTasks() async {
    try {
      await _api.deleteAllTasks();
      _tasks.clear();
      _notifiedTasks.clear();
      _safeNotify();
    } catch (e) {
      _error = ApiService.friendlyError(e);
      _safeNotify();
    }
  }

  void _fireNotificationForTask(Task task) {
    final ns = _notificationService;
    if (ns == null) {
      debugPrint('[TASK_PROV] No notification service wired');
      return;
    }
    final isComplete = task.isCompleted || task.status == 'completed';
    final title = isComplete ? '✅ Task Complete' : '❌ Task Failed';
    final body = isComplete
        ? task.prompt.length > 80
            ? '${task.prompt.substring(0, 80)}...'
            : task.prompt
        : task.errorMessage ?? 'Task failed';
    debugPrint('[TASK_PROV] Firing notification for task ${task.id}: $title');
    ns.showTaskCompleteNotification(taskId: task.id, title: title, body: body);
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
        // Fire notification BEFORE loadTasks — only once per task
        if (!_notifiedTasks.contains(taskId)) {
          _notifiedTasks.add(taskId);
          final task = _tasks.where((t) => t.id == taskId).firstOrNull;
          if (task != null) {
            final updatedTask = task.copyWith(status: taskStatus);
            _fireNotificationForTask(updatedTask);
          }
        }
        stopPolling();
        await loadTasks();
      }

      _safeNotify();
    } catch (e) {
      // Guard: only apply if still polling the same task
      if (_currentTaskId != taskId) return;
      _consecutiveFailures++;
      _feedError = ApiService.friendlyError(e);
      _safeNotify();
      if (_consecutiveFailures >= _maxFailures) {
        stopPolling();
      }
    }
  }

}
