import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibecode/providers/chat_provider.dart';
import 'package:vibecode/services/api_service.dart';

/// Full integration test: simulates send() + poll + merge cycle
/// and verifies message ordering without needing a screen.
void main() {
  test('single "hi!" — user msg appears before system and events', () async {
    final api = _TestApi();
    final prov = ChatProvider(api);
    prov.serverRepo = 'test/repo';
    prov.serverBranch = 'main';
    prov.serverMode = 'code';

    // Simulate send("hi!") → server queues it
    api._nextBatchResponse = {'status': 'queued', 'position': 0, 'total': 1};

    // First poll: before agent connects
    api._nextChatResponse = _makeChatResponse(
      conversationId: null,
      changeReason: 'Starting 1 new tasks',
      changeAt: '2026-07-06T14:28:03.797Z',
      position: 0, total: 1, done: 0, running: true,
      messages: [
        _msg('user', 'hi!', '2026-07-06T14:28:04.050Z', id: 1),
        _msg('event', '[STATUS] Agent is starting up... (0s)',
            '2026-07-06T14:28:04.050Z', id: 2),
      ],
    );

    // Second poll: agent connected, still processing
    api._nextChatResponse2 = _makeChatResponse(
      conversationId: 'test-conv-123',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T14:28:18.679Z',
      position: 0, total: 1, done: 0, running: true,
      messages: [
        _msg('user', 'hi!', '2026-07-06T14:28:04.050Z', id: 1),
        _msg('event', '[STATUS] Agent is starting up... (0s)',
            '2026-07-06T14:28:04.050Z', id: 2),
        _msg('event', '[STATUS] Working... (15s)',
            '2026-07-06T14:28:20.284Z', id: 3),
      ],
    );

    // Third poll: done
    api._nextChatResponse3 = _makeChatResponse(
      conversationId: 'test-conv-123',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T14:28:18.679Z',
      position: 1, total: 1, done: 1, running: false,
      messages: [
        _msg('user', 'hi!', '2026-07-06T14:28:04.050Z', id: 1),
        _msg('event', '[STATUS] Agent is starting up... (0s)',
            '2026-07-06T14:28:04.050Z', id: 2),
        _msg('event', '[TERMINAL] ls', '2026-07-06T14:28:30.190Z', id: 3),
        _msg('assistant', 'Hello!', '2026-07-06T14:29:02.233Z', id: 4),
      ],
    );

    // Trigger send — this starts the poll internally
    await prov.send('hi!', repo: 'test/repo', branch: 'main');

    // Let the poll tick run (it fires immediately, then schedules next)
    await Future.delayed(const Duration(milliseconds: 100));

    // Trigger second poll tick by setting up the response and waiting
    // for the self-rescheduling timer
    api._nextChatResponse = api._nextChatResponse2;
    await Future.delayed(const Duration(seconds: 3));
    // Third poll
    api._nextChatResponse = api._nextChatResponse3;
    await Future.delayed(const Duration(seconds: 4));

    // Now verify message ordering
    final msgs = prov.messages;
    print('\n=== MESSAGE ORDER (single "hi!") ===');
    for (final m in msgs) {
      final ts = DateTime.fromMillisecondsSinceEpoch(m.timestamp).toUtc().toIso8601String();
      print('  [${m.role.padRight(9)}] ts=$ts  ${m.content.substring(0, m.content.length.clamp(0, 70))}');
    }

    // Find the user message position
    final userIdx = msgs.indexWhere((m) => m.role == 'user' && m.content == 'hi!');
    final systemIdx = msgs.indexWhere((m) => m.role == 'system');
    final asstIdx = msgs.lastIndexWhere((m) => m.role == 'assistant');

    expect(userIdx, greaterThan(-1), reason: 'User message must exist');
    expect(asstIdx, greaterThan(-1), reason: 'Assistant reply must exist');

    // User message should come BEFORE assistant reply
    expect(userIdx, lessThan(asstIdx),
        reason: 'User "hi!" must appear before AI reply');

    // If there's a system message, it should be AFTER user (agent connects after user sends)
    if (systemIdx >= 0) {
      expect(userIdx, lessThan(systemIdx),
          reason: 'System "Agent connected" (ts=14:28:18) should be AFTER user "hi!" (ts=14:28:04)');
    }

    print('✅ User idx=$userIdx, System idx=$systemIdx, Asst idx=$asstIdx — ORDER CORRECT');
  });

  test('two messages — deferred insertion before merge sorts correctly', () async {
    final api = _TestApi();
    final prov = ChatProvider(api);
    prov.serverRepo = 'test/repo';
    prov.serverBranch = 'main';
    prov.serverMode = 'code';

    // Send msg 1 — starts batch
    api._nextBatchResponse = {'status': 'queued', 'position': 0, 'total': 1};

    // But we're appending — total becomes 2
    api._nextBatchResponse2 = {'status': 'appended', 'position': 0, 'total': 2};

    // Poll after msg 1 (before append)
    api._nextChatResponse = _makeChatResponse(
      conversationId: 'conv-456',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T15:00:00.000Z',
      position: 0, total: 1, done: 0, running: true,
      messages: [
        _msg('user', 'FIRST msg', '2026-07-06T15:00:01.000Z', id: 1),
        _msg('event', '[STATUS] Starting...', '2026-07-06T15:00:01.000Z', id: 2),
      ],
    );

    // Poll after msg 2 appended — agent processes msg 1, msg 2 deferred
    api._nextChatResponse2_chat = _makeChatResponse(
      conversationId: 'conv-456',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T15:00:00.000Z',
      position: 0, total: 2, done: 0, running: true,
      messages: [
        _msg('user', 'FIRST msg', '2026-07-06T15:00:01.000Z', id: 1),
        _msg('event', '[STATUS] Starting...', '2026-07-06T15:00:01.000Z', id: 2),
        _msg('event', '[TERMINAL] ls', '2026-07-06T15:00:10.000Z', id: 3),
        _msg('assistant', 'Done with first!', '2026-07-06T15:00:20.000Z', id: 4),
      ],
    );

    // Poll after msg 1 done, msg 2 starts
    api._nextChatResponse3 = _makeChatResponse(
      conversationId: 'conv-456',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T15:00:00.000Z',
      position: 1, total: 2, done: 1, running: true,
      messages: [
        _msg('user', 'FIRST msg', '2026-07-06T15:00:01.000Z', id: 1),
        _msg('user', 'SECOND msg', '2026-07-06T15:00:05.000Z', id: 5),
        _msg('event', '[STATUS] Starting...', '2026-07-06T15:00:01.000Z', id: 2),
        _msg('event', '[TERMINAL] ls', '2026-07-06T15:00:10.000Z', id: 3),
        _msg('assistant', 'Done with first!', '2026-07-06T15:00:20.000Z', id: 4),
      ],
    );

    // Final poll: both done
    api._nextChatResponse4 = _makeChatResponse(
      conversationId: 'conv-456',
      changeReason: 'Agent connected',
      changeAt: '2026-07-06T15:00:00.000Z',
      position: 2, total: 2, done: 2, running: false,
      messages: [
        _msg('user', 'FIRST msg', '2026-07-06T15:00:01.000Z', id: 1),
        _msg('user', 'SECOND msg', '2026-07-06T15:00:05.000Z', id: 5),
        _msg('event', '[STATUS] Starting...', '2026-07-06T15:00:01.000Z', id: 2),
        _msg('assistant', 'Done with first!', '2026-07-06T15:00:20.000Z', id: 4),
        _msg('assistant', 'Done with second!', '2026-07-06T15:01:00.000Z', id: 6),
      ],
    );

    // Send first message
    await prov.send('FIRST msg', repo: 'test/repo', branch: 'main');
    await Future.delayed(const Duration(milliseconds: 100));

    // Send second message (appended)
    api._nextBatchResponse = api._nextBatchResponse2;
    api._nextChatResponse = api._nextChatResponse2_chat;
    await prov.send('SECOND msg', repo: 'test/repo', branch: 'main');
    await Future.delayed(const Duration(milliseconds: 100));

    // Let polls run
    api._nextChatResponse = api._nextChatResponse3;
    await Future.delayed(const Duration(seconds: 3));
    api._nextChatResponse = api._nextChatResponse4;
    await Future.delayed(const Duration(seconds: 4));

    final msgs = prov.messages;
    print('\n=== MESSAGE ORDER (two msgs, second deferred) ===');
    for (final m in msgs) {
      final ts = DateTime.fromMillisecondsSinceEpoch(m.timestamp).toUtc().toIso8601String();
      print('  [${m.role.padRight(9)}] ts=$ts  ${m.content.substring(0, m.content.length.clamp(0, 70))}');
    }

    // Find both user messages
    final firstIdx = msgs.indexWhere((m) => m.content == 'FIRST msg');
    final secondIdx = msgs.indexWhere((m) => m.content == 'SECOND msg');
    final asst1 = msgs.indexWhere((m) => m.content == 'Done with first!');
    final asst2 = msgs.indexWhere((m) => m.content == 'Done with second!');

    expect(firstIdx, greaterThan(-1));
    expect(secondIdx, greaterThan(-1));
    expect(asst1, greaterThan(-1));
    expect(asst2, greaterThan(-1));

    // Chronological order: FIRST (15:00:01) < SECOND (15:00:05) < asst1 (15:00:20) < asst2 (15:01:00)
    expect(firstIdx, lessThan(secondIdx),
        reason: 'FIRST msg must appear before SECOND msg');
    expect(secondIdx, lessThan(asst2),
        reason: 'SECOND msg must appear before its reply');
    expect(asst1, lessThan(asst2),
        reason: 'First reply before second reply');

    print('✅ FIRST=$firstIdx SECOND=$secondIdx asst1=$asst1 asst2=$asst2 — ORDER CORRECT');
  });
}

// -- Test helpers --

Map<String, dynamic> _makeChatResponse({
  String? conversationId,
  required String changeReason,
  required String changeAt,
  required int position, required int total, required int done,
  required bool running,
  required List<Map<String, dynamic>> messages,
}) {
  return {
    'messages': messages,
    'conversation_id': conversationId,
    'sandbox_id': null,
    'repo': 'test/repo',
    'branch': 'main',
    'mode': 'code',
    'current_repo_key': 'test/repo',
    'conversation_status': running ? 'running' : 'idle',
    'llm_model': 'test-model',
    'conversation_change': {
      'reason': changeReason,
      'at': changeAt,
    },
    'batch': {
      'running': running,
      'cancelled': false,
      'position': position,
      'total': total,
      'done': done,
      'repo': 'test/repo',
      'prompts': <String>[],
      'modes': <String>[],
    },
  };
}

Map<String, dynamic> _msg(String role, String content, String isoUtc, {int? id}) {
  final ts = DateTime.parse(isoUtc).millisecondsSinceEpoch;
  final m = <String, dynamic>{
    'role': role,
    'content': content,
    'timestamp': ts,
  };
  if (id != null) m['id'] = id;
  return m;
}

/// Mock API that returns pre-configured responses.
class _TestApi extends ApiService {
  Map<String, dynamic>? _nextBatchResponse;
  Map<String, dynamic>? _nextBatchResponse2;
  Map<String, dynamic>? _nextChatResponse;
  Map<String, dynamic>? _nextChatResponse2;
  Map<String, dynamic>? _nextChatResponse3;
  Map<String, dynamic>? _nextChatResponse4;
  Map<String, dynamic>? _nextChatResponse2_chat;
  int _chatCallCount = 0;
  int _batchCallCount = 0;

  @override
  Future<Map<String, dynamic>> sendChatBatch({
    required List<String> prompts,
    String repo = '',
    String branch = '',
    String mode = 'code',
  }) async {
    _batchCallCount++;
    if (_batchCallCount == 2 && _nextBatchResponse2 != null) {
      return Map<String, dynamic>.from(_nextBatchResponse2!);
    }
    return Map<String, dynamic>.from(_nextBatchResponse ?? {
      'status': 'queued', 'position': 0, 'total': 1,
    });
  }

  @override
  Future<Map<String, dynamic>> getChat({
    String repo = '',
    String mode = '',
  }) async {
    _chatCallCount++;
    final responses = [
      _nextChatResponse,
      _nextChatResponse2,
      _nextChatResponse2_chat,
      _nextChatResponse3,
      _nextChatResponse4,
    ];
    // Use the appropriate response based on call count (skip nulls)
    for (final r in responses) {
      if (r != null && _chatCallCount > 0) {
        // Simple round-robin through non-null responses
        final nonNull = responses.where((x) => x != null).toList();
        final idx = (_chatCallCount - 1) % nonNull.length;
        return Map<String, dynamic>.from(nonNull[idx]!);
      }
    }
    return Map<String, dynamic>.from(_nextChatResponse ?? {
      'messages': <Map<String, dynamic>>[],
      'batch': {'position': 0, 'total': 0, 'done': 0, 'running': false},
    });
  }

  @override
  Future<List<Map<String, dynamic>>> getChatRepos() async => [];
}
