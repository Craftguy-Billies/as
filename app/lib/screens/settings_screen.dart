import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../services/preferences_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _gitNameCtrl = TextEditingController();
  final _gitEmailCtrl = TextEditingController();
  final _implementCtrl = TextEditingController();
  final _testCtrl = TextEditingController();
  final _auditCtrl = TextEditingController();
  String _selectedModel = 'deepseek/deepseek-v4-flash';
  Timer? _urlDebounce;

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _urlCtrl.dispose();
    _gitNameCtrl.dispose();
    _gitEmailCtrl.dispose();
    _implementCtrl.dispose();
    _testCtrl.dispose();
    _auditCtrl.dispose();
    super.dispose();
  }

  void _onUrlChanged(String v) {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 800), () {
      context.read<SettingsProvider>().setServerUrl(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    if (settings.serverUrl != null && _urlCtrl.text.isEmpty) {
      _urlCtrl.text = settings.serverUrl!;
    }

    // Pre-populate git config from server state
    if (settings.gitName != null && _gitNameCtrl.text.isEmpty) {
      _gitNameCtrl.text = settings.gitName!;
    }
    if (settings.gitEmail != null && _gitEmailCtrl.text.isEmpty) {
      _gitEmailCtrl.text = settings.gitEmail!;
    }

    // Pre-populate implement prompt from local prefs
    if (_implementCtrl.text.isEmpty) {
      _implementCtrl.text = context.read<PreferencesService>().implementPrompt;
    }
    // Pre-populate test prompt from local prefs (default empty)
    if (_testCtrl.text.isEmpty) {
      _testCtrl.text = context.read<PreferencesService>().testPrompt;
    }
    // Pre-populate audit prompt from local prefs
    if (_auditCtrl.text.isEmpty) {
      _auditCtrl.text = context.read<PreferencesService>().auditPrompt;
    }

    // Pre-populate model selection from server state (only when default = first build)
    if (settings.modelName != null && settings.modelName!.isNotEmpty && _selectedModel == 'deepseek/deepseek-v4-flash') {
      _selectedModel = settings.modelName!;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0D0D0D),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server section
          _SectionTitle(title: 'Server'),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _urlCtrl,
            label: 'Backend URL',
            hint: 'http://YOUR_VM_IP:8080',
            icon: Icons.dns,
            onChanged: _onUrlChanged,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: settings.testing ? null : () async {
                    final ok = await settings.testConnection();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? 'Connected!' : 'Connection failed'),
                          backgroundColor: ok ? Colors.green : Colors.red,
                        ),
                      );
                    }
                  },
                  icon: settings.testing
                      ? const SizedBox(
                          height: 16, width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          settings.connected == true
                              ? Icons.check_circle
                              : settings.connected == false
                                  ? Icons.error
                                  : Icons.wifi_find,
                        ),
                  label: const Text('Test Connection'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A2E),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // LLM Configuration
          _SectionTitle(title: 'LLM Configuration'),
          const SizedBox(height: 8),
          Text(
            'Choose the AI model for all conversations. '
            'Changes take effect on the next message (existing chats are preserved).',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 12),
          // Pre-populate _selectedModel from server state
          _buildModelSelector(),
          const SizedBox(height: 8),
          Text(
            settings.modelName != null && settings.modelName!.isNotEmpty
                ? 'Current model: ${settings.modelName}'
                : 'Current model: ${_selectedModel}',
            style: TextStyle(color: Colors.grey[500], fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            'API key is pre-configured on the server.',
            style: TextStyle(color: Colors.grey[700], fontSize: 11),
          ),

          const SizedBox(height: 32),

          // Git Configuration
          _SectionTitle(title: 'Git Configuration'),
          const SizedBox(height: 4),
          Text(
            'Used for commits made by AI agents',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _gitNameCtrl,
            label: 'Git Name',
            hint: 'Your Name',
            icon: Icons.person,
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _gitEmailCtrl,
            label: 'Git Email',
            hint: 'you@example.com',
            icon: Icons.email,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () async {
              if (_gitNameCtrl.text.isEmpty || _gitEmailCtrl.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Name and email are required'), backgroundColor: Colors.red),
                );
                return;
              }
              await settings.updateGitConfig(
                name: _gitNameCtrl.text.trim(),
                email: _gitEmailCtrl.text.trim(),
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Git config saved'), backgroundColor: Colors.green),
                );
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Git Config'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
              foregroundColor: Colors.white,
            ),
          ),

          const SizedBox(height: 32),

          // Diagnostics
          _SectionTitle(title: 'Diagnostics'),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/logs'),
            icon: const Icon(Icons.terminal),
            label: const Text('View Server Logs'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A2E),
            ),
          ),

          const SizedBox(height: 32),

          // Implement Prompt
          _SectionTitle(title: 'Implement Prompt'),
          const SizedBox(height: 8),
          Text(
            'When the "Implement" checkbox is checked, this prompt is appended '
            'to each message. Customize it per-device.',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _implementCtrl,
            maxLines: 6,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Enter implement instructions…',
              hintStyle: TextStyle(color: Colors.grey[700], fontSize: 13),
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () async {
              final prefs = context.read<PreferencesService>();
              await prefs.setImplementPrompt(_implementCtrl.text.trim());
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Implement prompt saved'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Implement Prompt'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
              foregroundColor: Colors.white,
            ),
          ),

          const SizedBox(height: 32),

          // Test & Debug Prompt
          _SectionTitle(title: 'Test & Debug Prompt'),
          const SizedBox(height: 8),
          Text(
            'When the "Test" checkbox is checked, this prompt is appended '
            'to each message. Leave blank to disable. Customize per-device.',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _testCtrl,
            maxLines: 6,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Enter test/debug instructions… (default: empty)',
              hintStyle: TextStyle(color: Colors.grey[700], fontSize: 13),
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () async {
              final prefs = context.read<PreferencesService>();
              await prefs.setTestPrompt(_testCtrl.text.trim());
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Test prompt saved'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Test Prompt'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
              foregroundColor: Colors.white,
            ),
          ),

          const SizedBox(height: 32),

          // Audit Prompt
          _SectionTitle(title: 'Audit Prompt'),
          const SizedBox(height: 8),
          Text(
            'When the "Audit" checkbox is checked, this prompt is appended '
            'to each message. Customize per-device.',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _auditCtrl,
            maxLines: 6,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Enter audit instructions…',
              hintStyle: TextStyle(color: Colors.grey[700], fontSize: 13),
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () async {
              final prefs = context.read<PreferencesService>();
              await prefs.setAuditPrompt(_auditCtrl.text.trim());
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Audit prompt saved'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Audit Prompt'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
              foregroundColor: Colors.white,
            ),
          ),

          const SizedBox(height: 32),

          // About
          _SectionTitle(title: 'About'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('VibeCode v1.0.0', style: TextStyle(color: Colors.white70)),
                SizedBox(height: 4),
                Text(
                  'Powered by OpenHands Cloud',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelSelector() {
    const models = [
      ('deepseek/deepseek-v4-flash', 'DeepSeek V4 Flash', 'Fast, cost-effective'),
      ('deepseek/deepseek-v4-pro', 'DeepSeek V4 Pro', 'Best quality, slower'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final (modelId, label, desc) in models)
            Material(
              color: Colors.transparent,
              child: ListTile(
                dense: true,
                leading: Icon(
                  _selectedModel == modelId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: _selectedModel == modelId
                      ? const Color(0xFF7C3AED)
                      : Colors.grey[600],
                  size: 22,
                ),
                title: Text(
                  label,
                  style: TextStyle(
                    color: _selectedModel == modelId ? Colors.white : Colors.grey[400],
                    fontSize: 14,
                    fontWeight: _selectedModel == modelId ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  desc,
                  style: TextStyle(color: Colors.grey[600], fontSize: 11),
                ),
                onTap: () {
                  _saveModelSelection(modelId);
                },
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _saveModelSelection(String modelId) async {
    final settings = context.read<SettingsProvider>();
    try {
      await settings.updateLlmConfig(model: modelId);
      setState(() => _selectedModel = modelId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Model changed to ${modelId.replaceAll("deepseek/", "")}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save model: ${e.toString().replaceAll("Exception: ", "")}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey[500]),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[700], fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF1A1A2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        prefixIcon: Icon(icon, color: Colors.grey[500], size: 20),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: Color(0xFF7C3AED),
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
      ),
    );
  }
}
