class Task {
  final String id;
  final String prompt;
  final String repo;
  final String branch;
  final String mode;
  final String status;
  final String? conversationId;
  final String? sandboxId;
  final String createdAt;
  final String? completedAt;
  final String? errorMessage;

  const Task({
    required this.id,
    required this.prompt,
    required this.repo,
    required this.branch,
    required this.mode,
    required this.status,
    this.conversationId,
    this.sandboxId,
    required this.createdAt,
    this.completedAt,
    this.errorMessage,
  });

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: (json['id'] ?? '').toString(),
      prompt: (json['prompt'] ?? '').toString(),
      repo: (json['repo'] ?? '').toString(),
      branch: (json['branch'] ?? 'main').toString(),
      mode: (json['mode'] ?? 'code').toString(),
      status: (json['status'] ?? 'queued').toString(),
      conversationId: json['conversation_id']?.toString(),
      sandboxId: json['sandbox_id']?.toString(),
      createdAt: (json['created_at'] ?? '').toString(),
      completedAt: json['completed_at']?.toString(),
      errorMessage: json['error_message']?.toString(),
    );
  }

  bool get isRunning => status == 'running' || status == 'starting';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isQueued => status == 'queued';
}
