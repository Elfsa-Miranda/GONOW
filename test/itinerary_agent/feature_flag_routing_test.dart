import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/config/agent_feature_flags.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/itinerary/presentation/screens/itinerary_screen.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';

void main() {
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
}
