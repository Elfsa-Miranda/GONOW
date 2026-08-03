import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/core/config/agent_feature_flags.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture =
        jsonDecode(
              File(
                'test/fixtures/compatibility/client-service-matrix-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
  });

  test('4/4 old and new client service paths remain compatible', () async {
    final Map<String, dynamic> services = Map<String, dynamic>.from(
      fixture['services'] as Map,
    );
    final List<dynamic> matrix = fixture['matrix'] as List<dynamic>;
    int passed = 0;

    for (final dynamic rawCase in matrix) {
      final Map<String, dynamic> compatibilityCase = Map<String, dynamic>.from(
        rawCase as Map,
      );
      final String caseId = compatibilityCase['case_id'] as String;
      final bool isOldApp = compatibilityCase['client_id'] == 'old_app';
      final AgentPlanningRoute actualRoute;
      if (isOldApp) {
        actualRoute = const AgentFeatureFlags()
            .evaluate(
              AgentEntryKind.itineraryPlanning,
              agentRouteAvailable: false,
            )
            .route;
      } else {
        final Map<String, dynamic> service = Map<String, dynamic>.from(
          services[compatibilityCase['service_id']] as Map,
        );
        final Map<String, dynamic> descriptor = Map<String, dynamic>.from(
          service['descriptor'] as Map,
        );
        var available = false;
        try {
          final AgentRunResult<Object> contract =
              await DefaultAgentRunRepository(
                gateway: _DescriptorGateway(
                  ContractDescriptor.fromJson(descriptor),
                ),
              ).verifyContract();
          available = contract is AgentRunSuccess<Object>;
        } on AgentApiProtocolException {
          available = false;
        }
        actualRoute =
            const AgentFeatureFlags(
                  itineraryPlanningEnabled: true,
                  itineraryPlanningKillSwitch: false,
                  clientGeneration: 1,
                  serverGeneration: 1,
                )
                .evaluate(
                  AgentEntryKind.itineraryPlanning,
                  agentRouteAvailable: available,
                )
                .route;
      }
      expect(
        actualRoute.name,
        compatibilityCase['expected_route'],
        reason: caseId,
      );
      passed += 1;
    }

    expect(passed, 4);
    expect(
      matrix.map((dynamic item) => (item as Map)['case_id']).toSet(),
      <String>{
        'old_app_old_service',
        'old_app_new_service',
        'new_app_old_service',
        'new_app_new_service',
      },
    );
  });

  test('contract and route failures return to the old route safely', () async {
    const AgentFeatureFlags enabled = AgentFeatureFlags(
      itineraryPlanningEnabled: true,
      itineraryPlanningKillSwitch: false,
      clientGeneration: 1,
      serverGeneration: 1,
    );
    final AgentRunResult<Object>
    digestMismatch = await DefaultAgentRunRepository(
      gateway: const _DescriptorGateway(
        ContractDescriptor(
          name: 'agent-api',
          major: 1,
          version: '1.1.1',
          specSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
      ),
    ).verifyContract();
    final AgentRunResult<Object> serviceUnavailable =
        await DefaultAgentRunRepository(
          gateway: const _UnavailableGateway(),
        ).verifyContract();

    expect(digestMismatch, isA<AgentRunRejected<Object>>());
    expect(serviceUnavailable, isA<AgentRunRejected<Object>>());
    expect(
      enabled
          .evaluate(
            AgentEntryKind.itineraryPlanning,
            agentRouteAvailable: false,
          )
          .route,
      AgentPlanningRoute.legacy,
    );
    expect(
      const AgentFeatureFlags(
            itineraryPlanningEnabled: true,
            itineraryPlanningKillSwitch: false,
            clientGeneration: 1,
            serverGeneration: 0,
          )
          .evaluate(AgentEntryKind.itineraryPlanning, agentRouteAvailable: true)
          .reasonCode,
      'generation_mismatch',
    );
  });

  test(
    'fixtures record contract evolution and forbid forced upgrade or deletion',
    () {
      final Map<String, dynamic> services = Map<String, dynamic>.from(
        fixture['services'] as Map,
      );

      expect(fixture['failure_cases'], hasLength(3));
      expect(fixture['forced_upgrade_count'], 0);
      expect(fixture['adapter_delete_count'], 0);
      expect(fixture['contract_change'], isTrue);
      expect(fixture['production_write_count'], 0);
      expect(
        services.values.every(
          (dynamic service) => (service as Map)['candidate_only'] == true,
        ),
        isTrue,
      );
    },
  );
}

class _DescriptorGateway implements AgentRunGateway {
  const _DescriptorGateway(this.descriptor);

  final ContractDescriptor descriptor;

  @override
  Future<ContractDescriptor> getContractDescriptor() async => descriptor;

  @override
  Future<RunStartResponse> startRun({
    required String idempotencyKey,
    required RunStartRequest request,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getRunCandidate({required String runId}) =>
      throw UnimplementedError();

  @override
  Future<CancelResponse> cancelRun({
    required String runId,
    required CancelRequest request,
  }) => throw UnimplementedError();

  @override
  Future<ResumeResponse> resumeRun({
    required String runId,
    required ResumeRequest request,
  }) => throw UnimplementedError();
}

class _UnavailableGateway implements AgentRunGateway {
  const _UnavailableGateway();

  @override
  Future<ContractDescriptor> getContractDescriptor() =>
      Future<ContractDescriptor>.error(StateError('service_unavailable'));

  @override
  Future<RunStartResponse> startRun({
    required String idempotencyKey,
    required RunStartRequest request,
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getRunCandidate({required String runId}) =>
      throw UnimplementedError();

  @override
  Future<CancelResponse> cancelRun({
    required String runId,
    required CancelRequest request,
  }) => throw UnimplementedError();

  @override
  Future<ResumeResponse> resumeRun({
    required String runId,
    required ResumeRequest request,
  }) => throw UnimplementedError();
}
