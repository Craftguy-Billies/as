import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;
  final List<StreamSubscription> _subscriptions = [];
  void Function(String taskId)? onTaskTap;
  void Function(String title, String body)? onForegroundMessage;

  NotificationService(this._api);

  Future<void> initialize() async {
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

        // Handle token refresh
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
      // Firebase not configured — push notifications disabled
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
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
}
