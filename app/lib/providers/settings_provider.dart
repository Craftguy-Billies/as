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

  SettingsProvider(this._api, this._prefs) {
    _serverUrl = _prefs.serverUrl;
    _api.setBaseUrl(_serverUrl!);
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
    _api.setBaseUrl(_serverUrl!);
    await _prefs.setServerUrl(_serverUrl!);
    notifyListeners();
  }

  Future<bool> testConnection() async {
    if (_testing) return _connected == true;
    _testing = true;
    _connected = null;
    notifyListeners();

    try {
      _connected = await _api.testConnection().timeout(const Duration(seconds: 10));
    } catch (_) {
      _connected = false;
    }

    if (_connected == true) {
      try {
        final health = await _api.health();
        _modelName = health?['model'] as String?;
      } catch (_) {}
      // Load git config from server
      try {
        final git = await _api.getGitConfig();
        if (git != null) {
          _gitName = git['name'] as String?;
          _gitEmail = git['email'] as String?;
        }
      } catch (_) {}
    }

    _testing = false;
    notifyListeners();
    return _connected == true;
  }

  void markDisconnected() {
    _connected = false;
    _testing = false;
    notifyListeners();
  }

  Future<void> updateLlmConfig({
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    try {
      await _api.updateLlmConfig(
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
      );
      _modelName = model;
      // Persist model name for chat subtitle
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
