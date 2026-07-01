import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as ln;
import 'package:workmanager/workmanager.dart';

/// Background service for periodic task status polling.
///
/// Runs via WorkManager in a background isolate. Polls GET /api/tasks
/// (read-only, zero KV writes) and fires local notifications when
/// tasks complete or fail.
///
/// The callback is a top-level function annotated with @pragma('vm:entry-point')
/// so Flutter's isolate can invoke it.

const String _backgroundTaskName = 'bgTaskRefresh';
const String _channelId = 'vibecode_tasks';
const String _channelName = 'Task Notifications';
const String _channelDesc = 'Notifications when AI tasks complete';
const String _prefsNotifiedKey = 'bg_notified_tasks';
const String _prefsServerUrlKey = 'server_url';

/// Initialize WorkManager and register the periodic background task.
/// Call this from main() after WidgetsFlutterBinding.ensureInitialized().
Future<void> initBackgroundService() async {
  await Workmanager().initialize(_callbackDispatcher, isInDebugMode: true);
  await Workmanager().registerPeriodicTask(
    'vibecode-bg-refresh',
    _backgroundTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
  debugPrint('[BG_SVC] WorkManager initialized, periodic task registered (15 min)');
}

/// Cancel all background tasks.
Future<void> cancelBackgroundService() async {
  await Workmanager().cancelAll();
  debugPrint('[BG_SVC] All background tasks cancelled');
}

/// Top-level callback dispatcher required by WorkManager.
/// Must be a top-level or static function with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    debugPrint('[BG_SVC] Background task started: $taskName');
    if (taskName == _backgroundTaskName) {
      try {
        await _checkTasksAndNotify();
        debugPrint('[BG_SVC] Background task completed successfully');
        return true;
      } catch (e) {
        debugPrint('[BG_SVC] Background task failed: $e');
        return false;
      }
    }
    return true;
  });
}

/// Core background logic: fetch tasks, check for completions, notify.
Future<void> _checkTasksAndNotify() async {
  // Get server URL from SharedPreferences
  final prefs = await SharedPreferences.getInstance();
  final serverUrl = prefs.getString(_prefsServerUrlKey);
  if (serverUrl == null || serverUrl.isEmpty) {
    debugPrint('[BG_SVC] No server URL configured, skipping');
    return;
  }

  debugPrint('[BG_SVC] Using server URL: $serverUrl');

  // Initialize local notifications
  final localNotif = ln.FlutterLocalNotificationsPlugin();
  const androidSettings = ln.AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = ln.InitializationSettings(android: androidSettings);
  await localNotif.initialize(settings: initSettings);

  // Create notification channel (no-op if already exists)
  await localNotif
      .resolvePlatformSpecificImplementation<
          ln.AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const ln.AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: ln.Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );

  // Request POST_NOTIFICATIONS permission (Android 13+)
  await localNotif
      .resolvePlatformSpecificImplementation<
          ln.AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  // Fetch task list (read-only, zero KV writes)
  final tasksUrl = Uri.parse('$serverUrl/api/tasks');
  debugPrint('[BG_SVC] Fetching: $tasksUrl');

  final response = await http
      .get(tasksUrl, headers: {'Content-Type': 'application/json'})
      .timeout(const Duration(seconds: 10));

  if (response.statusCode != 200) {
    debugPrint('[BG_SVC] HTTP ${response.statusCode}: ${response.body}');
    return;
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final tasks = data['tasks'] as List<dynamic>;

  // Load already-notified task IDs from SharedPreferences
  final notifiedRaw = prefs.getStringList(_prefsNotifiedKey) ?? [];
  final alreadyNotified = Set<String>.from(notifiedRaw);
  debugPrint('[BG_SVC] Got ${tasks.length} tasks, ${alreadyNotified.length} already notified');

  // Check each task for completion
  final newlyNotified = <String>[];
  for (final t in tasks) {
    final task = t as Map<String, dynamic>;
    final taskId = task['id'] as String;
    final status = task['status'] as String;

    if (alreadyNotified.contains(taskId)) continue;

    if (status == 'completed') {
      final prompt = task['prompt'] as String? ?? 'Task';
      final preview = prompt.length > 80 ? '${prompt.substring(0, 80)}...' : prompt;
      await localNotif.show(
        id: taskId.hashCode,
        title: '✅ Task Complete',
        body: preview,
        notificationDetails: const ln.NotificationDetails(
          android: ln.AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: ln.Importance.high,
            priority: ln.Priority.high,
            playSound: true,
            enableVibration: true,
            showWhen: true,
            category: ln.AndroidNotificationCategory.message,
          ),
        ),
        payload: taskId,
      );
      newlyNotified.add(taskId);
      alreadyNotified.add(taskId);
      debugPrint('[BG_SVC] Notified completed: $taskId');
    } else if (status == 'failed') {
      final errMsg = task['error_message'] as String? ?? 'Task failed';
      await localNotif.show(
        id: taskId.hashCode,
        title: '❌ Task Failed',
        body: errMsg,
        notificationDetails: const ln.NotificationDetails(
          android: ln.AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: ln.Importance.high,
            priority: ln.Priority.high,
            playSound: true,
            enableVibration: true,
            showWhen: true,
            category: ln.AndroidNotificationCategory.message,
          ),
        ),
        payload: taskId,
      );
      newlyNotified.add(taskId);
      alreadyNotified.add(taskId);
      debugPrint('[BG_SVC] Notified failed: $taskId');
    }
  }

  // Persist updated notified set
  if (newlyNotified.isNotEmpty) {
    await prefs.setStringList(_prefsNotifiedKey, alreadyNotified.toList());
    debugPrint('[BG_SVC] Persisted ${newlyNotified.length} new notifications');
  }
}
