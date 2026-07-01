import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

/// Callback invoked when the user sends a reply via notification.
typedef ReplyCallback = Future<void> Function(String taskId, String message);

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final List<StreamSubscription> _subscriptions = [];

  static const _channelId = 'vibecode_tasks';
  static const _channelName = 'Task Notifications';
  static const _replyActionId = 'reply';
  static const _openActionId = 'open';

  void Function(String taskId)? onTaskTap;
  void Function(String title, String body)? onForegroundMessage;
  ReplyCallback? onReply;

  NotificationService(this._api);

  Future<void> initialize() async {
    // Initialize local notifications
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

        _subscriptions.add(
          _messaging.onTokenRefresh.listen((newToken) {
            try {
              _api.registerFcmToken(newToken);
            } catch (_) {}
          }),
        );
      }

      // Foreground messages
      _subscriptions.add(
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage),
      );

      // Background tap
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap),
      );

      // Terminated tap
      final initial = await _messaging.getInitialMessage();
      if (initial != null) {
        _handleNotificationTap(initial);
      }
    } catch (_) {
      // Firebase not configured — push notifications via FCM disabled
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  /// Show a local notification for a completed task with a direct reply action.
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
        // Direct reply action with text input - verified syntax from
        // flutter_local_notifications source: notification_details.dart
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

    final notificationId = taskId.hashCode;
    await _localNotifications.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: platformDetails,
      payload: taskId,
    );
  }

  /// Dismiss a notification by task ID.
  Future<void> dismissNotification(String taskId) async {
    await _localNotifications.cancel(id: taskId.hashCode);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final title = message.notification?.title ?? 'Task Update';
    final body = message.notification?.body ?? '';
    onForegroundMessage?.call(title, body);
  }

  void _handleNotificationTap(RemoteMessage message) {
    final taskId = message.data['task_id'];
    if (taskId != null && onTaskTap != null) {
      onTaskTap!(taskId);
    }
  }

  /// Handle notification action responses (reply, open).
  void _handleNotificationResponse(NotificationResponse response) {
    final taskId = response.payload;
    if (taskId == null) return;

    if (response.actionId == _replyActionId) {
      final replyText = response.input;
      if (replyText != null && replyText.isNotEmpty) {
        _handleReply(taskId, replyText);
      }
    } else if (response.actionId == _openActionId) {
      onTaskTap?.call(taskId);
    }
  }

  /// Send reply via API and dismiss notification.
  Future<void> _handleReply(String taskId, String message) async {
    try {
      await _api.sendReply(taskId, message);
    } catch (_) {
      // Silently handle errors in notification replies
    }
    await dismissNotification(taskId);
    if (onReply != null) {
      await onReply!(taskId, message);
    }
  }
}
