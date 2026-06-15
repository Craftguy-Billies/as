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
  final String? rawJson;

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
    this.rawJson,
  });

  factory AgentEvent.fromJson(Map<String, dynamic> json) {
    return AgentEvent(
      id: (json['id'] ?? 0) as int,
      taskId: (json['task_id'] ?? '').toString(),
      eventIndex: (json['event_index'] ?? 0) as int,
      timestamp: (json['timestamp'] ?? '').toString(),
      kind: (json['kind'] ?? 'Unknown').toString(),
      source: json['source']?.toString(),
      toolName: json['tool_name']?.toString(),
      actionJson: json['action_json']?.toString(),
      observationJson: json['observation_json']?.toString(),
      messageJson: json['message_json']?.toString(),
      rawJson: json['raw_json']?.toString(),
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
