import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _gitNameCtrl = TextEditingController();
  final _gitEmailCtrl = TextEditingController();
  Timer? _urlDebounce;

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _urlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    _gitNameCtrl.dispose();
    _gitEmailCtrl.dispose();
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
          if (settings.modelName != null && settings.modelName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Current model: ${settings.modelName}',
                style: const TextStyle(color: Colors.green, fontSize: 13),
              ),
            ),
          _buildTextField(
            controller: _apiKeyCtrl,
            label: 'API Key',
            hint: 'sk-...',
            icon: Icons.key,
            obscure: true,
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _modelCtrl,
            label: 'Model',
            hint: 'deepseek-chat / gpt-4o / claude-sonnet-4-20250514',
            icon: Icons.smart_toy,
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _baseUrlCtrl,
            label: 'Base URL (optional)',
            hint: 'https://api.deepseek.com/v1',
            icon: Icons.link,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () async {
              if (_apiKeyCtrl.text.isEmpty || _modelCtrl.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('API Key and Model are required'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              await settings.updateLlmConfig(
                apiKey: _apiKeyCtrl.text.trim(),
                model: _modelCtrl.text.trim(),
                baseUrl: _baseUrlCtrl.text.trim().isEmpty
                    ? null
                    : _baseUrlCtrl.text.trim(),
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('LLM config updated'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save LLM Config'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
            ),
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

          // Presets
          _SectionTitle(title: 'Quick Setup'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PresetChip(
                label: 'DeepSeek',
                onTap: () {
                  _modelCtrl.text = 'deepseek-chat';
                  _baseUrlCtrl.text = 'https://api.deepseek.com/v1';
                },
              ),
              _PresetChip(
                label: 'Claude',
                onTap: () {
                  _modelCtrl.text = 'claude-sonnet-4-20250514';
                  _baseUrlCtrl.clear();
                },
              ),
              _PresetChip(
                label: 'OpenAI',
                onTap: () {
                  _modelCtrl.text = 'gpt-4o';
                  _baseUrlCtrl.clear();
                },
              ),
              _PresetChip(
                label: 'Groq',
                onTap: () {
                  _modelCtrl.text = 'llama-3.3-70b-versatile';
                  _baseUrlCtrl.text = 'https://api.groq.com/openai/v1';
                },
              ),
              _PresetChip(
                label: 'OpenRouter',
                onTap: () {
                  _modelCtrl.text = 'openai/gpt-4o';
                  _baseUrlCtrl.text = 'https://openrouter.ai/api/v1';
                },
              ),
            ],
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

class _PresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PresetChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF7C3AED).withAlpha(70)),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ),
    );
  }
}
