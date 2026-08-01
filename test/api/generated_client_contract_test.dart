import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const String runId = '11111111-1111-4111-8111-111111111111';

  test('generated digest is bound to the server OpenAPI bytes', () {
    expect(
      agentApiSpecSha256,
      'ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed',
    );
    expect(agentApiContractVersion, '1.0.0');
    expect(agentApiGeneratorVersion, '1.0.0');
  });

  test('health response is decoded without requesting a token', () async {
    var tokenReads = 0;
    final AgentApiClient client = AgentApiClient(
      baseUri: Uri.parse('http://localhost:8000'),
      httpClient: MockClient((http.Request request) async {
        expect(request.url.path, '/health/live');
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response(
          jsonEncode(<String, Object>{
            'status': 'live',
            'reason_codes': <String>[],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      accessTokenProvider: () async {
        tokenReads += 1;
        return 'not-used';
      },
    );

    final HealthProbe result = await client.getLiveness();
    expect(result.status, 'live');
    expect(result.reasonCodes, isEmpty);
    expect(tokenReads, 0);
  });

  test(
    'descriptor request carries ephemeral auth and parses the digest',
    () async {
      final AgentApiClient client = AgentApiClient(
        baseUri: Uri.parse('https://agent.example.test'),
        httpClient: MockClient((http.Request request) async {
          expect(request.url.path, '/v1/contracts/agent-api/1');
          expect(request.headers['authorization'], 'Bearer session-token');
          return http.Response(
            jsonEncode(<String, Object>{
              'name': 'agent-api',
              'major': 1,
              'version': '1.0.0',
              'spec_sha256': agentApiSpecSha256,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        accessTokenProvider: () async => 'session-token',
      );

      final ContractDescriptor descriptor = await client
          .getContractDescriptor();
      expect(descriptor.specSha256, agentApiSpecSha256);
    },
  );

  test(
    'resume emits the exact typed body and parses a typed response',
    () async {
      final AgentApiClient client = AgentApiClient(
        baseUri: Uri.parse('https://agent.example.test'),
        httpClient: MockClient((http.Request request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/v1/runs/$runId/resume');
          expect(jsonDecode(request.body), <String, Object>{
            'resume_token': 'one-use-token',
            'interrupt_id': '22222222-2222-4222-8222-222222222222',
            'command_hash': 'a' * 64,
            'command_version': '1.0',
          });
          return http.Response(
            jsonEncode(<String, Object>{
              'status': 'resumed',
              'run_id': runId,
              'interrupt_id': '22222222-2222-4222-8222-222222222222',
              'command_version': '1.0',
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
        accessTokenProvider: () async => 'session-token',
      );

      final ResumeResponse response = await client.resumeRun(
        runId: runId,
        request: ResumeRequest(
          resumeToken: 'one-use-token',
          interruptId: '22222222-2222-4222-8222-222222222222',
          commandHash: 'a' * 64,
          commandVersion: '1.0',
        ),
      );
      expect(response.status, 'resumed');
      expect(response.runId, runId);
    },
  );

  test('cancel response is typed and preserves replay state', () async {
    final AgentApiClient client = AgentApiClient(
      baseUri: Uri.parse('https://agent.example.test'),
      httpClient: MockClient((http.Request request) async {
        expect(jsonDecode(request.body), <String, Object>{
          'expected_version': 7,
        });
        return http.Response(
          jsonEncode(<String, Object>{
            'status': 'cancelled',
            'run_id': runId,
            'version': 8,
            'replayed': true,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
      accessTokenProvider: () async => 'session-token',
    );

    final CancelResponse response = await client.cancelRun(
      runId: runId,
      request: const CancelRequest(expectedVersion: 7),
    );
    expect(response.status, 'cancelled');
    expect(response.version, 8);
    expect(response.replayed, isTrue);
  });

  test(
    'HTTP errors expose typed safe fields without leaking the body',
    () async {
      final AgentApiClient client = AgentApiClient(
        baseUri: Uri.parse('https://agent.example.test'),
        httpClient: MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object>{
              'error': <String, Object>{
                'code': 'auth.forbidden',
                'message': 'This action is not allowed.',
                'request_id': 'req-safe',
              },
            }),
            403,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
        accessTokenProvider: () async => 'session-token',
      );

      await expectLater(
        client.cancelRun(
          runId: runId,
          request: const CancelRequest(expectedVersion: 1),
        ),
        throwsA(
          isA<AgentApiHttpException>()
              .having(
                (AgentApiHttpException error) => error.statusCode,
                'status',
                403,
              )
              .having(
                (AgentApiHttpException error) => error.error.code,
                'code',
                'auth.forbidden',
              )
              .having(
                (AgentApiHttpException error) => error.toString(),
                'safe string',
                isNot(contains('This action is not allowed.')),
              ),
        ),
      );
    },
  );

  test('unknown response fields fail closed', () {
    expect(
      () => HealthProbe.fromJson(<String, Object>{
        'status': 'live',
        'reason_codes': <String>[],
        'unexpected': true,
      }),
      throwsA(isA<AgentApiProtocolException>()),
    );
  });
}
