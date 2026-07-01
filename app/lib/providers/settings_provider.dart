import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';

class SettingsProvider extends ChangeNotifier {
  final ApiService _api;
  final PreferencesService _prefs;

  String? _serverUrl;
  bool _testing = false;
  bool? _connected;
  String? _modelName;
  String? _gitName;
  String? _gitEmail;

  // Guards against concurrent testConnection() calls.
  // When a test is in-flight, concurrent callers await the same future
  // instead of racing.
  Future<bool>? _testInProgress;

  SettingsProvider(this._api, this._prefs) {
    _serverUrl = _prefs.serverUrl;
    _api.setBaseUrl(_serverUrl ?? '');
    debugPrint('[CONN] SettingsProvider created, serverUrl=$_serverUrl');
  }

  String get serverUrl => _serverUrl ?? '';
  String? get serverUrlNullable => _serverUrl;
  bool get testing => _testing;
  bool? get connected => _connected;
  String? get modelName => _modelName;
  String? get gitName => _gitName;
  String? get gitEmail => _gitEmail;
  bool get isSetup => _prefs.hasServerUrl && _connected == true;

  Future<void> setServerUrl(String url) async {
    _serverUrl = url.trim();
    _api.setBaseUrl(_serverUrl ?? '');
    await _prefs.setServerUrl(_serverUrl ?? '');
    notifyListeners();
  }

  Future<bool> testConnection() async {
    // Dedup concurrent callers — if a test is already running, await it
    if (_testInProgress != null) {
      debugPrint('[CONN] testConnection() already in-flight, awaiting...');
      return _testInProgress!;
    }

    _testInProgress = _runTestConnection();
    final result = await _testInProgress;
    _testInProgress = null;
    debugPrint('[CONN] testConnection() result=$result');
    return result ?? false;
  }

  Future<bool> _runTestConnection() async {
    _testing = true;
    _connected = null;
    notifyListeners();
    debugPrint('[CONN] _runTestConnection() starting...');

    try {
      _connected = await _api.testConnection().timeout(const Duration(seconds: 10));
      debugPrint('[CONN] _runTestConnection() connected=$_connected');
    } catch (e) {
      debugPrint('[CONN] _runTestConnection() threw: $e');
      _connected = false;
    }

    if (_connected == true) {
      try {
        final health = await _api.health();
        _modelName = health?['model'] as String?;
        debugPrint('[CONN] health model=$_modelName');
      } catch (e) {
        debugPrint('[CONN] health() failed (non-fatal): $e');
      }
      // Load git config from server
      try {
        final git = await _api.getGitConfig();
        if (git != null) {
          _gitName = git['name'] as String?;
          _gitEmail = git['email'] as String?;
          debugPrint('[CONN] git config: name=$_gitName email=$_gitEmail');
        }
      } catch (e) {
        debugPrint('[CONN] getGitConfig() failed (non-fatal): $e');
      }
    }

    _testing = false;
    notifyListeners();
    debugPrint('[CONN] _runTestConnection() done, _connected=$_connected');
    return _connected == true;
  }

  void markDisconnected() {
    _connected = false;
    _testing = false;
    notifyListeners();
  }

  Future<void> updateLlmConfig({required String model}) async {
    try {
      await _api.updateLlmConfig(model: model);
      _modelName = model;
      // Persist model name so chat screen can show it immediately
      final sp = await SharedPreferences.getInstance();
      await sp.setString('last_model', model);
      notifyListeners();
    } catch (e) {
      throw Exception('Failed to update LLM config: $e');
    }
  }

  Future<void> updateGitConfig({
    required String name,
    required String email,
  }) async {
    await _api.updateGitConfig(name: name, email: email);
    _gitName = name;
    _gitEmail = email;
    notifyListeners();
  }
}
