import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_failure.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

Future<void> main(List<String> arguments) async {
  final Uri baseUri = _baseUri(arguments);
  final String token =
      Platform.environment['GONOW_RUNTIME_JOURNEY_TOKEN'] ?? '';
  if (token.isEmpty) {
    throw StateError('synthetic journey token is missing');
  }
  final http.Client httpClient = http.Client();
  try {
    final AgentRunRepository repository = DefaultAgentRunRepository(
      gateway: GeneratedAgentRunGateway(
        AgentApiClient(
          baseUri: baseUri,
          httpClient: httpClient,
          accessTokenProvider: () async => token,
          timeout: const Duration(seconds: 5),
        ),
      ),
      timeout: const Duration(seconds: 6),
    );
    final AgentRunResult<AgentApiContractReceipt> contract = await repository
        .verifyContract();
    if (contract is! AgentRunSuccess<AgentApiContractReceipt>) {
      throw StateError('contract verification failed');
    }
    final String threadId = const Uuid().v4();
    final AgentRunResult<StartAgentRunReceipt> started = await repository
        .startRun(
          StartAgentRunCommand(
            idempotencyKey: 'runtime-journey-${const Uuid().v4()}',
            threadId: threadId,
            origin: 'Shanghai',
            destination: 'Hangzhou',
            startsOn: '2026-08-03',
            days: 2,
            budgetMinor: 200000,
            currency: 'CNY',
            locale: 'zh-CN',
            timezone: 'Asia/Shanghai',
            hardConstraints: const <String>['no red-eye travel'],
          ),
        );
    if (started is! AgentRunSuccess<StartAgentRunReceipt>) {
      throw StateError('Run start failed');
    }
    final StartAgentRunReceipt run = started.value;
    ItineraryCandidateView? candidate;
    var attempts = 0;
    while (attempts < 100 && candidate == null) {
      attempts += 1;
      final AgentRunResult<AgentRunCandidateReceipt> result = await repository
          .getCandidate(run.runId);
      switch (result) {
        case AgentRunSuccess<AgentRunCandidateReceipt>(:final value):
          candidate = ItineraryCandidateView.fromJson(value.payload);
        case AgentRunRejected<AgentRunCandidateReceipt>(:final failure):
          if (failure.kind != AgentRunFailureKind.forbidden) {
            throw StateError('Candidate read failed: ${failure.kind.name}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (candidate == null) {
      throw TimeoutException('Candidate did not become readable');
    }
    stdout.writeln(
      jsonEncode(<String, Object>{
        'status': 'passed',
        'run_id': run.runId,
        'thread_id': run.threadId,
        'candidate_id': candidate.candidateId,
        'candidate_run_matches': candidate.runId == run.runId,
        'behavior_digest_matches':
            candidate.behaviorDigest == run.behaviorDigest,
        'candidate_read_attempts': attempts,
        'contract_sha256': contract.value.specSha256,
      }),
    );
  } finally {
    httpClient.close();
  }
}

Uri _baseUri(List<String> arguments) {
  const String prefix = '--base-url=';
  final String value = arguments
      .where((String item) => item.startsWith(prefix))
      .map((String item) => item.substring(prefix.length))
      .single;
  final Uri uri = Uri.parse(value);
  if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
    throw ArgumentError.value(value, 'base-url', 'loopback HTTP required');
  }
  return uri;
}
