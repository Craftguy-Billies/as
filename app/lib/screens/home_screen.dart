import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/task_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _promptCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  String _mode = 'code';
  bool _sending = false;
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startAutoRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    _promptCtrl.dispose();
    _repoCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[HOME] App resumed — triggering immediate refresh');
      context.read<TaskProvider>().refreshTasks();
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[HOME] App paused — stopping auto-refresh timer');
      _autoRefreshTimer?.cancel();
      _autoRefreshTimer = null;
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    debugPrint('[HOME] Starting auto-refresh timer (5s interval)');
    // Refresh every 5 seconds while on home screen — GET /api/tasks is
    // read-only (zero KV writes), so this costs nothing in quota.
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        debugPrint('[HOME] Auto-refresh tick — calling refreshTasks()');
        context.read<TaskProvider>().refreshTasks();
      }
    });
  }

  Future<void> _sendPrompt() async {
    final prompt = _promptCtrl.text.trim();
    final repo = _repoCtrl.text.trim();
    if (prompt.isEmpty || repo.isEmpty) return;

    setState(() => _sending = true);
    final taskProv = context.read<TaskProvider>();
    final task = await taskProv.createPrompt(
      prompt: prompt,
      repo: repo,
      mode: _mode,
    );
    setState(() => _sending = false);

    if (task != null && mounted) {
      _promptCtrl.clear();
      Navigator.pushNamed(context, '/tasks/${task.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskProv = context.watch<TaskProvider>();
    final settings = context.watch<SettingsProvider>();

    if (!settings.isSetup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushReplacementNamed(context, '/setup');
      });
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('VibeCode', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0D0D0D),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Prompt input
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF121212),
            child: Column(
              children: [
                TextField(
                  controller: _promptCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: 'What do you want to build?',
                    hintStyle: TextStyle(color: Colors.grey[700]),
                    filled: true,
                    fillColor: const Color(0xFF1A1A2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _repoCtrl,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'owner/repo',
                          hintStyle: TextStyle(color: Colors.grey[700]),
                          filled: true,
                          fillColor: const Color(0xFF1A1A2E),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Mode toggle
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          _ModeChip(
                            label: 'Code',
                            icon: Icons.bolt,
                            selected: _mode == 'code',
                            onTap: () => setState(() => _mode = 'code'),
                          ),
                          _ModeChip(
                            label: 'Plan',
                            icon: Icons.map,
                            selected: _mode == 'plan',
                            onTap: () => setState(() => _mode = 'plan'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 42,
                      child: ElevatedButton(
                        onPressed: _sending ? null : _sendPrompt,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: _sending
                            ? const SizedBox(
                                height: 18, width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Task list
          Expanded(
            child: taskProv.loading && taskProv.tasks.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : taskProv.tasks.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.inbox, size: 64, color: Colors.grey[800]),
                            const SizedBox(height: 16),
                            Text(
                              'No tasks yet',
                              style: TextStyle(color: Colors.grey[600], fontSize: 18),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Type a prompt above to start vibe coding',
                              style: TextStyle(color: Colors.grey[700], fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : Stack(
                        children: [
                          RefreshIndicator(
                            onRefresh: () => taskProv.refreshTasks(),
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              itemCount: taskProv.tasks.length,
                              itemBuilder: (context, i) {
                                final task = taskProv.tasks[i];
                                return TaskTile(
                                  task: task,
                                  onTap: () =>
                                      Navigator.pushNamed(context, '/tasks/${task.id}'),
                                  onDelete: () => taskProv.deleteTask(task.id),
                                );
                              },
                            ),
                          ),
                          // Subtle refresh indicator at top when auto-refreshing
                          if (taskProv.refreshing)
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: const LinearProgressIndicator(
                                backgroundColor: Colors.transparent,
                                minHeight: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Color(0xFF7C3AED)),
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF7C3AED) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : Colors.grey),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.grey,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
