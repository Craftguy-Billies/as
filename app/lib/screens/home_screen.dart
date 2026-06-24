import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/task_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/chat_provider.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';
import '../widgets/task_tile.dart';
import '../widgets/branch_popup.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _promptCtrl = TextEditingController();
  final _repoCtrl = TextEditingController();
  final _branchCtrl = TextEditingController();
  // _mode removed (always 'code')
  bool _sending = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    // Step 1: Restore repo/branch from PreferencesService (fast, local)
    final prefs = context.read<PreferencesService>();
    _repoCtrl.text = prefs.lastRepo;
    _branchCtrl.text = prefs.lastBranch;
    final savedRepo = _repoCtrl.text.trim();
    final savedBranch = _branchCtrl.text.trim();
    debugPrint('[HomeScreen._init] prefs restored repo=$savedRepo branch=$savedBranch');

    // Step 2: Populate ChatProvider with saved repo
    if (savedRepo.isNotEmpty) {
      context.read<ChatProvider>().initRepoFromHome(savedRepo);
    }

    // Step 3: Load cached + server state (async)
    try {
      final restoredRepo = await context.read<ChatProvider>().loadFromCache();
      final prov = context.read<ChatProvider>();
      debugPrint('[HomeScreen._init] loadFromCache done, serverRepo=${prov.serverRepo} branch=${prov.serverBranch}');

      // Step 4: Sync controllers — serverRepo is authoritative
      if (mounted) {
        if (prov.serverRepo.isNotEmpty && _repoCtrl.text != prov.serverRepo) {
          _repoCtrl.text = prov.serverRepo;
          debugPrint('[HomeScreen._init] synced _repoCtrl: ${prov.serverRepo}');
        }
        if (prov.serverBranch.isNotEmpty && _branchCtrl.text != prov.serverBranch) {
          _branchCtrl.text = prov.serverBranch;
          debugPrint('[HomeScreen._init] synced _branchCtrl: ${prov.serverBranch}');
        }
        // Persist whatever we ended up with so next boot is instant
        if (_repoCtrl.text.isNotEmpty) {
          prefs.saveLastPrompt(
            _repoCtrl.text.trim(),
            _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim(),
            'code',
          );
        }
      }
    } catch (e) {
      debugPrint('[HomeScreen._init] loadFromCache error: $e');
    }

    // Step 5: Auto-connect (original _autoConnect logic)
    try {
      final settings = context.read<SettingsProvider>();
      if (settings.connected == null) {
        try {
          await settings.testConnection().timeout(const Duration(seconds: 12));
          if (mounted && settings.connected == true) {
            await context.read<TaskProvider>().loadTasks();
          }
        } catch (_) {
          if (mounted && settings.connected == null) {
            settings.markDisconnected();
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _repoCtrl.dispose();
    _branchCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendPrompt() async {
    final prompt = _promptCtrl.text.trim();
    final repo = _repoCtrl.text.trim();
    if (prompt.isEmpty || repo.isEmpty) {
      _showError(prompt.isEmpty ? 'Enter a prompt' : 'Enter a GitHub repo (owner/repo)');
      return;
    }
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) {
      _showError('Invalid repo format. Use: owner/repo');
      return;
    }

    setState(() => _sending = true);
    try {
      final branch = _branchCtrl.text.trim().isEmpty ? '' : _branchCtrl.text.trim();
      final taskProv = context.read<TaskProvider>();
      final task = await taskProv
          .createPrompt(prompt: prompt, repo: repo, branch: branch, mode: 'code')
          .timeout(const Duration(seconds: 15));
      if (task != null && mounted) {
        context.read<PreferencesService>().saveLastPrompt(repo, branch, 'code');
        _promptCtrl.clear();
        Navigator.pushNamed(context, '/tasks/${task.id}');
      } else {
        final err = context.read<TaskProvider>().error ?? 'Unknown error';
        _showError('Failed: $err');
      }
    } catch (e) {
      _showError(e is TimeoutException
          ? 'Server not responding. Check VM.'
          : ApiService.friendlyError(e));
    }
    if (mounted) setState(() => _sending = false);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _confirmClearHistory(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Clear History', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Delete all tasks and chat history? This cannot be undone.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<TaskProvider>().deleteAllTasks();
            },
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
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
          if (taskProv.tasks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              tooltip: 'Clear all history',
              onPressed: () => _confirmClearHistory(context),
            ),
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
                // Line 1: repo + branch + mode (send button is on line 2)
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
                    const SizedBox(width: 6),
                    BranchPopup(
                      controller: _branchCtrl,
                      onChanged: () => context.read<PreferencesService>().saveLastPrompt(_repoCtrl.text, _branchCtrl.text, 'code'),
                      width: 100,
                      height: 34,
                      borderRadius: 12,
                    ),
                    const SizedBox(width: 6),
                    // Mode label (code-only, plan mode hidden)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bolt, size: 16, color: Colors.grey[400]),
                          const SizedBox(width: 4),
                          Text('Code', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Line 2: send button (full width)
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _sending ? null : _sendPrompt,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _sending
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.send, color: Colors.white, size: 18),
                              SizedBox(width: 8),
                              Text('Send to AI', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                            ],
                          ),
                  ),
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
                              onRetry: task.isFailed
                                  ? () => taskProv.retryTask(task.id)
                                  : null,
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
