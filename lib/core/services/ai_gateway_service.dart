import 'dart:async';
import 'dart:convert';

import 'package:gonow/core/constants/ai_config.dart';
import 'package:http/http.dart' as http;

class AiGatewayException implements Exception {
  final String code;

  const AiGatewayException(this.code);

  @override
  String toString() => 'AiGatewayException($code)';
}

class AiGatewayResponse {
  final String content;
  final Map<String, dynamic>? itineraryData;
  final String? requestId;

  const AiGatewayResponse({
    required this.content,
    this.itineraryData,
    this.requestId,
  });
}

/// Release A's fixed, authenticated server boundary for ordinary chat.
///
/// This client never accepts, stores, or forwards a model-provider key and has
/// no direct-provider fallback. Invalid or absent deployment configuration
/// fails before a network request is created.
class AiGatewayService {
  static const String _chatPath = '/v1/release-a/chat';
  static const int _maxMessageCount = 16;
  static const int _maxRequestCharacters = 50000;
  static const int _maxResponseBytes = 512 * 1024;

  final http.Client _client;
  final bool _enabled;
  final String _gatewayUrl;
  final String _allowedHost;
  final Duration _timeout;

  AiGatewayService({
    required http.Client client,
    bool enabled = AiConfig.releaseAGatewayEnabled,
    String gatewayUrl = AiConfig.releaseAGatewayUrl,
    String allowedHost = AiConfig.releaseAGatewayAllowedHost,
    Duration timeout = const Duration(seconds: 60),
  }) : _client = client,
       _enabled = enabled,
       _gatewayUrl = gatewayUrl,
       _allowedHost = allowedHost,
       _timeout = timeout;

  Future<AiGatewayResponse> sendChat({
    required String accessToken,
    required List<Map<String, String>> messages,
    required String source,
    Map<String, dynamic>? currentPlan,
  }) async {
    final Uri endpoint = _validatedEndpoint();
    final String normalizedToken = accessToken.trim();
    if (normalizedToken.isEmpty) {
      throw const AiGatewayException('authentication_required');
    }
    if (messages.isEmpty || messages.length > _maxMessageCount) {
      throw const AiGatewayException('invalid_message_count');
    }
    var requestCharacters = source.length;
    final List<Map<String, String>> normalizedMessages =
        <Map<String, String>>[];
    for (final Map<String, String> message in messages) {
      final String role = (message['role'] ?? '').trim();
      final String content = (message['content'] ?? '').trim();
      if ((role != 'user' && role != 'assistant') || content.isEmpty) {
        throw const AiGatewayException('invalid_message');
      }
      requestCharacters += role.length + content.length;
      normalizedMessages.add(<String, String>{
        'role': role,
        'content': content,
      });
    }
    if (requestCharacters > _maxRequestCharacters) {
      throw const AiGatewayException('request_too_large');
    }

    late final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: <String, String>{
              'Authorization': 'Bearer $normalizedToken',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'messages': normalizedMessages,
              'source': source,
              'current_plan': ?currentPlan,
            }),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const AiGatewayException('timeout');
    } on http.ClientException {
      throw const AiGatewayException('network_failure');
    }

    if (response.statusCode != 200) {
      throw AiGatewayException('gateway_http_${response.statusCode}');
    }
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const AiGatewayException('response_too_large');
    }
    final String contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('application/json')) {
      throw const AiGatewayException('invalid_content_type');
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const AiGatewayException('invalid_response');
    }
    if (decoded is! Map) {
      throw const AiGatewayException('invalid_response');
    }
    final Map<String, dynamic> body = Map<String, dynamic>.from(decoded);
    final String responseContent = (body['content'] as String? ?? '').trim();
    if (responseContent.isEmpty) {
      throw const AiGatewayException('empty_response');
    }
    final Object? itineraryValue = body['itinerary_data'];
    final Map<String, dynamic>? itineraryData = itineraryValue is Map
        ? Map<String, dynamic>.from(itineraryValue)
        : null;
    final Object? requestIdValue = body['request_id'];
    return AiGatewayResponse(
      content: responseContent,
      itineraryData: itineraryData,
      requestId: requestIdValue is String ? requestIdValue : null,
    );
  }

  Uri _validatedEndpoint() {
    if (!_enabled) {
      throw const AiGatewayException('gateway_disabled');
    }
    final String allowedHost = _allowedHost.trim().toLowerCase();
    final Uri? base = Uri.tryParse(_gatewayUrl.trim());
    if (allowedHost.isEmpty ||
        base == null ||
        base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.toLowerCase() != allowedHost ||
        base.userInfo.isNotEmpty ||
        base.port != 443 ||
        (base.path.isNotEmpty && base.path != '/') ||
        base.hasQuery ||
        base.hasFragment) {
      throw const AiGatewayException('invalid_gateway_configuration');
    }
    return base.replace(path: _chatPath, query: null, fragment: null);
  }
}
