// GENERATED CODE - DO NOT MODIFY BY HAND.

final class AgentApiProtocolException implements Exception {
  const AgentApiProtocolException(this.code);

  final String code;

  @override
  String toString() => 'AgentApiProtocolException($code)';
}

Map<String, dynamic> _object(Object? value, String schema) {
  if (value is! Map) {
    throw AgentApiProtocolException('$schema.invalid_object');
  }
  return Map<String, dynamic>.from(value);
}

void _keys(Map<String, dynamic> json, String schema, Set<String> allowed) {
  if (json.keys.any((String key) => !allowed.contains(key))) {
    throw AgentApiProtocolException('$schema.unknown_field');
  }
}

T _required<T>(Map<String, dynamic> json, String schema, String key) {
  final Object? value = json[key];
  if (value is! T) {
    throw AgentApiProtocolException('$schema.invalid_$key');
  }
  return value;
}

final class HealthProbe {
  const HealthProbe({required this.status, required this.reasonCodes});

  factory HealthProbe.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'health_probe');
    _keys(json, 'health_probe', const <String>{'status', 'reason_codes'});
    final String status = _required<String>(json, 'health_probe', 'status');
    if (!const <String>{'live', 'ready', 'not_ready'}.contains(status)) {
      throw const AgentApiProtocolException('health_probe.invalid_status');
    }
    final List<dynamic> reasons = _required<List<dynamic>>(
      json,
      'health_probe',
      'reason_codes',
    );
    if (reasons.length > 8 || reasons.any((Object? item) => item is! String)) {
      throw const AgentApiProtocolException(
        'health_probe.invalid_reason_codes',
      );
    }
    return HealthProbe(status: status, reasonCodes: reasons.cast<String>());
  }

  final String status;
  final List<String> reasonCodes;
}

final class ContractDescriptor {
  const ContractDescriptor({
    required this.name,
    required this.major,
    required this.version,
    required this.specSha256,
  });

  factory ContractDescriptor.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'contract_descriptor');
    _keys(json, 'contract_descriptor', const <String>{
      'name',
      'major',
      'version',
      'spec_sha256',
    });
    final ContractDescriptor descriptor = ContractDescriptor(
      name: _required<String>(json, 'contract_descriptor', 'name'),
      major: _required<int>(json, 'contract_descriptor', 'major'),
      version: _required<String>(json, 'contract_descriptor', 'version'),
      specSha256: _required<String>(json, 'contract_descriptor', 'spec_sha256'),
    );
    if (descriptor.name != 'agent-api' ||
        descriptor.major != 1 ||
        descriptor.version != '1.0.0' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(descriptor.specSha256)) {
      throw const AgentApiProtocolException('contract_descriptor.invalid');
    }
    return descriptor;
  }

  final String name;
  final int major;
  final String version;
  final String specSha256;
}

final class ResumeRequest {
  const ResumeRequest({
    required this.resumeToken,
    required this.interruptId,
    required this.commandHash,
    required this.commandVersion,
  });

  final String resumeToken;
  final String interruptId;
  final String commandHash;
  final String commandVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'resume_token': resumeToken,
    'interrupt_id': interruptId,
    'command_hash': commandHash,
    'command_version': commandVersion,
  };
}

final class ResumeResponse {
  const ResumeResponse({
    required this.status,
    required this.runId,
    required this.interruptId,
    required this.commandVersion,
  });

  factory ResumeResponse.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'resume_response');
    _keys(json, 'resume_response', const <String>{
      'status',
      'run_id',
      'interrupt_id',
      'command_version',
    });
    final String status = _required<String>(json, 'resume_response', 'status');
    if (status != 'resumed') {
      throw const AgentApiProtocolException('resume_response.invalid_status');
    }
    return ResumeResponse(
      status: status,
      runId: _required<String>(json, 'resume_response', 'run_id'),
      interruptId: _required<String>(json, 'resume_response', 'interrupt_id'),
      commandVersion: _required<String>(
        json,
        'resume_response',
        'command_version',
      ),
    );
  }

  final String status;
  final String runId;
  final String interruptId;
  final String commandVersion;
}

final class CancelRequest {
  const CancelRequest({required this.expectedVersion});

  final int expectedVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'expected_version': expectedVersion,
  };
}

final class CancelResponse {
  const CancelResponse({
    required this.status,
    required this.runId,
    required this.version,
    required this.replayed,
  });

  factory CancelResponse.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'cancel_response');
    _keys(json, 'cancel_response', const <String>{
      'status',
      'run_id',
      'version',
      'replayed',
    });
    final String status = _required<String>(json, 'cancel_response', 'status');
    if (!const <String>{'cancelling', 'cancelled'}.contains(status)) {
      throw const AgentApiProtocolException('cancel_response.invalid_status');
    }
    return CancelResponse(
      status: status,
      runId: _required<String>(json, 'cancel_response', 'run_id'),
      version: _required<int>(json, 'cancel_response', 'version'),
      replayed: _required<bool>(json, 'cancel_response', 'replayed'),
    );
  }

  final String status;
  final String runId;
  final int version;
  final bool replayed;
}

final class PublicError {
  const PublicError({
    required this.code,
    required this.message,
    required this.requestId,
    this.retryAfterSeconds,
  });

  factory PublicError.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'public_error');
    _keys(json, 'public_error', const <String>{
      'code',
      'message',
      'request_id',
      'retry_after_seconds',
    });
    final int? retryAfterSeconds = json['retry_after_seconds'] as int?;
    if (retryAfterSeconds != null &&
        (retryAfterSeconds < 1 || retryAfterSeconds > 86400)) {
      throw const AgentApiProtocolException('public_error.invalid_retry_after');
    }
    return PublicError(
      code: _required<String>(json, 'public_error', 'code'),
      message: _required<String>(json, 'public_error', 'message'),
      requestId: _required<String>(json, 'public_error', 'request_id'),
      retryAfterSeconds: retryAfterSeconds,
    );
  }

  final String code;
  final String message;
  final String requestId;
  final int? retryAfterSeconds;
}

final class ErrorEnvelope {
  const ErrorEnvelope({required this.error});

  factory ErrorEnvelope.fromJson(Object? value) {
    final Map<String, dynamic> json = _object(value, 'error_envelope');
    _keys(json, 'error_envelope', const <String>{'error'});
    return ErrorEnvelope(error: PublicError.fromJson(json['error']));
  }

  final PublicError error;
}
