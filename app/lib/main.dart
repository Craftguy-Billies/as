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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  final prefs = PreferencesService(); await prefs.init();
  final api = ApiService();
  if (prefs.serverUrl != null) { api.setBaseUrl(prefs.serverUrl!); }
  final ns = NotificationService(api); await ns.initialize();

  // Setup task provider with notification service
  final taskProvider = TaskProvider(api, prefs);
  taskProvider.setNotificationService(ns);

  // Process any pending replies from notification actions
  await taskProvider.processPendingReplies();
  await taskProvider.loadTasks();

  runApp(VibeCodeApp(api: api, prefs: prefs, taskProvider: taskProvider, notificationService: ns));
}

class VibeCodeApp extends StatelessWidget {
  final ApiService api;
  final PreferencesService prefs;
  final TaskProvider taskProvider;
  final NotificationService notificationService;
  const VibeCodeApp({
    super.key,
    required this.api,
    required this.prefs,
    required this.taskProvider,
    required this.notificationService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: taskProvider),
        ChangeNotifierProvider(create: (_) => SettingsProvider(api, prefs)),
      ],
      child: MaterialApp(
        navigatorKey: NotificationService.navigatorKey,
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
            case '/': return MaterialPageRoute(builder: (_) => const HomeScreen());
            case '/settings': return MaterialPageRoute(builder: (_) => const SettingsScreen());
            default: return MaterialPageRoute(builder: (_) => const HomeScreen());
          }
        },
      ),
    );
  }
}
