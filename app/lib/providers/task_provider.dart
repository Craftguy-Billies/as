import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  // Track tasks already notified via local notification (prevents duplicates)
  final Set<String> _notifiedTasks = {};

  TaskProvider(this._api, this._prefs);

  void setNotificationService(NotificationService ns) {
    _notificationService = ns;
    debugPrint('[TASK_PROV] NotificationService wired');
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
    debugPrint('[TASK_PROV] loadTasks() statusFilter=$statusFilter');
    _loading = true;
    _error = null;
    _safeNotify();

    try {
      _tasks = await _api.listTasks(status: statusFilter);
      debugPrint('[TASK_PROV] loadTasks() got ${_tasks.length} tasks');
      _checkCompletedTasks();
    } catch (e) {
      debugPrint('[TASK_PROV] loadTasks() ERROR: $e');
      _error = ApiService.friendlyError(e);
    }

    _loading = false;
    _safeNotify();
  }

  /// Background refresh without showing full-screen spinner.
  Future<void> refreshTasks() async {
    debugPrint('[TASK_PROV] refreshTasks()');
    _refreshing = true;
    _error = null;
    _safeNotify();

    try {
      _tasks = await _api.listTasks();
      debugPrint('[TASK_PROV] refreshTasks() got ${_tasks.length} tasks');
      _checkCompletedTasks();
    } catch (e) {
      debugPrint('[TASK_PROV] refreshTasks() ERROR: $e');
      _error = ApiService.friendlyError(e);
    }

    _refreshing = false;
    _safeNotify();
  }

  /// Fire local notifications for any completed/failed tasks not yet notified.
  void _checkCompletedTasks() {
    debugPrint('[TASK_PROV] _checkCompletedTasks() checking ${_tasks.length} tasks');
    final newlyNotified = <String>[];
    for (final task in _tasks) {
      if (task.isCompleted && !_notifiedTasks.contains(task.id)) {
        debugPrint('[TASK_PROV] Found completed (unnotified): ${task.id}');
        _notifiedTasks.add(task.id);
        newlyNotified.add(task.id);
        final preview = task.prompt.length > 80
            ? '${task.prompt.substring(0, 80)}...'
            : task.prompt;
        _notificationService?.showTaskCompleteNotification(
          taskId: task.id,
          title: '✅ Task Complete',
          body: preview,
        );
      }
      if (task.isFailed && !_notifiedTasks.contains(task.id)) {
        debugPrint('[TASK_PROV] Found failed (unnotified): ${task.id}');
        _notifiedTasks.add(task.id);
        newlyNotified.add(task.id);
        _notificationService?.showTaskCompleteNotification(
          taskId: task.id,
          title: '❌ Task Failed',
          body: task.errorMessage ?? 'Task failed',
        );
      }
    }
    // Sync to SharedPreferences so background WorkManager doesn't re-notify
    if (newlyNotified.isNotEmpty) {
      _persistNotifiedBgIds(newlyNotified);
    }
    debugPrint('[TASK_PROV] _checkCompletedTasks() done, _notifiedTasks=${_notifiedTasks.length}');
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
      _safeNotify();
    } catch (e) {
      _error = ApiService.friendlyError(e);
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

  /// Fire a local notification directly from events API data.
  /// Called BEFORE stopPolling() so retries work on failure.
  /// Called BEFORE loadTasks() so it works even if the list reload fails.
  void _notifyTaskCompletion(String taskId, String status) {
    if (_notifiedTasks.contains(taskId)) {
      debugPrint('[TASK_PROV] _notifyTaskCompletion($taskId) already notified, skip');
      return;
    }
    if (_notificationService == null) {
      debugPrint('[TASK_PROV] _notifyTaskCompletion($taskId) no service, skip');
      return;
    }

    final task = _tasks.where((t) => t.id == taskId).firstOrNull;
    final prompt = task?.prompt ?? 'Task';
    final preview = prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt;

    _notifiedTasks.add(taskId);
    debugPrint('[TASK_PROV] _notifyTaskCompletion($taskId) status=$status');

    _notificationService!.showTaskCompleteNotification(
      taskId: taskId,
      title: status == 'completed' ? '✅ Task Complete' : '❌ Task Failed',
      body: status == 'failed' ? (task?.errorMessage ?? 'Task failed') : preview,
    );

    // Sync to SharedPreferences so background WorkManager doesn't re-notify
    _persistNotifiedBgIds([taskId]);
  }

  /// Write notified task IDs to SharedPreferences so background WorkManager
  /// (which uses its own dedup set) doesn't re-notify the same tasks.
  void _persistNotifiedBgIds(List<String> ids) {
    SharedPreferences.getInstance().then((prefs) {
      final existing = prefs.getStringList('bg_notified_tasks') ?? [];
      final updated = {...existing, ...ids}.toList();
      prefs.setStringList('bg_notified_tasks', updated);
      debugPrint('[TASK_PROV] Synced ${ids.length} IDs to bg_notified_tasks (total=${updated.length})');
    });
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
        debugPrint('[TASK_PROV] _fetchEvents($taskId) ${newEvents.length} events, status=$taskStatus');
      }

      // Update inline task status so list tile reflects current state
      final taskIdx = _tasks.indexWhere((t) => t.id == taskId);
      if (taskIdx != -1 && _tasks[taskIdx].status != taskStatus) {
        debugPrint('[TASK_PROV] _fetchEvents($taskId) status: ${_tasks[taskIdx].status} -> $taskStatus');
        _tasks[taskIdx] = _tasks[taskIdx].copyWith(status: taskStatus);
      }

      if (taskStatus == 'completed' || taskStatus == 'failed') {
        debugPrint('[TASK_PROV] _fetchEvents($taskId) DETECTED $taskStatus');
        // Fire notification DIRECTLY from events API — NOT dependent on loadTasks()
        _notifyTaskCompletion(taskId, taskStatus);
        // Stop polling AFTER notification fires, so retry works on failure
        stopPolling();
        // Best-effort refresh of task list (may fail, notification already fired)
        await loadTasks();
      }

      _safeNotify();
    } catch (e) {
      // Guard: only apply if still polling the same task
      if (_currentTaskId != taskId) return;
      _consecutiveFailures++;
      _feedError = ApiService.friendlyError(e);
      debugPrint('[TASK_PROV] _fetchEvents($taskId) ERROR (attempt $_consecutiveFailures/$_maxFailures): $e');
      _safeNotify();
      if (_consecutiveFailures >= _maxFailures) {
        debugPrint('[TASK_PROV] _fetchEvents($taskId) MAX FAILURES, stopping');
        stopPolling();
      }
    }
  }

}
