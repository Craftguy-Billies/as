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
      id: json['id'] as String,
      prompt: json['prompt'] as String,
      repo: json['repo'] as String,
      branch: json['branch'] as String? ?? 'main',
      mode: json['mode'] as String? ?? 'code',
      status: json['status'] as String,
      conversationId: json['conversation_id'] as String?,
      sandboxId: json['sandbox_id'] as String?,
      createdAt: json['created_at'] as String,
      completedAt: json['completed_at'] as String?,
      errorMessage: json['error_message'] as String?,
    );
  }

  bool get isRunning => status == 'running' || status == 'starting';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isQueued => status == 'queued';
}
