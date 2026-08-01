final class ResumeAgentRunCommand {
  const ResumeAgentRunCommand({
    required this.runId,
    required this.resumeToken,
    required this.interruptId,
    required this.commandHash,
    required this.commandVersion,
  });

  final String runId;
  final String resumeToken;
  final String interruptId;
  final String commandHash;
  final String commandVersion;

  @override
  String toString() =>
      'ResumeAgentRunCommand(runId=$runId, interruptId=$interruptId, commandVersion=$commandVersion, resumeToken=[REDACTED])';
}

final class CancelAgentRunCommand {
  const CancelAgentRunCommand({
    required this.runId,
    required this.expectedVersion,
  });

  final String runId;
  final int expectedVersion;
}
