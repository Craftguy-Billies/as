import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/api_service.dart';
import 'services/preferences_service.dart';
import 'services/notification_service.dart';
import 'providers/task_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/live_feed_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/log_viewer_screen.dart';
import 'screens/app_shell.dart';
import 'providers/chat_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    try { await Firebase.initializeApp(); } catch (_) {}
  }
  final prefs = PreferencesService();
  try { await prefs.init(); } catch (_) { /* prefs unavailable — defaults used */ }
  final api = ApiService();
  api.setBaseUrl(prefs.serverUrl);
  NotificationService? ns;
  if (!kIsWeb) {
    ns = NotificationService(api);
    try { await ns.initialize(); } catch (_) {}
  }
  runApp(VibeCodeApp(api: api, prefs: prefs, ns: ns));
}

class VibeCodeApp extends StatelessWidget {
  final ApiService api;
  final PreferencesService prefs;
  final NotificationService? ns;
  const VibeCodeApp({super.key, required this.api, required this.prefs, this.ns});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: prefs),
        ChangeNotifierProvider(create: (_) => TaskProvider(api, prefs)),
        ChangeNotifierProvider(create: (_) => SettingsProvider(api, prefs)),
        ChangeNotifierProvider(create: (_) => ChatProvider(api)),
      ],
      child: MaterialApp(
        title: 'VibeCode',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0D0D0D),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF7C3AED),
            secondary: Color(0xFF2563EB),
            surface: Color(0xFF121212),
          ),
          appBarTheme: const AppBarTheme(
            elevation: 0, centerTitle: false,
            iconTheme: IconThemeData(color: Colors.white),
            titleTextStyle: TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600,
            ),
          ),
        ),
        initialRoute: '/',
        onGenerateRoute: (settings) {
          if (settings.name == '/setup') {
            return MaterialPageRoute(builder: (_) => const SetupScreen());
          }
          final m = RegExp(r'^/tasks/(.+)$').firstMatch(settings.name ?? '');
          if (m != null) {
            return MaterialPageRoute(builder: (_) => LiveFeedScreen(taskId: m.group(1)!));
          }
          switch (settings.name) {
            case '/': return MaterialPageRoute(builder: (_) => const AppShell());
            case '/settings': return MaterialPageRoute(builder: (_) => const SettingsScreen());
            case '/logs': return MaterialPageRoute(builder: (_) => const LogViewerScreen());
            default: return MaterialPageRoute(builder: (_) => const AppShell());
          }
        },
      ),
    );
  }
}
