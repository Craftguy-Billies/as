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

class _HomeScreenState extends State<HomeScreen> {
  final _promptCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  String _mode = 'code';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final prefs = context.read<PreferencesService>();
    _repoCtrl.text = prefs.lastRepo;
    _mode = prefs.lastMode;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  Future<void> _autoConnect() async {
    final settings = context.read<SettingsProvider>();
    if (settings.connected == null) {
      try {
        await settings.testConnection().timeout(const Duration(seconds: 12));
        if (mounted && settings.connected == true) {
          context.read<TaskProvider>().loadTasks();
        }
      } catch (_) {
        if (mounted && settings.connected == null) {
          settings.markDisconnected();
        }
      }
    }
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _repoCtrl.dispose();
    super.dispose();
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
      context.read<PreferencesService>().saveLastPrompt(repo, 'main', _mode);
      _promptCtrl.clear();
      Navigator.pushNamed(context, '/tasks/${task.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskProv = context.watch<TaskProvider>();
    final settings = context.watch<SettingsProvider>();

    if (settings.connected == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 80, width: 80,
                child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF7C3AED))),
              SizedBox(height: 24),
              Text('VibeCode', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('Connecting to server...', style: TextStyle(color: Colors.grey, fontSize: 14)),
            ],
          ),
        ),
      );
    }

    if (settings.connected == false) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Cannot connect to server', style: TextStyle(color: Colors.white, fontSize: 18)),
                const SizedBox(height: 8),
                Text(settings.serverUrl ?? '', style: TextStyle(color: Colors.grey[600], fontSize: 14)),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => settings.testConnection(),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
                  child: const Text('Retry', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/settings'),
                  child: const Text('Change server URL', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      );
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
            child: taskProv.loading
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
                    : RefreshIndicator(
                        onRefresh: () => taskProv.loadTasks(),
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
