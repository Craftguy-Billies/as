import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/preferences_service.dart';

class SettingsProvider extends ChangeNotifier {
  final ApiService _api;
  final PreferencesService _prefs;

  String? _serverUrl;
  bool _testing = false;
  bool? _connected;
  String? _modelName;

  SettingsProvider(this._api, this._prefs) {
    _serverUrl = _prefs.serverUrl;
    if (_serverUrl != null) {
      _api.setBaseUrl(_serverUrl!);
      // Auto-test connection so isSetup returns true without user tapping "Connect" again
      debugPrint('[SETTINGS] Server URL found, auto-testing connection...');
      WidgetsBinding.instance.addPostFrameCallback((_) => testConnection());
    }
  }

  String? get serverUrl => _serverUrl;
  bool get testing => _testing;
  bool? get connected => _connected;
  String? get modelName => _modelName;
  bool get isSetup => _prefs.hasServerUrl && _connected == true;

  Future<void> setServerUrl(String url) async {
    _serverUrl = url.trim();
    _api.setBaseUrl(_serverUrl!);
    await _prefs.setServerUrl(_serverUrl!);
    notifyListeners();
  }

  Future<bool> testConnection() async {
    _testing = true;
    _connected = null;
    notifyListeners();

    _connected = await _api.testConnection();
    if (_connected == true) {
      final health = await _api.health();
      _modelName = health?['model'] as String?;
    }

    _testing = false;
    notifyListeners();
    return _connected == true;
  }

  Future<void> updateLlmConfig({
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    await _api.updateLlmConfig(
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
    );
    _modelName = model;
    notifyListeners();
  }
}
