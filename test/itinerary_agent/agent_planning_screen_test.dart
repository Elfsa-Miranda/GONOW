import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/config/agent_service_config.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';
import 'package:gonow/features/itinerary_agent/presentation/screens/agent_planning_screen.dart';

const String _runId = '11111111-1111-4111-8111-111111111111';
const AgentServiceConfig _safeConfig = AgentServiceConfig(
  baseUrl: 'https://agent.gonow.example',
  planningEnabled: true,
  killSwitch: false,
  clientGeneration: 1,
  serverGeneration: 1,
);

void main() {
  testWidgets('start and Candidate refresh use the real repository surface', (
    WidgetTester tester,
  ) async {
    final _ScreenRepository repository = _ScreenRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: AgentPlanningScreen(config: _safeConfig, repository: repository),
      ),
    );

    await tester.enterText(find.byKey(const Key('agent-origin')), 'Beijing');
    await tester.enterText(
      find.byKey(const Key('agent-destination')),
      'Shanghai',
    );
    await tester.tap(find.byKey(const Key('agent-start-run')));
    await tester.pumpAndSettle();

    expect(repository.startCommands, hasLength(1));
    expect(repository.startCommands.single.destination, 'Shanghai');
    expect(find.byKey(const Key('agent-run-id')), findsOneWidget);

    final Finder refresh = find.byKey(const Key('agent-refresh-candidate'));
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    await tester.tap(refresh);
    await tester.pumpAndSettle();

    expect(repository.candidateReads, <String>[_runId]);
    expect(find.byKey(const Key('agent-candidate-preview')), findsOneWidget);
    expect(find.text('Candidate plan'), findsOneWidget);
    expect(find.text('Arrival'), findsOneWidget);
  });

  testWidgets('missing endpoint fails closed before client construction', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AgentPlanningScreen(
          config: AgentServiceConfig(
            baseUrl: '',
            planningEnabled: true,
            killSwitch: false,
            clientGeneration: 1,
            serverGeneration: 1,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('agent-configuration-error')), findsOneWidget);
    expect(find.byKey(const Key('agent-start-run')), findsNothing);
  });
}

final class _ScreenRepository implements AgentRunRepository {
  final List<StartAgentRunCommand> startCommands = <StartAgentRunCommand>[];
  final List<String> candidateReads = <String>[];

  @override
  Future<AgentRunResult<AgentApiContractReceipt>>
  verifyContract() async => const AgentRunSuccess<AgentApiContractReceipt>(
    AgentApiContractReceipt(
      name: 'agent-api',
      major: 1,
      version: '1.1.0',
      specSha256:
          'bc067228d99196391b9a0cdb9c687fadb5b0c2947418afe8687eca53e78e3fc0',
    ),
  );

  @override
  Future<AgentRunResult<StartAgentRunReceipt>> startRun(
    StartAgentRunCommand command,
  ) async {
    startCommands.add(command);
    return AgentRunSuccess<StartAgentRunReceipt>(
      StartAgentRunReceipt(
        runId: _runId,
        threadId: command.threadId,
        state: 'queued',
        version: 1,
        replayed: false,
        behaviorDigest: 'b' * 64,
      ),
    );
  }

  @override
  Future<AgentRunResult<AgentRunCandidateReceipt>> getCandidate(
    String runId,
  ) async {
    candidateReads.add(runId);
    return AgentRunSuccess<AgentRunCandidateReceipt>(
      AgentRunCandidateReceipt(runId: runId, payload: _candidateJson()),
    );
  }

  @override
  Future<AgentRunResult<CancelAgentRunReceipt>> cancelRun(
    CancelAgentRunCommand command,
  ) => throw UnimplementedError();

  @override
  Future<AgentRunResult<ResumeAgentRunReceipt>> resumeRun(
    ResumeAgentRunCommand command,
  ) => throw UnimplementedError();
}

Map<String, dynamic> _candidateJson() => <String, dynamic>{
  'schema_version': '1.0',
  'candidate_id': 'cand_11111111111111111111111111111111',
  'run_id': _runId,
  'behavior_digest': 'b' * 64,
  'input_digest': 'c' * 64,
  'title': 'Candidate plan',
  'days': <Object>[
    <String, dynamic>{
      'day_number': 1,
      'items': <Object>[
        <String, dynamic>{
          'item_id': 'item_arrival',
          'title': 'Arrival',
          'start_minute': 540,
          'duration_minutes': 60,
          'claim_ids': <String>[],
        },
      ],
    },
  ],
  'citations': <Object>[],
  'evidence_refs': <String>[],
  'status': 'candidate',
};
