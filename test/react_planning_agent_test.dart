import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/ai/react_planning_agent.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _toolCall({
  required String id,
  required String name,
  required String arguments,
}) {
  return <String, dynamic>{
    'id': id,
    'type': 'function',
    'function': <String, dynamic>{'name': name, 'arguments': arguments},
  };
}

http.Response _llmResponse({
  required String finishReason,
  String content = '',
  List<Map<String, dynamic>> toolCalls = const <Map<String, dynamic>>[],
}) {
  return http.Response.bytes(
    utf8.encode(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'finish_reason': finishReason,
            'message': <String, dynamic>{
              'role': 'assistant',
              'content': content,
              if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
            },
          },
        ],
      }),
    ),
    200,
  );
}

void main() {
  group('ReactPlanningAgent', () {
    test('runs tool call loop and returns final answer', () async {
      int callCount = 0;
      final List<AgentStep> observedSteps = <AgentStep>[];
      final List<String> executedTools = <String>[];
      final http.Client client = MockClient((http.Request request) async {
        callCount++;
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['tools'], isA<List<dynamic>>());
        expect(body['tool_choice'], 'auto');
        if (callCount == 1) {
          return _llmResponse(
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall(
                id: 'call_1',
                name: 'search_poi',
                arguments: jsonEncode(<String, dynamic>{
                  'city': '西安',
                  'category': '景点',
                  'limit': 3,
                }),
              ),
            ],
          );
        }
        final List<dynamic> messages = body['messages'] as List<dynamic>;
        expect(
          messages.any(
            (dynamic message) =>
                message is Map<String, dynamic> && message['role'] == 'tool',
          ),
          isTrue,
        );
        return _llmResponse(finishReason: 'stop', content: 'final itinerary');
      });

      final ReactAgentResult result = await ReactPlanningAgent.run(
        systemPrompt: 'system',
        messages: <Map<String, dynamic>>[],
        userInput: '帮我规划西安三天',
        client: client,
        toolExecutor: (String toolName, Map<String, dynamic> args) async {
          executedTools.add(toolName);
          return jsonEncode(<String, dynamic>{'ok': true, 'args': args});
        },
        onStep: observedSteps.add,
      );

      expect(result.finalText, 'final itinerary');
      expect(result.isFallback, isFalse);
      expect(result.steps, hasLength(1));
      expect(result.steps.single.toolName, 'search_poi');
      expect(observedSteps, hasLength(1));
      expect(executedTools, <String>['search_poi']);
      expect(callCount, 2);
    });

    test('falls back after max steps', () async {
      final http.Client client = MockClient((http.Request request) async {
        return _llmResponse(
          finishReason: 'tool_calls',
          toolCalls: <Map<String, dynamic>>[
            _toolCall(
              id: 'call_loop',
              name: 'search_poi',
              arguments: jsonEncode(<String, dynamic>{
                'city': '西安',
                'category': '景点',
              }),
            ),
          ],
        );
      });

      final ReactAgentResult result = await ReactPlanningAgent.run(
        systemPrompt: 'system',
        messages: <Map<String, dynamic>>[],
        userInput: '帮我规划西安三天',
        client: client,
        toolExecutor: (String toolName, Map<String, dynamic> args) async {
          return jsonEncode(<String, dynamic>{'ok': true});
        },
      );

      expect(result.isFallback, isTrue);
      expect(result.steps.length, ReactPlanningAgent.maxSteps);
    });

    test('does not execute tools outside the allowlist', () async {
      int callCount = 0;
      int executedCount = 0;
      final http.Client client = MockClient((http.Request request) async {
        callCount++;
        if (callCount == 1) {
          return _llmResponse(
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall(id: 'call_bad', name: 'delete_trip', arguments: '{}'),
            ],
          );
        }
        return _llmResponse(finishReason: 'stop', content: 'safe final');
      });

      final ReactAgentResult result = await ReactPlanningAgent.run(
        systemPrompt: 'system',
        messages: <Map<String, dynamic>>[],
        userInput: '帮我规划西安三天',
        client: client,
        toolExecutor: (String toolName, Map<String, dynamic> args) async {
          executedCount++;
          return '{}';
        },
      );

      expect(result.finalText, 'safe final');
      expect(result.steps, isEmpty);
      expect(executedCount, 0);
      expect(callCount, 2);
    });

    test('uses empty args when tool arguments are invalid JSON', () async {
      int callCount = 0;
      Map<String, dynamic>? capturedArgs;
      final http.Client client = MockClient((http.Request request) async {
        callCount++;
        if (callCount == 1) {
          return _llmResponse(
            finishReason: 'tool_calls',
            toolCalls: <Map<String, dynamic>>[
              _toolCall(
                id: 'call_args',
                name: 'check_weather_forecast',
                arguments: 'not-json',
              ),
            ],
          );
        }
        return _llmResponse(finishReason: 'stop', content: 'weather noted');
      });

      final ReactAgentResult result = await ReactPlanningAgent.run(
        systemPrompt: 'system',
        messages: <Map<String, dynamic>>[],
        userInput: '安排西安两天',
        client: client,
        toolExecutor: (String toolName, Map<String, dynamic> args) async {
          capturedArgs = args;
          return 'sunny';
        },
      );

      expect(result.finalText, 'weather noted');
      expect(capturedArgs, isEmpty);
    });

    test('detects planning intent without routing weather-only chat', () {
      expect(ReactPlanningAgent.isPlanningIntent('帮我规划西安三天'), isTrue);
      expect(ReactPlanningAgent.isPlanningIntent('日本关西 7天特种兵打卡'), isTrue);
      expect(ReactPlanningAgent.isPlanningIntent('北京天气怎么样'), isFalse);
    });
  });
}
