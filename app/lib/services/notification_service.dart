import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api_service.dart';

/// Callback invoked when the user sends a reply via notification.
typedef ReplyCallback = Future<void> Function(String taskId, String message);

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'vibecode_tasks';
  static const _channelName = 'Task Notifications';
  static const _replyActionId = 'reply';
  static const _openActionId = 'open';

  ReplyCallback? onReply;

  NotificationService(this._api);

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    // Create notification channel
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: 'Notifications when AI tasks complete',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

    // Request Android 13+ notification permission
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    // Initialize FCM
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        final token = await _messaging.getToken();
        if (token != null) {
          await _api.registerFcmToken(token);
        }

        _messaging.onTokenRefresh.listen((newToken) {
          _api.registerFcmToken(newToken);
        });
      }

      // Foreground messages (from FCM)
      FirebaseMessaging.onMessage.listen(_handleFcmMessage);

      // Background tap on FCM notification
      FirebaseMessaging.onMessageOpenedApp.listen(_handleFcmTap);

      // Terminated tap on FCM notification
      final initial = await _messaging.getInitialMessage();
      if (initial != null) {
        _handleFcmTap(initial);
      }
    } catch (_) {
      // Firebase not configured — push notifications via FCM disabled
    }
  }

  /// Show a local notification for a completed task with a reply action.
  Future<void> showTaskCompleteNotification({
    required String taskId,
    required String title,
    required String body,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Notifications when AI tasks complete',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      fullScreenIntent: false,
      showWhen: true,
      category: AndroidNotificationCategory.message,
      actions: <AndroidNotificationAction>[
        // Direct reply action with text input
        const AndroidNotificationAction(
          _replyActionId,
          'Reply',
          inputs: <AndroidNotificationActionInput>[
            AndroidNotificationActionInput(
              label: 'Type your reply...',
              allowFreeFormInput: true,
            ),
          ],
          showsUserInterface: false,
          cancelNotification: false,
          semanticAction: SemanticAction.reply,
        ),
        // Open action
        const AndroidNotificationAction(
          _openActionId,
          'Open',
          showsUserInterface: true,
          cancelNotification: false,
          semanticAction: SemanticAction.none,
        ),
      ],
    );

    final platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    // Use task_id as a unique notification ID to avoid duplicates
    final notificationId = taskId.hashCode;

    await _localNotifications.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: taskId,
    );
  }

  /// Dismiss a specific notification by task ID.
  Future<void> dismissNotification(String taskId) async {
    await _localNotifications.cancel(id: taskId.hashCode);
  }

  /// Return pending replies stored from notification-triggered sends.
  /// Kept for compatibility with TaskProvider.processPendingReplies().
  Future<List<Map<String, String>>> getPendingReplies() async {
    // The flutter_local_notifications plugin handles reply delivery
    // synchronously via _handleNotificationResponse, so no pending store needed.
    return [];
  }

  /// Handle notification action responses (reply, open).
  void _handleNotificationResponse(NotificationResponse response) {
    final taskId = response.payload;
    if (taskId == null) return;

    if (response.actionId == _replyActionId) {
      final replyText = response.input;
      if (replyText != null && replyText.isNotEmpty) {
        // Send the reply and dismiss notification
        _handleReply(taskId, replyText);
      }
    } else if (response.actionId == _openActionId) {
      // Open the task screen - navigate via the app navigator
      _navigateToTask(taskId);
    }
  }

  /// Send reply message and dismiss notification.
  Future<void> _handleReply(String taskId, String message) async {
    try {
      await _api.sendReply(taskId, message);
    } catch (_) {
      // Silently handle errors in notification reply
    }
    // Dismiss the notification
    await dismissNotification(taskId);

    // Notify any registered callback
    if (onReply != null) {
      await onReply!(taskId, message);
    }
  }

  /// Handle FCM data message payload.
  void _handleFcmMessage(RemoteMessage message) {
    final taskId = message.data['task_id'];
    final title = message.notification?.title ?? '✅ Task Complete';
    final body = message.notification?.body ?? 'Your AI task has finished.';
    if (taskId != null) {
      showTaskCompleteNotification(
        taskId: taskId,
        title: title,
        body: body,
      );
    }
  }

  /// Handle tapping an FCM notification.
  void _handleFcmTap(RemoteMessage message) {
    final taskId = message.data['task_id'];
    if (taskId != null) {
      _navigateToTask(taskId);
    }
  }

  /// Navigate to the live feed screen for a task.
  void _navigateToTask(String taskId) {
    final context = _navigatorKey.currentContext;
    if (context != null) {
      Navigator.pushNamed(context, '/tasks/$taskId');
    }
  }

  /// Global navigator key for navigation from notifications.
  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  static GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;
}
