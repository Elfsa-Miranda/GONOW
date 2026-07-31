import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/services/ai_gateway_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const List<Map<String, String>> messages = <Map<String, String>>[
    <String, String>{'role': 'user', 'content': 'Plan a short trip.'},
  ];

  test('disabled gateway fails closed without a network call', () async {
    var callCount = 0;
    final AiGatewayService service = AiGatewayService(
      client: MockClient((http.Request request) async {
        callCount++;
        return http.Response('{}', 200);
      }),
      enabled: false,
      gatewayUrl: 'https://gateway.example.test',
      allowedHost: 'gateway.example.test',
    );

    await expectLater(
      service.sendChat(
        accessToken: 'user-session-token',
        messages: messages,
        source: 'test',
      ),
      throwsA(
        isA<AiGatewayException>().having(
          (AiGatewayException error) => error.code,
          'code',
          'gateway_disabled',
        ),
      ),
    );
    expect(callCount, 0);
  });

  test('host mismatch fails before a network call', () async {
    var callCount = 0;
    final AiGatewayService service = AiGatewayService(
      client: MockClient((http.Request request) async {
        callCount++;
        return http.Response('{}', 200);
      }),
      enabled: true,
      gatewayUrl: 'https://gateway.example.test',
      allowedHost: 'different.example.test',
    );

    await expectLater(
      service.sendChat(
        accessToken: 'user-session-token',
        messages: messages,
        source: 'test',
      ),
      throwsA(
        isA<AiGatewayException>().having(
          (AiGatewayException error) => error.code,
          'code',
          'invalid_gateway_configuration',
        ),
      ),
    );
    expect(callCount, 0);
  });

  test('request uses only the fixed authenticated server contract', () async {
    late http.Request captured;
    final AiGatewayService service = AiGatewayService(
      client: MockClient((http.Request request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'content': 'A safe response',
            'itinerary_data': <String, Object?>{'title': 'Trip'},
            'request_id': 'request-1',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      enabled: true,
      gatewayUrl: 'https://gateway.example.test',
      allowedHost: 'gateway.example.test',
    );

    final AiGatewayResponse result = await service.sendChat(
      accessToken: 'user-session-token',
      messages: messages,
      source: 'test',
      currentPlan: <String, dynamic>{'title': 'Existing'},
    );

    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://gateway.example.test/v1/release-a/chat',
    );
    expect(captured.headers['authorization'], 'Bearer user-session-token');
    final Map<String, dynamic> body =
        jsonDecode(captured.body) as Map<String, dynamic>;
    expect(
      body.keys,
      containsAll(<String>['messages', 'source', 'current_plan']),
    );
    expect(body.containsKey('model'), isFalse);
    expect(body.containsKey('api_key'), isFalse);
    expect(body.containsKey('provider'), isFalse);
    expect(result.content, 'A safe response');
    expect(result.itineraryData, <String, dynamic>{'title': 'Trip'});
    expect(result.requestId, 'request-1');
  });

  test('gateway error never exposes the upstream response body', () async {
    final AiGatewayService service = AiGatewayService(
      client: MockClient(
        (http.Request request) async => http.Response(
          'sensitive-upstream-body',
          502,
          headers: <String, String>{'content-type': 'text/plain'},
        ),
      ),
      enabled: true,
      gatewayUrl: 'https://gateway.example.test',
      allowedHost: 'gateway.example.test',
    );

    try {
      await service.sendChat(
        accessToken: 'user-session-token',
        messages: messages,
        source: 'test',
      );
      fail('Expected the gateway request to fail.');
    } on AiGatewayException catch (error) {
      expect(error.code, 'gateway_http_502');
      expect(error.toString(), isNot(contains('sensitive-upstream-body')));
    }
  });
}
