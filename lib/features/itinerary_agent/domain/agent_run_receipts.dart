final class AgentApiContractReceipt {
  const AgentApiContractReceipt({
    required this.name,
    required this.major,
    required this.version,
    required this.specSha256,
  });

  final String name;
  final int major;
  final String version;
  final String specSha256;
}

final class StartAgentRunReceipt {
  const StartAgentRunReceipt({
    required this.runId,
    required this.threadId,
    required this.state,
    required this.version,
    required this.replayed,
    required this.behaviorDigest,
  });

  final String runId;
  final String threadId;
  final String state;
  final int version;
  final bool replayed;
  final String behaviorDigest;
}

final class AgentRunCandidateReceipt {
  AgentRunCandidateReceipt({
    required this.runId,
    required Map<String, dynamic> payload,
  }) : payload = Map<String, dynamic>.unmodifiable(payload);

  final String runId;
  final Map<String, dynamic> payload;
}

final class ResumeAgentRunReceipt {
  const ResumeAgentRunReceipt({
    required this.runId,
    required this.interruptId,
    required this.commandVersion,
  });

  final String runId;
  final String interruptId;
  final String commandVersion;
}

final class CancelAgentRunReceipt {
  const CancelAgentRunReceipt({
    required this.status,
    required this.runId,
    required this.version,
    required this.replayed,
  });

  final String status;
  final String runId;
  final int version;
  final bool replayed;
}
