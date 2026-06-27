import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _serverUrlKey = 'server_url';
  static const _lastSeenKey = 'last_seen_timestamp';
  static const _lastRepoKey = 'last_repo';
  static const _lastBranchKey = 'last_branch';
  static const _lastModeKey = 'last_mode';
  static const _implementPromptKey = 'implement_prompt';
  static const _testPromptKey = 'test_prompt';
  static const _testEnabledKey = 'test_enabled';
  static const _auditPromptKey = 'audit_prompt';
  static const _auditEnabledKey = 'audit_enabled';

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
  static const defaultAuditPrompt = (
    "perform a thorough audit of the changes made\n"
    "verify all edge cases, error handling, and state management\n"
    "check for regressions, missing imports, and type safety\n"
    "ensure the implementation is complete and production-ready"
  );

  String get serverUrl => _prefs.getString(_serverUrlKey) ?? defaultUrl;
  String? get lastSeenTimestamp => _prefs.getString(_lastSeenKey);

  String get lastRepo => _prefs.getString(_lastRepoKey) ?? '';
  String get lastBranch => _prefs.getString(_lastBranchKey) ?? '';
  String get lastMode => _prefs.getString(_lastModeKey) ?? 'code';

  /// The implement prompt appended when the checkbox is checked.
  /// Falls back to defaultImplementPrompt when never customized.
  String get implementPrompt => _prefs.getString(_implementPromptKey) ?? defaultImplementPrompt;

  /// The test & debug prompt appended when the test checkbox is checked.
  /// Default is empty string — user writes their own.
  String get testPrompt => _prefs.getString(_testPromptKey) ?? '';
  bool get testEnabled => _prefs.getBool(_testEnabledKey) ?? false;

  String get auditPrompt => _prefs.getString(_auditPromptKey) ?? defaultAuditPrompt;
  bool get auditEnabled => _prefs.getBool(_auditEnabledKey) ?? false;

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

  Future<void> setTestPrompt(String prompt) async {
    await _prefs.setString(_testPromptKey, prompt);
  }

  Future<void> setTestEnabled(bool enabled) async {
    await _prefs.setBool(_testEnabledKey, enabled);
  }

  Future<void> setAuditPrompt(String prompt) async {
    await _prefs.setString(_auditPromptKey, prompt);
  }

  Future<void> setAuditEnabled(bool enabled) async {
    await _prefs.setBool(_auditEnabledKey, enabled);
  }

  bool get hasServerUrl => _prefs.getString(_serverUrlKey)?.isNotEmpty == true;
}
