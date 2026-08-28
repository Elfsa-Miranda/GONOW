import 'package:gonow/core/config/agent_feature_flags.dart';

final class AgentServiceConfig {
  const AgentServiceConfig({
    required this.baseUrl,
    required this.planningEnabled,
    required this.killSwitch,
    required this.clientGeneration,
    required this.serverGeneration,
  });

  static const AgentServiceConfig environment = AgentServiceConfig(
    baseUrl: String.fromEnvironment('GONOW_AGENT_API_URL'),
    planningEnabled: bool.fromEnvironment(
      'GONOW_ITINERARY_AGENT_ENABLED',
      defaultValue: false,
    ),
    killSwitch: bool.fromEnvironment(
      'GONOW_ITINERARY_AGENT_KILL_SWITCH',
      defaultValue: true,
    ),
    clientGeneration: int.fromEnvironment(
      'GONOW_ITINERARY_AGENT_CLIENT_GENERATION',
      defaultValue: 1,
    ),
    serverGeneration: int.fromEnvironment(
      'GONOW_ITINERARY_AGENT_SERVER_GENERATION',
      defaultValue: 0,
    ),
  );

  final String baseUrl;
  final bool planningEnabled;
  final bool killSwitch;
  final int clientGeneration;
  final int serverGeneration;

  AgentFeatureFlags get featureFlags => AgentFeatureFlags(
    itineraryPlanningEnabled: planningEnabled,
    itineraryPlanningKillSwitch: killSwitch,
    clientGeneration: clientGeneration,
    serverGeneration: serverGeneration,
  );

  Uri? get validatedBaseUri {
    final Uri? uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    if (uri.scheme == 'https') {
      return uri;
    }
    if (uri.scheme == 'http' && _isLoopback(uri.host)) {
      return uri;
    }
    return null;
  }

  bool get routeAvailable => validatedBaseUri != null;

  static bool _isLoopback(String host) {
    final String normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1';
  }
}
