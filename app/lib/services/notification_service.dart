import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as ln;
import 'api_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;
  final ln.FlutterLocalNotificationsPlugin _localNotifications =
      ln.FlutterLocalNotificationsPlugin();
  final List<StreamSubscription> _subscriptions = [];
  void Function(String taskId)? onTaskTap;
  void Function(String title, String body)? onForegroundMessage;

  static const String _channelId = 'vibecode_tasks';
  static const String _channelName = 'Task Notifications';
  static const String _channelDesc = 'Notifications when AI tasks complete';

  bool _localInitialized = false;
  bool _disposed = false;

  NotificationService(this._api);

  Future<void> initialize() async {
    debugPrint('[NOTIF] === initialize() start ===');

    // Step 1: Initialize local notifications (always works)
    await _initLocalNotifications();

    // Step 2: Request Android 13+ POST_NOTIFICATIONS permission
    await _requestAndroidPermission();

    // Step 3: Initialize FCM (best-effort, may fail silently)
    await _initFcm();

    debugPrint('[NOTIF] === initialize() done: local=$_localInitialized ===');
  }

  Future<void> _initLocalNotifications() async {
    try {
      const androidSettings = ln.AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = ln.DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const initSettings = ln.InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _localNotifications.initialize(settings: initSettings);

      // Create notification channel for Android 8+ (required)
      await _localNotifications
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

      _localInitialized = true;
      debugPrint('[NOTIF] Local notifications initialized OK');
    } catch (e) {
      debugPrint('[NOTIF] Local notifications init FAILED: $e');
    }
  }

  Future<void> _requestAndroidPermission() async {
    try {
      final granted = await _localNotifications
          .resolvePlatformSpecificImplementation<
              ln.AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      debugPrint('[NOTIF] Android POST_NOTIFICATIONS permission granted: $granted');
    } catch (e) {
      debugPrint('[NOTIF] requestNotificationsPermission error: $e');
    }
  }

  Future<void> _initFcm() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('[NOTIF] FCM auth status: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        final token = await _messaging.getToken();
        if (token != null) {
          debugPrint('[NOTIF] FCM token obtained, registering...');
          try {
            await _api.registerFcmToken(token).timeout(const Duration(seconds: 5));
            debugPrint('[NOTIF] FCM token registered OK');
          } catch (e) {
            debugPrint('[NOTIF] FCM token register FAILED: $e');
          }
        } else {
          debugPrint('[NOTIF] FCM token is null');
        }

        _subscriptions.add(
          _messaging.onTokenRefresh.listen((newToken) {
            debugPrint('[NOTIF] FCM token refreshed');
            _api.registerFcmToken(newToken).catchError(
              (e) => debugPrint('[NOTIF] FCM token refresh register failed: $e'));
          }),
        );
      }

      _subscriptions.add(
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap),
      );

      final initial = await _messaging.getInitialMessage();
      if (initial != null) {
        debugPrint('[NOTIF] App launched from terminated FCM notification');
        _handleNotificationTap(initial);
      }

      debugPrint('[NOTIF] FCM initialized OK');
    } catch (e) {
      debugPrint('[NOTIF] FCM init FAILED (non-fatal, local still works): $e');
      // FCM failure is non-fatal — local notifications still work
    }
  }

  /// Show a local notification for a completed/failed task.
  Future<void> showTaskCompleteNotification({
    required String taskId,
    required String title,
    required String body,
  }) async {
    if (_disposed) {
      debugPrint('[NOTIF] showTaskCompleteNotification skipped (disposed)');
      return;
    }
    if (!_localInitialized) {
      debugPrint('[NOTIF] showTaskCompleteNotification skipped (not initialized)');
      return;
    }

    try {
      const androidDetails = ln.AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: ln.Importance.high,
        priority: ln.Priority.high,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: false,
        showWhen: true,
        category: ln.AndroidNotificationCategory.message,
      );

      const platformDetails = ln.NotificationDetails(
        android: androidDetails,
        iOS: ln.DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );

      await _localNotifications.show(
        id: taskId.hashCode,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: taskId,
      );
      debugPrint('[NOTIF] Shown: id=${taskId.hashCode} title=$title body=$body');
    } catch (e) {
      debugPrint('[NOTIF] showTaskCompleteNotification FAILED: $e');
    }
  }

  /// Dismiss a notification by task ID.
  Future<void> dismissNotification(String taskId) async {
    try {
      await _localNotifications.cancel(id: taskId.hashCode);
    } catch (_) {}
  }

  void dispose() {
    debugPrint('[NOTIF] dispose()');
    _disposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _localNotifications.cancelAll();
  }

  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[NOTIF] Foreground FCM msg: ${message.messageId}');
    final title = message.notification?.title ?? 'Task Update';
    final body = message.notification?.body ?? '';
    onForegroundMessage?.call(title, body);
  }

  void _handleNotificationTap(RemoteMessage message) {
    final taskId = message.data['task_id'];
    debugPrint('[NOTIF] FCM tap: task_id=$taskId');
    if (taskId != null && onTaskTap != null) {
      onTaskTap!(taskId);
    }
  }
}

