import 'dart:async';
import 'dart:convert';

import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:http/http.dart' as http;

abstract interface class AgentEventStreamGateway {
  Future<AgentEventConnection> connect({
    required String runId,
    required int lastEventId,
  });
}

final class GeneratedAgentEventStreamGateway
    implements AgentEventStreamGateway {
  const GeneratedAgentEventStreamGateway(this._client);

  final AgentApiClient _client;

  @override
  Future<AgentEventConnection> connect({
    required String runId,
    required int lastEventId,
  }) async {
    final http.StreamedResponse response = await _client.streamRunEvents(
      runId: runId,
      lastEventId: lastEventId == 0 ? null : lastEventId,
    );
    return AgentEventConnection(response.stream);
  }
}

final class AgentEventConnection {
  const AgentEventConnection(this.body);

  final Stream<List<int>> body;
}

final class AgentRunEvent {
  const AgentRunEvent({
    required this.id,
    required this.type,
    required this.payload,
  });

  final int id;
  final String type;
  final Map<String, dynamic> payload;

  bool get isTerminal => const <String>{
    'cancelled',
    'succeeded',
    'blocked',
    'failed',
  }.contains(type);
}

final class AgentEventStreamException implements Exception {
  const AgentEventStreamException({
    required this.code,
    required this.retryable,
    this.httpStatus,
  });

  final String code;
  final bool retryable;
  final int? httpStatus;

  @override
  String toString() =>
      'AgentEventStreamException(code=$code, retryable=$retryable, httpStatus=${httpStatus ?? 'unavailable'})';
}

typedef AgentReconnectDelay = Future<void> Function(Duration duration);
typedef AgentEventCursorWriter = Future<void> Function(int lastEventId);

final class AgentEventStream {
  AgentEventStream({
    required AgentEventStreamGateway gateway,
    required AgentEventCursorWriter persistLastEventId,
    AgentReconnectDelay delay = _defaultDelay,
    int maximumReconnects = 15,
  }) : _gateway = gateway,
       _persistLastEventId = persistLastEventId,
       _delay = delay,
       _maximumReconnects = _validatedMaximumReconnects(maximumReconnects);

  final AgentEventStreamGateway _gateway;
  final AgentEventCursorWriter _persistLastEventId;
  final AgentReconnectDelay _delay;
  final int _maximumReconnects;

  Stream<AgentRunEvent> watch({
    required String runId,
    int initialLastEventId = 0,
  }) async* {
    if (runId.trim().isEmpty || initialLastEventId < 0) {
      throw const AgentEventStreamException(
        code: 'stream.invalid_request',
        retryable: false,
      );
    }

    int cursor = initialLastEventId;
    int reconnectsWithoutProgress = 0;
    while (true) {
      try {
        final AgentEventConnection connection = await _gateway.connect(
          runId: runId,
          lastEventId: cursor,
        );
        await for (final AgentRunEvent event in _SseParser.parse(
          connection.body,
        )) {
          if (event.id <= cursor) {
            continue;
          }
          try {
            await _persistLastEventId(event.id);
          } on Object {
            throw const AgentEventStreamException(
              code: 'stream.cursor_persist_failed',
              retryable: false,
            );
          }
          cursor = event.id;
          reconnectsWithoutProgress = 0;
          yield event;
          if (event.isTerminal) {
            return;
          }
        }
      } on Object catch (error) {
        final AgentEventStreamException failure = _mapFailure(error);
        if (!failure.retryable ||
            reconnectsWithoutProgress >= _maximumReconnects) {
          throw failure;
        }
        reconnectsWithoutProgress += 1;
        await _delay(_backoff(reconnectsWithoutProgress));
        continue;
      }

      if (reconnectsWithoutProgress >= _maximumReconnects) {
        throw const AgentEventStreamException(
          code: 'stream.reconnect_exhausted',
          retryable: true,
        );
      }
      reconnectsWithoutProgress += 1;
      await _delay(_backoff(reconnectsWithoutProgress));
    }
  }

  static AgentEventStreamException _mapFailure(Object error) {
    if (error is AgentEventStreamException) {
      return error;
    }
    if (error is AgentApiHttpException) {
      if (error.statusCode == 410) {
        return const AgentEventStreamException(
          code: 'stream.history_expired',
          retryable: false,
          httpStatus: 410,
        );
      }
      if (error.statusCode == 401 || error.statusCode == 403) {
        return AgentEventStreamException(
          code: 'stream.authorization_denied',
          retryable: false,
          httpStatus: error.statusCode,
        );
      }
      return AgentEventStreamException(
        code: 'stream.http_failure',
        retryable:
            error.statusCode == 408 ||
            error.statusCode == 429 ||
            error.statusCode >= 500,
        httpStatus: error.statusCode,
      );
    }
    if (error is AgentApiTransportException ||
        error is http.ClientException ||
        error is TimeoutException) {
      return const AgentEventStreamException(
        code: 'stream.network_failure',
        retryable: true,
      );
    }
    if (error is AgentApiProtocolException || error is FormatException) {
      return const AgentEventStreamException(
        code: 'stream.invalid_event',
        retryable: false,
      );
    }
    return const AgentEventStreamException(
      code: 'stream.unknown_failure',
      retryable: false,
    );
  }

  static Duration _backoff(int reconnectNumber) {
    final int shift = reconnectNumber.clamp(1, 6) - 1;
    return Duration(milliseconds: 250 * (1 << shift));
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  static int _validatedMaximumReconnects(int value) {
    if (value < 0 || value > 15) {
      throw ArgumentError.value(value, 'maximumReconnects');
    }
    return value;
  }
}

final class _SseParser {
  static const int _maximumDataBytes = 64 * 1024;
  static const Set<String> _allowedEventTypes = <String>{
    'run_created',
    'run_queued',
    'step_started',
    'step_completed',
    'tool_called',
    'tool_result',
    'candidate_ready',
    'waiting_input',
    'resuming',
    'recovering',
    'cancelling',
    'cancelled',
    'succeeded',
    'blocked',
    'failed',
  };

  static Stream<AgentRunEvent> parse(Stream<List<int>> body) async* {
    String? eventType;
    String? eventId;
    final List<String> data = <String>[];

    await for (final String line
        in body.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        final AgentRunEvent? event = _finish(
          eventType: eventType,
          eventId: eventId,
          data: data,
        );
        eventType = null;
        eventId = null;
        data.clear();
        if (event != null) {
          yield event;
        }
        continue;
      }
      if (line.startsWith(':')) {
        continue;
      }
      final int separator = line.indexOf(':');
      if (separator < 1) {
        throw const AgentApiProtocolException('sse.invalid_field');
      }
      final String field = line.substring(0, separator);
      final String rawValue = line.substring(separator + 1);
      final String value = rawValue.startsWith(' ')
          ? rawValue.substring(1)
          : rawValue;
      switch (field) {
        case 'event':
          if (eventType != null) {
            throw const AgentApiProtocolException('sse.duplicate_event_field');
          }
          eventType = value;
        case 'id':
          if (eventId != null) {
            throw const AgentApiProtocolException('sse.duplicate_id_field');
          }
          eventId = value;
        case 'data':
          data.add(value);
        default:
          throw const AgentApiProtocolException('sse.unknown_field');
      }
    }
    if (eventType != null || eventId != null || data.isNotEmpty) {
      throw const AgentApiProtocolException('sse.truncated_frame');
    }
  }

  static AgentRunEvent? _finish({
    required String? eventType,
    required String? eventId,
    required List<String> data,
  }) {
    if (eventType == null && eventId == null && data.isEmpty) {
      return null;
    }
    if (eventType == 'heartbeat' && eventId == null) {
      return null;
    }
    if (eventType == null ||
        !_allowedEventTypes.contains(eventType) ||
        eventId == null ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(eventId) ||
        data.isEmpty) {
      throw const AgentApiProtocolException('sse.invalid_business_event');
    }
    final int parsedId = int.parse(eventId);
    if (parsedId > 9_223_372_036_854_775_807) {
      throw const AgentApiProtocolException('sse.invalid_event_id');
    }
    final String encodedData = data.join('\n');
    if (utf8.encode(encodedData).length > _maximumDataBytes) {
      throw const AgentApiProtocolException('sse.data_too_large');
    }
    try {
      final Object? decoded = jsonDecode(encodedData);
      if (decoded is! Map) {
        throw const AgentApiProtocolException('sse.invalid_data');
      }
      return AgentRunEvent(
        id: parsedId,
        type: eventType,
        payload: Map<String, dynamic>.from(decoded),
      );
    } on AgentApiProtocolException {
      rethrow;
    } on Object {
      throw const AgentApiProtocolException('sse.invalid_data');
    }
  }
}
