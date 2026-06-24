import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _serverUrlKey = 'server_url';
  static const _lastSeenKey = 'last_seen_timestamp';
  static const _lastRepoKey = 'last_repo';
  static const _lastBranchKey = 'last_branch';
  static const _lastModeKey = 'last_mode';
  static const _implementPromptKey = 'implement_prompt';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static const defaultUrl = 'http://34.44.82.227:8080';
  static const defaultImplementPrompt = (
    "a full codebase audit, comprehensive enough\n"
    "robust catch all debug logging without any missing cases no matter how edge it was\n"
    "100 possibilities of sub use cases like: how about if the user pressed cancel before xxx? how about xxx? make sure all the sub use cases are also considered, whole flow zero issues\n"
    "\n"
    "full codebase view and search all potential possibilities is main requirement"
  );

  String get serverUrl => _prefs.getString(_serverUrlKey) ?? defaultUrl;
  String? get lastSeenTimestamp => _prefs.getString(_lastSeenKey);

  String get lastRepo => _prefs.getString(_lastRepoKey) ?? '';
  String get lastBranch => _prefs.getString(_lastBranchKey) ?? '';
  String get lastMode => _prefs.getString(_lastModeKey) ?? 'code';

  /// The implement prompt appended when the checkbox is checked.
  /// Falls back to defaultImplementPrompt when never customized.
  String get implementPrompt => _prefs.getString(_implementPromptKey) ?? defaultImplementPrompt;

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

  Future<void> setImplementPrompt(String prompt) async {
    await _prefs.setString(_implementPromptKey, prompt);
  }

  bool get hasServerUrl => _prefs.getString(_serverUrlKey)?.isNotEmpty == true;
}
