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
