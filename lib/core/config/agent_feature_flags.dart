enum AgentEntryKind { itineraryPlanning, ordinaryChat }

enum AgentPlanningRoute { legacy, agent }

final class AgentRouteDecision {
  const AgentRouteDecision({
    required this.entry,
    required this.route,
    required this.reasonCode,
    required this.clientGeneration,
    required this.serverGeneration,
  });

  final AgentEntryKind entry;
  final AgentPlanningRoute route;
  final String reasonCode;
  final int clientGeneration;
  final int serverGeneration;
}

final class AgentPlanningRouteAudit {
  const AgentPlanningRouteAudit({
    required this.sequence,
    required this.entry,
    required this.route,
    required this.reasonCode,
    required this.clientGeneration,
    required this.serverGeneration,
  });

  final int sequence;
  final AgentEntryKind entry;
  final AgentPlanningRoute route;
  final String reasonCode;
  final int clientGeneration;
  final int serverGeneration;
}

final class AgentFeatureFlags {
  const AgentFeatureFlags({
    this.itineraryPlanningEnabled = false,
    this.itineraryPlanningKillSwitch = true,
    this.clientGeneration = 1,
    this.serverGeneration = 0,
  });

  static const String itineraryPlanningFlagName = 'gonow_itinerary_agent_v1';

  final bool itineraryPlanningEnabled;
  final bool itineraryPlanningKillSwitch;
  final int clientGeneration;
  final int serverGeneration;

  AgentRouteDecision evaluate(
    AgentEntryKind entry, {
    required bool agentRouteAvailable,
  }) {
    if (entry == AgentEntryKind.ordinaryChat) {
      return _legacy(entry, 'ordinary_chat_bypass');
    }
    if (itineraryPlanningKillSwitch) {
      return _legacy(entry, 'kill_switch_active');
    }
    if (!itineraryPlanningEnabled) {
      return _legacy(entry, 'flag_disabled');
    }
    if (clientGeneration < 1 || serverGeneration != clientGeneration) {
      return _legacy(entry, 'generation_mismatch');
    }
    if (!agentRouteAvailable) {
      return _legacy(entry, 'agent_route_unavailable');
    }
    return AgentRouteDecision(
      entry: entry,
      route: AgentPlanningRoute.agent,
      reasonCode: 'flag_enabled',
      clientGeneration: clientGeneration,
      serverGeneration: serverGeneration,
    );
  }

  AgentRouteDecision _legacy(AgentEntryKind entry, String reasonCode) =>
      AgentRouteDecision(
        entry: entry,
        route: AgentPlanningRoute.legacy,
        reasonCode: reasonCode,
        clientGeneration: clientGeneration,
        serverGeneration: serverGeneration,
      );
}
