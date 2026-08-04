enum AgentEntryKind { itineraryPlanning, ordinaryChat }

enum AgentPlanningRoute { legacy, agent }

enum ItineraryBasicInfoWriteRoute { legacy, domainCommand }

final class ItineraryBasicInfoWriteRouteDecision {
  const ItineraryBasicInfoWriteRouteDecision({
    required this.route,
    required this.reasonCode,
  });

  final ItineraryBasicInfoWriteRoute route;
  final String reasonCode;
}

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
    this.itineraryBasicInfoCommandEnabled = false,
    this.itineraryBasicInfoCommandKillSwitch = true,
    this.clientGeneration = 1,
    this.serverGeneration = 0,
  });

  static const String itineraryPlanningFlagName = 'gonow_itinerary_agent_v1';
  static const String itineraryBasicInfoCommandFlagName =
      'gonow_itinerary_basic_info_command_v1';

  final bool itineraryPlanningEnabled;
  final bool itineraryPlanningKillSwitch;
  final bool itineraryBasicInfoCommandEnabled;
  final bool itineraryBasicInfoCommandKillSwitch;
  final int clientGeneration;
  final int serverGeneration;

  ItineraryBasicInfoWriteRouteDecision evaluateItineraryBasicInfoWrite({
    required bool commandRouteAvailable,
  }) {
    if (itineraryBasicInfoCommandKillSwitch) {
      return const ItineraryBasicInfoWriteRouteDecision(
        route: ItineraryBasicInfoWriteRoute.legacy,
        reasonCode: 'command_kill_switch_active',
      );
    }
    if (!itineraryBasicInfoCommandEnabled) {
      return const ItineraryBasicInfoWriteRouteDecision(
        route: ItineraryBasicInfoWriteRoute.legacy,
        reasonCode: 'command_flag_disabled',
      );
    }
    if (!commandRouteAvailable) {
      return const ItineraryBasicInfoWriteRouteDecision(
        route: ItineraryBasicInfoWriteRoute.legacy,
        reasonCode: 'command_route_unavailable',
      );
    }
    return const ItineraryBasicInfoWriteRouteDecision(
      route: ItineraryBasicInfoWriteRoute.domainCommand,
      reasonCode: 'command_flag_enabled',
    );
  }

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
