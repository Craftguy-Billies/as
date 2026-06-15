import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../providers/settings_provider.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _scrollCtrl = ScrollController();
  List<String> _lines = [];
  bool _autoScroll = true;
  Timer? _timer;
  bool _fetching = false;
  bool _initFailed = false;
  String _baseUrl = '';

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    try {
      final settings = context.read<SettingsProvider>();
      _baseUrl = settings.serverUrl;
      _doFetch();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _doFetch());
    } catch (_) {
      if (mounted) setState(() => _initFailed = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _doFetch() async {
    if (_fetching || _baseUrl.isEmpty) return;
    _fetching = true;
    try {
      try {
        final resp = await http
            .get(Uri.parse('$_baseUrl/api/logs'))
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          final newLines = (data['lines'] as List).cast<String>();
          if (mounted) {
            setState(() => _lines = newLines);
            if (_autoScroll && _lines.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollCtrl.hasClients) {
                  _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                }
              });
            }
          }
        }
      } catch (_) {}
    } finally {
      _fetching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initFailed) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          title: const Text('Server Logs', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: const Color(0xFF0D0D0D),
        ),
        body: const Center(
          child: Text('Failed to load preferences', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Server Logs', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF0D0D0D),
        actions: [
          IconButton(
            icon: Icon(_autoScroll ? Icons.lock : Icons.lock_open, color: Colors.grey),
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _doFetch,
          ),
        ],
      ),
      body: _lines.isEmpty
          ? const Center(
              child: Text('No logs yet', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(8),
              itemCount: _lines.length,
              itemBuilder: (_, i) => _LogLine(line: _lines[i]),
            ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final String line;
  const _LogLine({required this.line});

  Color _colorForLevel(String line) {
    if (line.contains('[ERROR]')) return Colors.red;
    if (line.contains('[WARNING]')) return Colors.orange;
    if (line.contains('[DEBUG]')) return Colors.grey;
    if (line.contains('[INFO]')) return Colors.white70;
    return Colors.white54;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text(
        line,
        style: TextStyle(
          color: _colorForLevel(line),
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.4,
        ),
      ),
    );
  }
}
