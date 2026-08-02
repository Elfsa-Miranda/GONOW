final class StartAgentRunCommand {
  const StartAgentRunCommand({
    required this.idempotencyKey,
    required this.threadId,
    required this.origin,
    required this.destination,
    required this.startsOn,
    required this.days,
    required this.budgetMinor,
    required this.currency,
    required this.locale,
    required this.timezone,
    required this.hardConstraints,
  });

  final String idempotencyKey;
  final String threadId;
  final String origin;
  final String destination;
  final String startsOn;
  final int days;
  final int budgetMinor;
  final String currency;
  final String locale;
  final String timezone;
  final List<String> hardConstraints;
}

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
