import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/config/agent_feature_flags.dart';
import 'package:gonow/features/itinerary_agent/data/active_run_store.dart';
import 'package:gonow/features/itinerary_agent/data/agent_control_client.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';
import 'package:gonow/features/itinerary_agent/presentation/controllers/candidate_decision_controller.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';

const String _runId = '11111111-1111-4111-8111-111111111111';
const String _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test(
    'create -> interrupt -> resume -> cancel -> adopt conflict -> flag off',
    () async {
      final _MemoryBackend backend = _MemoryBackend();
      final ActiveRunStore store = ActiveRunStore(
        backend: backend,
        accountScopeSha256: _scope,
      );
      await store.save(
        const ActiveRunReference(runId: _runId, lastEventId: 2, version: 1),
      );
      final _JourneyRepository repository = _JourneyRepository();
      final AgentControlClient control = AgentControlClient(
        repository: repository,
        auditSink: _ControlAuditSink(),
      );

      final AgentControlOutcome<ResumeAgentRunReceipt> resumed = await control
          .resume(
            runId: _runId,
            capability: OneUseResumeCapability('opaque-one-use-capability'),
            interruptId: '22222222-2222-4222-8222-222222222222',
            commandHash: 'b' * 64,
            commandVersion: '1.0',
          );
      final AgentControlOutcome<CancelAgentRunReceipt> cancelled = await control
          .cancel(runId: _runId, expectedVersion: 1);
      final CandidateDecisionController candidate = _candidateController();
      candidate
        ..setReviewAcknowledged(true)
        ..setConflictAcknowledged(true);
      final CandidateDecisionReceipt adoption = await candidate
          .requestAdoption();
      final AgentRouteDecision rollback = const AgentFeatureFlags().evaluate(
        AgentEntryKind.itineraryPlanning,
        agentRouteAvailable: true,
      );

      expect((await store.read())?.lastEventId, 2);
      expect(resumed.result, isA<AgentRunSuccess<ResumeAgentRunReceipt>>());
      expect(cancelled.result, isA<AgentRunSuccess<CancelAgentRunReceipt>>());
      expect(adoption.kind, CandidateDecisionKind.requestAdoption);
      expect(repository.resumeCommands, hasLength(1));
      expect(repository.cancelCommands, hasLength(1));
      expect(rollback.route, AgentPlanningRoute.legacy);
    },
  );

  test('adopt conflict stays pending until both acknowledgements', () async {
    final CandidateDecisionController candidate = _candidateController();

    await expectLater(
      candidate.requestAdoption(),
      throwsA(isA<CandidateDecisionException>()),
    );
    candidate.setReviewAcknowledged(true);
    expect(candidate.canRequestAdoption, isFalse);
    candidate.setConflictAcknowledged(true);
    expect(candidate.canRequestAdoption, isTrue);
    await candidate.requestAdoption();
    expect(candidate.state, CandidateDecisionState.adoptionRequested);
  });

  test('old path remains available when flag off without Agent control', () {
    final _JourneyRepository repository = _JourneyRepository();
    final AgentRouteDecision decision = const AgentFeatureFlags().evaluate(
      AgentEntryKind.itineraryPlanning,
      agentRouteAvailable: true,
    );

    expect(decision.route, AgentPlanningRoute.legacy);
    expect(decision.reasonCode, 'kill_switch_active');
    expect(repository.resumeCommands, isEmpty);
    expect(repository.cancelCommands, isEmpty);
  });
}

CandidateDecisionController _candidateController() =>
    CandidateDecisionController(
      preview: CandidatePreviewModel(
        candidate: ItineraryCandidateView.fromJson(_candidateJson()),
        current: const CurrentItinerarySnapshot(
          version: 2,
          title: 'Existing plan',
          items: <CurrentItineraryItem>[],
        ),
        expectedVersion: 1,
      ),
      auditSink: _CandidateAuditSink(),
    );

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

final class _MemoryBackend implements ActiveRunKeyValueBackend {
  final Map<String, String> values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }
}

final class _ControlAuditSink implements AgentControlAuditSink {
  @override
  Future<String> record(AgentControlAuditEvent event) async =>
      'control-audit-receipt';
}

final class _CandidateAuditSink implements CandidateDecisionAuditSink {
  @override
  Future<String> record(CandidateDecisionAuditEvent event) async =>
      'candidate-audit-receipt';
}

final class _JourneyRepository implements AgentRunRepository {
  final List<ResumeAgentRunCommand> resumeCommands = <ResumeAgentRunCommand>[];
  final List<CancelAgentRunCommand> cancelCommands = <CancelAgentRunCommand>[];

  @override
  Future<AgentRunResult<ResumeAgentRunReceipt>> resumeRun(
    ResumeAgentRunCommand command,
  ) async {
    resumeCommands.add(command);
    return AgentRunSuccess<ResumeAgentRunReceipt>(
      ResumeAgentRunReceipt(
        runId: command.runId,
        interruptId: command.interruptId,
        commandVersion: command.commandVersion,
      ),
    );
  }

  @override
  Future<AgentRunResult<CancelAgentRunReceipt>> cancelRun(
    CancelAgentRunCommand command,
  ) async {
    cancelCommands.add(command);
    return AgentRunSuccess<CancelAgentRunReceipt>(
      CancelAgentRunReceipt(
        status: 'cancelling',
        runId: command.runId,
        version: command.expectedVersion + 1,
        replayed: false,
      ),
    );
  }

  @override
  Future<AgentRunResult<AgentApiContractReceipt>> verifyContract() async =>
      const AgentRunSuccess<AgentApiContractReceipt>(
        AgentApiContractReceipt(
          name: 'agent-api',
          major: 1,
          version: '1.0.0',
          specSha256:
              'ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed',
        ),
      );
}
