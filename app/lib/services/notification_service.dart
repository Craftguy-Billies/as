import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;
  final List<StreamSubscription> _subscriptions = [];
  final FlutterLocalNotificationsPlugin _localNotif = FlutterLocalNotificationsPlugin();
  bool _localReady = false;
  int _notifIdCounter = 1000;
  void Function(String taskId)? onTaskTap;
  void Function(String title, String body)? onForegroundMessage;

  NotificationService(this._api);

  Future<void> initialize() async {
    // Initialize local notifications as fallback
    await _initLocalNotifications();

    // Try FCM — non-fatal if it fails
    await _initFcm();
  }

  Future<void> _initLocalNotifications() async {
    if (kIsWeb) return;
    try {
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
      await _localNotif.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty && onTaskTap != null) {
            onTaskTap!(payload);
          }
        },
      );

      // Request Android 13+ permission explicitly
      if (!kIsWeb) {
        try {
          final androidPlugin = _localNotif.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
          if (androidPlugin != null) {
            await androidPlugin.requestNotificationsPermission();
          }
        } catch (_) {}
      }

      _localReady = true;
      debugPrint('[NOTIF] Local notifications initialized');
    } catch (e) {
      debugPrint('[NOTIF] Local notifications init failed: $e');
    }
  }

  Future<void> _initFcm() async {
    if (kIsWeb) return;
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
          debugPrint('[NOTIF] FCM token registered');
        }

        _subscriptions.add(
          _messaging.onTokenRefresh.listen((newToken) {
            try {
              _api.registerFcmToken(newToken);
              debugPrint('[NOTIF] FCM token refreshed');
            } catch (_) {}
          }),
        );
      }

      _subscriptions.add(
        FirebaseMessaging.onMessage.listen((msg) {
          debugPrint('[NOTIF] Foreground FCM message received');
          _handleForegroundMessage(msg);
        }),
      );

      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((msg) {
          debugPrint('[NOTIF] Background tap handled');
          _handleNotificationTap(msg);
        }),
      );

      final initial = await _messaging.getInitialMessage();
      if (initial != null) {
        debugPrint('[NOTIF] Terminated tap handled');
        _handleNotificationTap(initial);
      }

      debugPrint('[NOTIF] FCM initialized successfully');
    } catch (e) {
      debugPrint('[NOTIF] FCM init skipped (non-fatal): $e');
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  /// Fire a notification. Uses FCM when possible, falls back to local.
  Future<void> showTaskCompleteNotification({
    required String taskId,
    required String title,
    String body = '',
  }) async {
    debugPrint('[NOTIF] showTaskCompleteNotification: $title (task=$taskId)');

    // Try local notification (always works if init succeeded)
    if (_localReady) {
      try {
        final androidDetails = AndroidNotificationDetails(
          'task_complete',
          'Task Updates',
          channelDescription: 'Notifications when AI tasks complete',
          importance: Importance.high,
          priority: Priority.high,
          showWhen: true,
          enableVibration: true,
          playSound: true,
        );
        const iosDetails = DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true);
        final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
        final notifId = _notifIdCounter++;
        await _localNotif.show(notifId, title, body, details, payload: taskId);
        debugPrint('[NOTIF] Local notification shown (id=$notifId)');
        return;
      } catch (e) {
        debugPrint('[NOTIF] Local notification show failed: $e');
      }
    }

    debugPrint('[NOTIF] No notification channel available (local not ready)');
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final title = message.notification?.title ?? 'Task Update';
    final body = message.notification?.body ?? '';
    debugPrint('[NOTIF] Foreground message: $title');
    onForegroundMessage?.call(title, body);
  }

  void _handleNotificationTap(RemoteMessage message) {
    final taskId = message.data['task_id'];
    if (taskId != null && onTaskTap != null) {
      debugPrint('[NOTIF] Notification tap -> task $taskId');
      onTaskTap!(taskId);
    }
  }
}
