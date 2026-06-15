import 'package:firebase_messaging/firebase_messaging.dart';
import 'api_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiService _api;

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
        _messaging.onTokenRefresh.listen((newToken) {
          _api.registerFcmToken(newToken);
        });
      }

      // Foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Background tap
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Terminated tap
      final initial = await _messaging.getInitialMessage();
      if (initial != null) {
        _handleNotificationTap(initial);
      }
    } catch (_) {
      // Firebase not configured — push notifications disabled
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // Show in-app banner handled by the UI layer
  }

  void _handleNotificationTap(RemoteMessage message) {
    final taskId = message.data['task_id'];
    if (taskId != null) {
      // Navigate to task — handled by app's navigator observer
    }
  }
}
