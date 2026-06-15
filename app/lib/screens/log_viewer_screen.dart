import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/preferences_service.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _scrollCtrl = ScrollController();
  final _prefs = PreferencesService();
  List<String> _lines = [];
  bool _autoScroll = true;
  Timer? _timer;
  bool _init = false;

  @override
  void initState() {
    super.initState();
    _prefs.init().then((_) {
      _init = true;
      _fetch();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetch());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (!_init) return;
    try {
      final resp = await http
          .get(Uri.parse('${_prefs.serverUrl}/api/logs'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final newLines = (data['lines'] as List).cast<String>();
        if (mounted) {
          setState(() => _lines = newLines);
          if (_autoScroll && _lines.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _fetch,
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
