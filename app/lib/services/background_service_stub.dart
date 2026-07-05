import 'package:flutter/foundation.dart';

/// Web stub — no background tasks supported.
Future<void> initBackgroundService() async {
  debugPrint('[BG_SVC] Web platform — background service skipped');
}

Future<void> cancelBackgroundService() async {
  debugPrint('[BG_SVC] Web platform — nothing to cancel');
}
