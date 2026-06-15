import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _serverUrlKey = 'server_url';
  static const _lastSeenKey = 'last_seen_timestamp';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String? get serverUrl => _prefs.getString(_serverUrlKey);
  String? get lastSeenTimestamp => _prefs.getString(_lastSeenKey);

  Future<void> setServerUrl(String url) async {
    await _prefs.setString(_serverUrlKey, url);
  }

  Future<void> setLastSeenTimestamp(String ts) async {
    await _prefs.setString(_lastSeenKey, ts);
  }

  bool get hasServerUrl => _prefs.containsKey(_serverUrlKey);
}
