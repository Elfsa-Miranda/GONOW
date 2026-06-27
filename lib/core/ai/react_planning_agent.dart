import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gonow/core/constants/ai_config.dart';
import 'package:gonow/core/services/amap_service.dart';
import 'package:http/http.dart' as http;

const List<String> _kAllowedToolNames = <String>[
  'search_poi',
  'estimate_route',
  'check_weather_forecast',
];

const List<Map<String, dynamic>> _kTools = <Map<String, dynamic>>[
  <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'search_poi',
      'description': '当需要为某个城市查找真实存在的景点、餐厅、酒店或购物地点时调用。',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'city': <String, dynamic>{
            'type': 'string',
            'description': '城市名称，例如“西安”',
          },
          'category': <String, dynamic>{
            'type': 'string',
            'description': '地点类别：景点、餐厅、酒店或购物',
          },
          'limit': <String, dynamic>{
            'type': 'integer',
            'description': '返回数量，默认 8',
          },
        },
        'required': <String>['city', 'category'],
      },
    },
  },
  <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'estimate_route',
      'description': '当需要确认两个地点之间通勤时间是否适合相邻安排时调用。',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'from_location': <String, dynamic>{
            'type': 'string',
            'description': '出发地点名称',
          },
          'to_location': <String, dynamic>{
            'type': 'string',
            'description': '目的地点名称',
          },
          'mode': <String, dynamic>{
            'type': 'string',
            'description': '交通方式：driving、walking 或 transit，默认 driving',
          },
        },
        'required': <String>['from_location', 'to_location'],
      },
    },
  },
  <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'check_weather_forecast',
      'description': '当需要判断目的地天气是否适合户外活动或调整行程节奏时调用。',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'city': <String, dynamic>{'type': 'string', 'description': '城市名称'},
        },
        'required': <String>['city'],
      },
    },
  },
];

typedef AgentToolExecutor =
    Future<String> Function(String toolName, Map<String, dynamic> args);

class AgentStep {
  const AgentStep({
    required this.toolName,
    required this.argsJson,
    required this.observation,
  });

  final String toolName;
  final String argsJson;
  final String observation;
}

class ReactAgentResult {
  const ReactAgentResult({
    required this.finalText,
    required this.steps,
    this.isFallback = false,
  });

  final String finalText;
  final List<AgentStep> steps;
  final bool isFallback;
}

class ReactPlanningAgent {
  static const int maxSteps = 6;

  static Future<ReactAgentResult> run({
    required String systemPrompt,
    required List<Map<String, dynamic>> messages,
    required String userInput,
    void Function(AgentStep step)? onStep,
    http.Client? client,
    AgentToolExecutor? toolExecutor,
  }) async {
    final List<AgentStep> steps = <AgentStep>[];
    final http.Client localClient = client ?? http.Client();
    final bool ownsClient = client == null;
    final AgentToolExecutor executeTool =
        toolExecutor ?? AmapService.executeTool;
    final List<Map<String, dynamic>> chatMessages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
      ...messages.map(
        (Map<String, dynamic> message) => Map<String, dynamic>.from(message),
      ),
      <String, dynamic>{'role': 'user', 'content': userInput},
    ];

    try {
      for (int stepIndex = 0; stepIndex < maxSteps; stepIndex++) {
        final http.Response response = await localClient
            .post(
              Uri.parse(AiConfig.deepseekEndpoint),
              headers: <String, String>{
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${AiConfig.deepseekApiKey.trim()}',
              },
              body: jsonEncode(<String, dynamic>{
                'model': AiConfig.deepseekModel,
                'messages': chatMessages,
                'tools': _kTools,
                'tool_choice': 'auto',
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          return ReactAgentResult(
            finalText: '规划服务暂时不可用，请稍后再试。',
            steps: steps,
            isFallback: true,
          );
        }

        final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map<String, dynamic>) {
          return ReactAgentResult(
            finalText: '规划服务暂时不可用，请稍后再试。',
            steps: steps,
            isFallback: true,
          );
        }
        final List<dynamic> choices =
            decoded['choices'] as List<dynamic>? ?? <dynamic>[];
        if (choices.isEmpty || choices.first is! Map) {
          return ReactAgentResult(
            finalText: '规划服务暂时不可用，请稍后再试。',
            steps: steps,
            isFallback: true,
          );
        }
        final Map<dynamic, dynamic> choice =
            choices.first as Map<dynamic, dynamic>;
        final Map<dynamic, dynamic> message =
            choice['message'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{};
        final String finishReason = choice['finish_reason']?.toString() ?? '';

        if (finishReason == 'stop' || finishReason == 'length') {
          return ReactAgentResult(
            finalText: message['content']?.toString() ?? '',
            steps: steps,
          );
        }

        if (finishReason == 'tool_calls') {
          final List<dynamic> toolCalls =
              message['tool_calls'] as List<dynamic>? ?? <dynamic>[];
          chatMessages.add(<String, dynamic>{
            'role': 'assistant',
            if (message.containsKey('content'))
              'content': message['content']?.toString(),
            'tool_calls': toolCalls,
          });

          for (final dynamic rawToolCall in toolCalls) {
            if (rawToolCall is! Map) continue;
            final String toolCallId = rawToolCall['id']?.toString() ?? '';
            final Map<dynamic, dynamic> function =
                rawToolCall['function'] as Map<dynamic, dynamic>? ??
                <dynamic, dynamic>{};
            final String toolName = function['name']?.toString() ?? '';
            final String argsJson = function['arguments']?.toString() ?? '{}';

            if (!_kAllowedToolNames.contains(toolName)) {
              chatMessages.add(<String, dynamic>{
                'role': 'tool',
                'tool_call_id': toolCallId,
                'content': jsonEncode(<String, dynamic>{
                  'error': 'not allowed',
                }),
              });
              continue;
            }

            final Map<String, dynamic> args = _safeDecodeArgs(argsJson);
            final String observation = await _safeExecuteTool(
              executeTool: executeTool,
              toolName: toolName,
              args: args,
            );
            final AgentStep agentStep = AgentStep(
              toolName: toolName,
              argsJson: argsJson,
              observation: observation,
            );
            steps.add(agentStep);
            onStep?.call(agentStep);
            chatMessages.add(<String, dynamic>{
              'role': 'tool',
              'tool_call_id': toolCallId,
              'content': observation,
            });
          }
          continue;
        }

        return ReactAgentResult(
          finalText: message['content']?.toString() ?? '规划服务暂时不可用，请稍后再试。',
          steps: steps,
          isFallback: true,
        );
      }

      return ReactAgentResult(
        finalText: '行程规划步骤过多，请稍后重试或简化需求。',
        steps: steps,
        isFallback: true,
      );
    } catch (e) {
      debugPrint('ReactPlanningAgent run 失败: $e');
      return ReactAgentResult(
        finalText: '规划服务暂时不可用，请稍后再试。',
        steps: steps,
        isFallback: true,
      );
    } finally {
      if (ownsClient) {
        localClient.close();
      }
    }
  }

  static bool isPlanningIntent(String text) {
    try {
      const List<String> planningKeywords = <String>[
        '行程',
        '规划',
        '路线',
        '安排',
        '怎么玩',
        '天游',
        '天的',
        '景点',
        '攻略',
        '计划',
        '旅游',
        '旅行',
        '游玩',
        '推荐去',
        '去哪玩',
      ];
      final RegExp dayCountPattern = RegExp(r'(\d+|[一二三四五六七八九十两]+)\s*天');
      if (dayCountPattern.hasMatch(text)) return true;
      return planningKeywords.any(text.contains);
    } catch (e) {
      debugPrint('ReactPlanningAgent isPlanningIntent 失败: $e');
      return false;
    }
  }

  static Map<String, dynamic> _safeDecodeArgs(String argsJson) {
    try {
      final Object? decoded = jsonDecode(argsJson);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return <String, dynamic>{};
    } catch (e) {
      debugPrint('ReactPlanningAgent args 解析失败: $e');
      return <String, dynamic>{};
    }
  }

  static Future<String> _safeExecuteTool({
    required AgentToolExecutor executeTool,
    required String toolName,
    required Map<String, dynamic> args,
  }) async {
    try {
      return await executeTool(toolName, args);
    } catch (e) {
      debugPrint('ReactPlanningAgent tool 执行失败: $e');
      return jsonEncode(<String, dynamic>{'error': 'tool failed'});
    }
  }
}
