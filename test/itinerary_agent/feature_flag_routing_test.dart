import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/config/agent_feature_flags.dart';
import 'package:gonow/features/itinerary/data/itinerary_basic_info_command_client.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/itinerary/presentation/screens/itinerary_screen.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _basicInfoTarget = '10000000-0000-4000-8000-000000000001';

String _digest(String character) => List<String>.filled(64, character).join();

Map<String, dynamic> _commandReceipt(
  Map<String, Object?> body, {
  String state = 'committed',
  int? actualVersion = 6,
  bool replayed = false,
}) => <String, dynamic>{
  'schema_version': '1.0',
  'command_type': 'itinerary.basic_info.update',
  'command_id': body['command_id'],
  'state': state,
  'target_digest': _digest('a'),
  'principal_digest': _digest('b'),
  'idempotency_digest': _digest('c'),
  'command_hash': _digest('d'),
  'approval_reference': 'policy:itinerary.basic_info.low-risk:v1',
  'expected_version': body['expected_version'],
  'actual_version': actualVersion,
  'event_id': actualVersion == null
      ? null
      : '30000000-0000-4000-8000-000000000001',
  'outbox_id': actualVersion == null
      ? null
      : '40000000-0000-4000-8000-000000000001',
  'policy_digest': _digest('e'),
  'schema_digest': _digest('f'),
  'recorded_at': '2026-08-04T10:00:00Z',
  'replayed': replayed,
};

final class _RoutingTransport implements ItineraryBasicInfoCommandTransport {
  String state = 'committed';
  Object? submitError;
  Map<String, dynamic>? lookupResponse;
  int submitCount = 0;
  int lookupCount = 0;
  Map<String, Object?>? lastBody;

  @override
  Future<Map<String, dynamic>?> lookup({
    required String targetItineraryId,
    required String idempotencyKey,
  }) async {
    lookupCount += 1;
    return lookupResponse;
  }

  @override
  Future<Map<String, dynamic>> submit({
    required String targetItineraryId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    submitCount += 1;
    lastBody = body;
    if (submitError case final Object error) throw error;
    return _commandReceipt(
      body,
      state: state,
      actualVersion: state == 'committed' ? 6 : null,
    );
  }
}

ItineraryModel _basicInfoFixture() => ItineraryModel(
  title: 'Legacy title',
  startDate: DateTime(2026, 10),
  endDate: DateTime(2026, 10, 3),
  planData: const <String, dynamic>{
    'destination_city': 'Shanghai',
    'estimated_budget_per_person': '1200.00',
    'actual_cost': '50.00',
    'tags': <String>['legacy'],
  },
  days: const <DayPlan>[],
  arrivedActivityIds: const <String>{},
  arrivedAtByActivityId: const <String, String>{},
  prepTaskDoneMap: const <String, bool>{},
  version: 5,
  remoteId: _basicInfoTarget,
);

Future<void> _seed(ItineraryProvider provider) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await provider.saveItinerary(_basicInfoFixture());
}

Future<void> _update(
  ItineraryProvider provider, {
  String title = 'New title',
}) => provider.updateItineraryBasicInfo(
  id: _basicInfoTarget,
  newTitle: title,
  newDestination: 'Shanghai',
  newStartDate: '2026-10-01',
  newEndDate: '2026-10-03',
  newBudget: '1200.00',
  newActualCost: '50.00',
  newTags: const <String>['city'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('flag off preserves the legacy planning fixture', () {
    const AgentFeatureFlags flags = AgentFeatureFlags();

    final AgentRouteDecision decision = flags.evaluate(
      AgentEntryKind.itineraryPlanning,
      agentRouteAvailable: true,
    );

    expect(decision.route, AgentPlanningRoute.legacy);
    expect(decision.reasonCode, 'kill_switch_active');
  });

  test('matched server and client generation enables only planning route', () {
    const AgentFeatureFlags flags = AgentFeatureFlags(
      itineraryPlanningEnabled: true,
      itineraryPlanningKillSwitch: false,
      clientGeneration: 7,
      serverGeneration: 7,
    );

    expect(
      flags
          .evaluate(AgentEntryKind.itineraryPlanning, agentRouteAvailable: true)
          .route,
      AgentPlanningRoute.agent,
    );
  });

  test('ordinary chat always bypasses Agent planning', () {
    for (final AgentFeatureFlags flags in <AgentFeatureFlags>[
      const AgentFeatureFlags(),
      const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: false,
        clientGeneration: 1,
        serverGeneration: 1,
      ),
      const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: false,
        clientGeneration: 9,
        serverGeneration: 9,
      ),
    ]) {
      final AgentRouteDecision decision = flags.evaluate(
        AgentEntryKind.ordinaryChat,
        agentRouteAvailable: true,
      );
      expect(decision.route, AgentPlanningRoute.legacy);
      expect(decision.reasonCode, 'ordinary_chat_bypass');
    }
  });

  test('kill switch and generation mismatch fail closed to legacy', () {
    for (final AgentFeatureFlags flags in <AgentFeatureFlags>[
      const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        clientGeneration: 3,
        serverGeneration: 3,
      ),
      const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: false,
        clientGeneration: 3,
        serverGeneration: 2,
      ),
    ]) {
      expect(
        flags
            .evaluate(
              AgentEntryKind.itineraryPlanning,
              agentRouteAvailable: true,
            )
            .route,
        AgentPlanningRoute.legacy,
      );
    }
  });

  test('missing Agent route callback fails closed to legacy', () {
    const AgentFeatureFlags flags = AgentFeatureFlags(
      itineraryPlanningEnabled: true,
      itineraryPlanningKillSwitch: false,
      clientGeneration: 4,
      serverGeneration: 4,
    );

    final AgentRouteDecision decision = flags.evaluate(
      AgentEntryKind.itineraryPlanning,
      agentRouteAvailable: false,
    );

    expect(decision.route, AgentPlanningRoute.legacy);
    expect(decision.reasonCode, 'agent_route_unavailable');
  });

  test('runtime kill switch immediately returns planning to legacy', () {
    final ItineraryProvider provider = ItineraryProvider(
      agentFeatureFlags: const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: false,
        clientGeneration: 6,
        serverGeneration: 6,
      ),
    );
    expect(
      provider
          .previewAgentRoute(
            AgentEntryKind.itineraryPlanning,
            agentRouteAvailable: true,
          )
          .route,
      AgentPlanningRoute.agent,
    );

    provider.applyAgentFeatureFlags(
      const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: true,
        clientGeneration: 6,
        serverGeneration: 6,
      ),
    );

    expect(
      provider
          .previewAgentRoute(
            AgentEntryKind.itineraryPlanning,
            agentRouteAvailable: true,
          )
          .route,
      AgentPlanningRoute.legacy,
    );
  });

  test('route audit is bounded and contains no prompt or identity fields', () {
    final ItineraryProvider provider = ItineraryProvider(
      agentFeatureFlags: const AgentFeatureFlags(),
    );

    for (int index = 0; index < 40; index += 1) {
      provider.selectAgentRoute(
        AgentEntryKind.itineraryPlanning,
        agentRouteAvailable: true,
      );
    }

    expect(provider.agentRouteAudit, hasLength(32));
    expect(provider.agentRouteAudit.first.sequence, 9);
    expect(provider.agentRouteAudit.last.sequence, 40);
    expect(provider.agentRouteAudit.last.reasonCode, 'kill_switch_active');
  });

  testWidgets('enabled planning CTA invokes only the Agent route callback', (
    WidgetTester tester,
  ) async {
    final ItineraryProvider itineraryProvider = ItineraryProvider(
      agentFeatureFlags: const AgentFeatureFlags(
        itineraryPlanningEnabled: true,
        itineraryPlanningKillSwitch: false,
        clientGeneration: 5,
        serverGeneration: 5,
      ),
    );
    final MainNavProvider mainNavProvider = MainNavProvider();
    int agentOpenCount = 0;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ItineraryProvider>.value(
            value: itineraryProvider,
          ),
          ChangeNotifierProvider<MainNavProvider>.value(value: mainNavProvider),
        ],
        child: MaterialApp(
          home: ItineraryScreen(onOpenAgentPlanning: () => agentOpenCount += 1),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('使用 Agent 规划行程'));
    await tester.pump();

    expect(agentOpenCount, 1);
    expect(
      itineraryProvider.agentRouteAudit.single.route,
      AgentPlanningRoute.agent,
    );
    expect(mainNavProvider.currentIndex, 0);
  });

  test('basic-info command flag is independent and default-off', () {
    const AgentFeatureFlags defaults = AgentFeatureFlags();
    expect(
      defaults
          .evaluateItineraryBasicInfoWrite(commandRouteAvailable: true)
          .route,
      ItineraryBasicInfoWriteRoute.legacy,
    );
    expect(
      defaults
          .evaluateItineraryBasicInfoWrite(commandRouteAvailable: true)
          .reasonCode,
      'command_kill_switch_active',
    );
  });

  test('flag off invokes only the tracked legacy basic-info writer', () async {
    final _RoutingTransport transport = _RoutingTransport();
    int legacyWriteCount = 0;
    final ItineraryProvider provider = ItineraryProvider(
      itineraryBasicInfoCommandClient: ItineraryBasicInfoCommandClient(
        transport: transport,
      ),
      itineraryBasicInfoLegacyWriter:
          ({
            required String cloudId,
            required Map<String, dynamic> values,
          }) async {
            legacyWriteCount += 1;
          },
    );
    await _seed(provider);

    await _update(provider);
    await Future<void>.delayed(Duration.zero);

    expect(legacyWriteCount, 1);
    expect(transport.submitCount, 0);
    expect(provider.currentItinerary!.title, 'New title');
    expect(provider.currentItinerary!.version, 5);
  });

  test('flag on invokes only the selected Domain Command writer', () async {
    final _RoutingTransport transport = _RoutingTransport();
    int legacyWriteCount = 0;
    final ItineraryProvider provider = ItineraryProvider(
      agentFeatureFlags: const AgentFeatureFlags(
        itineraryBasicInfoCommandEnabled: true,
        itineraryBasicInfoCommandKillSwitch: false,
      ),
      itineraryBasicInfoCommandClient: ItineraryBasicInfoCommandClient(
        transport: transport,
      ),
      itineraryBasicInfoLegacyWriter:
          ({
            required String cloudId,
            required Map<String, dynamic> values,
          }) async {
            legacyWriteCount += 1;
          },
    );
    await _seed(provider);

    await _update(provider);

    expect(transport.submitCount, 1);
    expect(transport.lookupCount, 0);
    expect(legacyWriteCount, 0);
    expect(provider.currentItinerary!.title, 'New title');
    expect(provider.currentItinerary!.version, 6);
  });

  test(
    'stale conflict leaves local success state unchanged and never falls back',
    () async {
      final _RoutingTransport transport = _RoutingTransport()
        ..state = 'conflict';
      int legacyWriteCount = 0;
      final ItineraryProvider provider = ItineraryProvider(
        agentFeatureFlags: const AgentFeatureFlags(
          itineraryBasicInfoCommandEnabled: true,
          itineraryBasicInfoCommandKillSwitch: false,
        ),
        itineraryBasicInfoCommandClient: ItineraryBasicInfoCommandClient(
          transport: transport,
        ),
        itineraryBasicInfoLegacyWriter:
            ({
              required String cloudId,
              required Map<String, dynamic> values,
            }) async {
              legacyWriteCount += 1;
            },
      );
      await _seed(provider);

      await expectLater(
        _update(provider),
        throwsA(
          isA<ItineraryBasicInfoCommandClientException>().having(
            (ItineraryBasicInfoCommandClientException error) => error.code,
            'code',
            'domain_command.stale_version',
          ),
        ),
      );

      expect(provider.currentItinerary!.title, 'Legacy title');
      expect(provider.currentItinerary!.version, 5);
      expect(transport.submitCount, 1);
      expect(legacyWriteCount, 0);
    },
  );

  test('unknown command outcome looks up once and never falls back', () async {
    final _RoutingTransport transport = _RoutingTransport()
      ..submitError = const ItineraryBasicInfoCommandTransportException(
        'transport.response_lost',
        outcomeUnknown: true,
      );
    int legacyWriteCount = 0;
    final ItineraryProvider provider = ItineraryProvider(
      agentFeatureFlags: const AgentFeatureFlags(
        itineraryBasicInfoCommandEnabled: true,
        itineraryBasicInfoCommandKillSwitch: false,
      ),
      itineraryBasicInfoCommandClient: ItineraryBasicInfoCommandClient(
        transport: transport,
      ),
      itineraryBasicInfoLegacyWriter:
          ({
            required String cloudId,
            required Map<String, dynamic> values,
          }) async {
            legacyWriteCount += 1;
          },
    );
    await _seed(provider);

    await expectLater(
      _update(provider),
      throwsA(
        isA<ItineraryBasicInfoCommandClientException>().having(
          (ItineraryBasicInfoCommandClientException error) => error.code,
          'code',
          'domain_command.outcome_unknown',
        ),
      ),
    );

    expect(transport.submitCount, 1);
    expect(transport.lookupCount, 1);
    expect(legacyWriteCount, 0);
    expect(provider.currentItinerary!.title, 'Legacy title');
  });

  test(
    'kill switch returns new intents to legacy after a committed command',
    () async {
      final _RoutingTransport transport = _RoutingTransport();
      int legacyWriteCount = 0;
      final ItineraryProvider provider = ItineraryProvider(
        agentFeatureFlags: const AgentFeatureFlags(
          itineraryBasicInfoCommandEnabled: true,
          itineraryBasicInfoCommandKillSwitch: false,
        ),
        itineraryBasicInfoCommandClient: ItineraryBasicInfoCommandClient(
          transport: transport,
        ),
        itineraryBasicInfoLegacyWriter:
            ({
              required String cloudId,
              required Map<String, dynamic> values,
            }) async {
              legacyWriteCount += 1;
            },
      );
      await _seed(provider);
      await _update(provider, title: 'Command title');

      provider.applyAgentFeatureFlags(
        const AgentFeatureFlags(
          itineraryBasicInfoCommandEnabled: true,
          itineraryBasicInfoCommandKillSwitch: true,
        ),
      );
      await _update(provider, title: 'Rollback title');
      await Future<void>.delayed(Duration.zero);

      expect(transport.submitCount, 1);
      expect(legacyWriteCount, 1);
      expect(provider.currentItinerary!.title, 'Rollback title');
      expect(provider.currentItinerary!.version, 6);
    },
  );

  test(
    'the command client is referenced by exactly one provider write entry',
    () {
      final String source = File(
        'lib/features/itinerary/data/itinerary_provider.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'await _itineraryBasicInfoCommandClient!\.execute\(request\)',
        ).allMatches(source),
        hasLength(1),
      );
    },
  );
}
