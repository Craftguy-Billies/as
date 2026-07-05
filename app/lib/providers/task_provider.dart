import 'dart:async';
import 'package:flutter/material.dart';
import '../models/task.dart';
import '../models/event.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';
import '../services/notification_service.dart';

/// Callback when a task transitions to completed/failed during polling.
typedef TaskStatusCallback = void Function(String taskId, String status, String prompt);

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
  bool _hasMoreEvents = false;

  /// Called when a task becomes completed or failed during polling.
  TaskStatusCallback? onTaskCompleted;

  // Keep track of tasks we already notified about
  final Set<String> _notifiedTasks = {};

  TaskProvider(this._api, this._prefs);

  void setNotificationService(NotificationService ns) {
    _notificationService = ns;
  }

  List<Task> get tasks => _tasks;
  List<AgentEvent> get events => _events;
  bool get loading => _loading;
  bool get refreshing => _refreshing;
  String? get error => _error;
  String? get currentTaskId => _currentTaskId;
  bool get autoScroll => _autoScroll;
  bool get hasMoreEvents => _hasMoreEvents;

  set autoScroll(bool v) {
    _autoScroll = v;
    notifyListeners();
  }

  /// Full load with loading spinner.
  Future<void> loadTasks({String? statusFilter}) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      debugPrint('[TASK_PROV] loadTasks() fetching tasks...');
      _tasks = await _api.listTasks(status: statusFilter);
      debugPrint('[TASK_PROV] loadTasks() got ${_tasks.length} tasks');
      checkCompletedTasks();
    } catch (e) {
      debugPrint('[TASK_PROV] loadTasks() ERROR: $e');
      _error = e.toString();
    }

    _loading = false;
    notifyListeners();
  }

  /// Background refresh without showing full-screen spinner.
  Future<void> refreshTasks() async {
    _refreshing = true;
    _error = null;
    notifyListeners();

    try {
      debugPrint('[TASK_PROV] refreshTasks() fetching tasks...');
      _tasks = await _api.listTasks();
      debugPrint('[TASK_PROV] refreshTasks() got ${_tasks.length} tasks');
      checkCompletedTasks();
    } catch (e) {
      debugPrint('[TASK_PROV] refreshTasks() ERROR: $e');
      _error = e.toString();
    }

    _refreshing = false;
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

  /// Check all loaded tasks for completion and show local notifications
  /// for any that haven't been notified yet.
  void checkCompletedTasks() {
    for (final task in _tasks) {
      if (task.isCompleted && !_notifiedTasks.contains(task.id)) {
        debugPrint('[TASK_PROV] checkCompletedTasks() completed: ${task.id} "${task.prompt.substring(0, task.prompt.length.clamp(0, 40))}"');
        _notifiedTasks.add(task.id);
        final promptPreview =
            task.prompt.length > 80
                ? '${task.prompt.substring(0, 80)}...'
                : task.prompt;
        _notificationService?.showTaskCompleteNotification(
          taskId: task.id,
          title: '✅ Task Complete',
          body: promptPreview,
        );
      }
      if (task.isFailed && !_notifiedTasks.contains(task.id)) {
        debugPrint('[TASK_PROV] checkCompletedTasks() failed: ${task.id} "${task.errorMessage ?? "no error msg"}"');
        _notifiedTasks.add(task.id);
        _notificationService?.showTaskCompleteNotification(
          taskId: task.id,
          title: '❌ Task Failed',
          body: task.errorMessage ?? 'Task failed',
        );
      }
    }
  }

  /// Process any pending replies from notification actions and send them
  /// to the backend.
  Future<void> processPendingReplies() async {
    final ns = _notificationService;
    if (ns == null) return;
    final replies = await ns.getPendingReplies();
    for (final reply in replies) {
      final taskId = reply['taskId'] ?? '';
      final message = reply['message'] ?? '';
      if (taskId.isNotEmpty && message.isNotEmpty) {
        await _api.sendReply(taskId, message);
      }
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
    notifyListeners();
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

  /// Fire a local notification for a completed/failed task.
  /// Uses task data from the in-memory _tasks list (not dependent on API).
  void _notifyTaskCompletion(String taskId, String status) {
    if (_notifiedTasks.contains(taskId)) {
      debugPrint('[TASK_PROV] _notifyTaskCompletion() SKIP: already notified task=$taskId');
      return;
    }
    if (_notificationService == null) {
      debugPrint('[TASK_PROV] _notifyTaskCompletion() SKIP: notificationService is null!');
      return;
    }

    final task = _tasks.where((t) => t.id == taskId).firstOrNull;
    final prompt = task?.prompt ?? 'Task';
    final promptPreview =
        prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt;

    _notifiedTasks.add(taskId);

    if (status == 'completed') {
      debugPrint('[TASK_PROV] _notifyTaskCompletion() FIRING ✅ notification for task=$taskId prompt="$promptPreview"');
      _notificationService!.showTaskCompleteNotification(
        taskId: taskId,
        title: '✅ Task Complete',
        body: promptPreview,
      );
    } else if (status == 'failed') {
      final errMsg = task?.errorMessage ?? 'Task failed';
      debugPrint('[TASK_PROV] _notifyTaskCompletion() FIRING ❌ notification for task=$taskId error="$errMsg"');
      _notificationService!.showTaskCompleteNotification(
        taskId: taskId,
        title: '❌ Task Failed',
        body: errMsg,
      );
    } else {
      debugPrint('[TASK_PROV] _notifyTaskCompletion() SKIP: unknown status=$status');
    }
  }

  Future<void> _fetchEvents() async {
    if (_currentTaskId == null) return;
    try {
      final lastTs = _prefs.lastSeenTimestamp;
      debugPrint('[TASK_PROV] _fetchEvents() polling task=$_currentTaskId since=$lastTs');
      final data = await _api.getEvents(
        _currentTaskId!,
        sinceTimestamp: lastTs,
        limit: 200,
      );
      final newEvents = (data['events'] as List)
          .map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      final taskStatus = data['task_status'] as String?;
      _hasMoreEvents = data['has_more'] == true;

      debugPrint('[TASK_PROV] _fetchEvents() got ${newEvents.length} events, task_status=$taskStatus');

      if (newEvents.isNotEmpty) {
        _events = [..._events, ...newEvents];
        // Update last seen timestamp
        _prefs.setLastSeenTimestamp(
          newEvents.last.timestamp,
        );
        notifyListeners();
      }

      // Check if task completed — fire notification DIRECTLY from events API
      // data, NOT dependent on loadTasks() succeeding.
      if (taskStatus == 'completed' || taskStatus == 'failed') {
        debugPrint('[TASK_PROV] _fetchEvents() task $taskStatus DETECTED!');
        // Fire notification immediately using in-memory task data
        // taskStatus is non-null here (checked against two string literals above)
        _notifyTaskCompletion(_currentTaskId!, taskStatus!);

        // Notify listener callback if registered
        if (onTaskCompleted != null) {
          final task = _tasks.where((t) => t.id == _currentTaskId).firstOrNull;
          onTaskCompleted!(
            _currentTaskId!,
            taskStatus!,
            task?.prompt ?? 'Task',
          );
        }

        // Stop polling AFTER notification is fired, so if loadTasks() fails,
        // the notification is still shown.
        stopPolling();
        debugPrint('[TASK_PROV] _fetchEvents() polling stopped, refreshing task list...');
        // Refresh task list (best-effort UI update)
        await loadTasks();
      } else if (taskStatus == null) {
        debugPrint('[TASK_PROV] _fetchEvents() task_status is null (task still running or no status yet)');
      } else {
        debugPrint('[TASK_PROV] _fetchEvents() task still $taskStatus, continuing poll');
      }
    } catch (e) {
      debugPrint('[TASK_PROV] _fetchEvents() ERROR: $e');
    }
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
