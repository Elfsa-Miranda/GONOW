import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/config/agent_service_config.dart';

void main() {
  const AgentServiceConfig defaults = AgentServiceConfig(
    baseUrl: '',
    planningEnabled: false,
    killSwitch: true,
    clientGeneration: 1,
    serverGeneration: 0,
  );

  test('default configuration fails closed', () {
    expect(defaults.routeAvailable, isFalse);
    expect(defaults.featureFlags.itineraryPlanningKillSwitch, isTrue);
  });

  test('HTTPS and loopback HTTP are the only accepted endpoint classes', () {
    expect(_config('https://agent.gonow.example').routeAvailable, isTrue);
    expect(_config('http://127.0.0.1:8000').routeAvailable, isTrue);
    expect(_config('http://localhost:8000').routeAvailable, isTrue);
    expect(_config('http://agent.gonow.example').routeAvailable, isFalse);
    expect(_config('https://user@agent.gonow.example').routeAvailable, isFalse);
    expect(_config('https://agent.gonow.example/v1').routeAvailable, isFalse);
    expect(_config('https://agent.gonow.example?a=b').routeAvailable, isFalse);
  });

  test('environment values map exactly to feature flag generations', () {
    const AgentServiceConfig config = AgentServiceConfig(
      baseUrl: 'https://agent.gonow.example',
      planningEnabled: true,
      killSwitch: false,
      clientGeneration: 4,
      serverGeneration: 4,
    );
    final flags = config.featureFlags;
    expect(flags.itineraryPlanningEnabled, isTrue);
    expect(flags.itineraryPlanningKillSwitch, isFalse);
    expect(flags.clientGeneration, 4);
    expect(flags.serverGeneration, 4);
  });
}

AgentServiceConfig _config(String url) => AgentServiceConfig(
  baseUrl: url,
  planningEnabled: true,
  killSwitch: false,
  clientGeneration: 1,
  serverGeneration: 1,
);
