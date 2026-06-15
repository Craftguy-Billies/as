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
    _api.setBaseUrl(_serverUrl!);
  }

  String get serverUrl => _serverUrl ?? '';
  String? get serverUrlNullable => _serverUrl;
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
      notifyListeners();
    } catch (e) {
      throw Exception('Failed to update LLM config: $e');
    }
  }
}
