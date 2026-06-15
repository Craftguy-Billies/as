class AgentEvent {
  final int id;
  final String taskId;
  final int eventIndex;
  final String timestamp;
  final String kind;
  final String? source;
  final String? toolName;
  final String? actionJson;
  final String? observationJson;
  final String? messageJson;

  const AgentEvent({
    required this.id,
    required this.taskId,
    required this.eventIndex,
    required this.timestamp,
    required this.kind,
    this.source,
    this.toolName,
    this.actionJson,
    this.observationJson,
    this.messageJson,
  });

  factory AgentEvent.fromJson(Map<String, dynamic> json) {
    return AgentEvent(
      id: json['id'] as int,
      taskId: json['task_id'] as String,
      eventIndex: json['event_index'] as int,
      timestamp: json['timestamp'] as String,
      kind: json['kind'] as String,
      source: json['source'] as String?,
      toolName: json['tool_name'] as String?,
      actionJson: json['action_json'] as String?,
      observationJson: json['observation_json'] as String?,
      messageJson: json['message_json'] as String?,
    );
  }

  bool get isUserMessage =>
      kind == 'MessageEvent' && source == 'user';
  bool get isAgentMessage =>
      kind == 'MessageEvent' && (source == 'agent' || source == 'assistant');
  bool get isTerminalAction =>
      kind == 'ActionEvent' && toolName == 'terminal';
  bool get isFileEditAction =>
      kind == 'ActionEvent' && (toolName == 'file_editor' || toolName == 'str_replace_editor');
  bool get isSearchAction =>
      kind == 'ActionEvent' && (toolName == 'tavily_search' || toolName == 'tavily_tavily_search');
  bool get isObservation =>
      kind == 'ObservationEvent';
  bool get isError =>
      kind == 'ErrorEvent';
}
