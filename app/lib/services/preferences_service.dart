import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _serverUrlKey = 'server_url';
  static const _lastSeenKey = 'last_seen_timestamp';
  static const _lastRepoKey = 'last_repo';
  static const _lastBranchKey = 'last_branch';
  static const _lastModeKey = 'last_mode';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static const defaultUrl = 'http://34.44.82.227:8080';

  String get serverUrl => _prefs.getString(_serverUrlKey) ?? defaultUrl;
  String? get lastSeenTimestamp => _prefs.getString(_lastSeenKey);

  String get lastRepo => _prefs.getString(_lastRepoKey) ?? '';
  String get lastBranch => _prefs.getString(_lastBranchKey) ?? 'main';
  String get lastMode => _prefs.getString(_lastModeKey) ?? 'code';

  Future<void> setServerUrl(String url) async {
    await _prefs.setString(_serverUrlKey, url);
  }

  Future<void> setLastSeenTimestamp(String ts) async {
    await _prefs.setString(_lastSeenKey, ts);
  }

  Future<void> clearLastSeenTimestamp() async {
    await _prefs.remove(_lastSeenKey);
  }

  Future<void> saveLastPrompt(String repo, String branch, String mode) async {
    await Future.wait([
      _prefs.setString(_lastRepoKey, repo),
      _prefs.setString(_lastBranchKey, branch),
      _prefs.setString(_lastModeKey, mode),
    ]);
  }

  bool get hasServerUrl => true;
}
