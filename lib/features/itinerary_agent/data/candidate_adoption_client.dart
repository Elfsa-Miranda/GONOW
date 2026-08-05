import 'dart:async';

final class OneUseApprovalCapability {
  OneUseApprovalCapability(String nonce) : _nonce = _validateNonce(nonce);

  String? _nonce;

  String consume() {
    final String? nonce = _nonce;
    if (nonce == null) {
      throw const CandidateAdoptionClientException(
        'approval_capability_consumed',
      );
    }
    _nonce = null;
    return nonce;
  }

  static String _validateNonce(String value) {
    if (value.length < 32 || value.length > 512) {
      throw const CandidateAdoptionClientException(
        'approval_capability_invalid',
      );
    }
    return value;
  }
}

final class CandidateActivityOperation {
  const CandidateActivityOperation({
    required this.activityId,
    required this.dayIndex,
    required this.position,
    required this.title,
    required this.evidenceIds,
    this.startsAt,
    this.note,
  });

  final String activityId;
  final int dayIndex;
  final int position;
  final String title;
  final DateTime? startsAt;
  final String? note;
  final List<String> evidenceIds;

  Map<String, Object?> toJson() => <String, Object?>{
    'activity_id': activityId,
    'day_index': dayIndex,
    'position': position,
    'title': title,
    'starts_at': startsAt?.toUtc().toIso8601String(),
    'note': note,
    'evidence_ids': List<String>.unmodifiable(evidenceIds),
  };
}

final class AdoptableCandidatePayload {
  const AdoptableCandidatePayload({
    required this.candidateId,
    required this.title,
    required this.startsOn,
    required this.endsOn,
    required this.activities,
  });

  final String candidateId;
  final String title;
  final DateTime startsOn;
  final DateTime endsOn;
  final List<CandidateActivityOperation> activities;

  Map<String, Object?> toJson() => <String, Object?>{
    'candidate_id': candidateId,
    'title': title,
    'starts_on': _date(startsOn),
    'ends_on': _date(endsOn),
    'activities': activities
        .map((CandidateActivityOperation item) => item.toJson())
        .toList(growable: false),
  };

  static String _date(DateTime value) {
    final String year = value.year.toString().padLeft(4, '0');
    final String month = value.month.toString().padLeft(2, '0');
    final String day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

final class CandidateAdoptionRequest {
  const CandidateAdoptionRequest({
    required this.commandId,
    required this.approvalId,
    required this.targetItineraryId,
    required this.runId,
    required this.expectedVersion,
    required this.capability,
    required this.candidate,
  });

  final String commandId;
  final String approvalId;
  final String targetItineraryId;
  final String runId;
  final int expectedVersion;
  final OneUseApprovalCapability capability;
  final AdoptableCandidatePayload candidate;

  Map<String, Object?> consumeJson() => <String, Object?>{
    'schema_version': '1.0',
    'command_id': commandId,
    'approval_id': approvalId,
    'target_itinerary_id': targetItineraryId,
    'run_id': runId,
    'expected_version': expectedVersion,
    'capability_nonce': capability.consume(),
    'candidate': candidate.toJson(),
  };
}

final class CandidateAdoptionReceipt {
  const CandidateAdoptionReceipt({
    required this.commandId,
    required this.approvalId,
    required this.candidateId,
    required this.itineraryId,
    required this.resultVersion,
    required this.candidateHash,
    required this.commandHash,
    required this.eventId,
    required this.outboxId,
    required this.auditReceiptId,
    required this.replayed,
  });

  final String commandId;
  final String approvalId;
  final String candidateId;
  final String itineraryId;
  final int resultVersion;
  final String candidateHash;
  final String commandHash;
  final String eventId;
  final String outboxId;
  final String auditReceiptId;
  final bool replayed;

  factory CandidateAdoptionReceipt.fromJson(Map<String, dynamic> json) {
    const Set<String> allowed = <String>{
      'command_id',
      'approval_id',
      'candidate_id',
      'itinerary_id',
      'result_version',
      'candidate_hash',
      'command_hash',
      'event_id',
      'outbox_id',
      'audit_receipt_id',
      'replayed',
    };
    if (json.keys.toSet().difference(allowed).isNotEmpty ||
        json.keys.length != allowed.length) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    final CandidateAdoptionReceipt receipt = CandidateAdoptionReceipt(
      commandId: _string(json, 'command_id'),
      approvalId: _string(json, 'approval_id'),
      candidateId: _string(json, 'candidate_id'),
      itineraryId: _string(json, 'itinerary_id'),
      resultVersion: _integer(json, 'result_version'),
      candidateHash: _hash(json, 'candidate_hash'),
      commandHash: _hash(json, 'command_hash'),
      eventId: _string(json, 'event_id'),
      outboxId: _string(json, 'outbox_id'),
      auditReceiptId: _string(json, 'audit_receipt_id'),
      replayed: _boolean(json, 'replayed'),
    );
    if (receipt.resultVersion < 1) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    return receipt;
  }

  static String _string(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    return value;
  }

  static int _integer(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! int) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    return value;
  }

  static bool _boolean(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! bool) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    return value;
  }

  static String _hash(Map<String, dynamic> json, String key) {
    final String value = _string(json, key);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const CandidateAdoptionClientException('adoption_response_invalid');
    }
    return value;
  }
}

abstract interface class CandidateAdoptionTransport {
  Future<Map<String, dynamic>> adopt(Map<String, Object?> request);
}

final class CandidateAdoptionClient {
  const CandidateAdoptionClient({
    required CandidateAdoptionTransport transport,
    Duration timeout = const Duration(seconds: 35),
  }) : _transport = transport,
       _timeout = timeout;

  final CandidateAdoptionTransport _transport;
  final Duration _timeout;

  Future<CandidateAdoptionReceipt> adopt(
    CandidateAdoptionRequest request,
  ) async {
    _validateRequest(request);
    try {
      final Map<String, dynamic> response = await _transport
          .adopt(request.consumeJson())
          .timeout(_timeout);
      return CandidateAdoptionReceipt.fromJson(response);
    } on CandidateAdoptionClientException {
      rethrow;
    } on TimeoutException {
      throw const CandidateAdoptionClientException('adoption_timeout');
    } on Object {
      throw const CandidateAdoptionClientException('adoption_failed');
    }
  }

  static void _validateRequest(CandidateAdoptionRequest request) {
    final bool invalid =
        request.commandId.trim().isEmpty ||
        request.approvalId.trim().isEmpty ||
        request.targetItineraryId.trim().isEmpty ||
        request.runId.trim().isEmpty ||
        request.expectedVersion < 0 ||
        request.candidate.candidateId.trim().isEmpty ||
        request.candidate.title.trim().isEmpty ||
        request.candidate.endsOn.isBefore(request.candidate.startsOn) ||
        request.candidate.activities.isEmpty;
    if (invalid) {
      throw const CandidateAdoptionClientException('adoption_request_invalid');
    }
  }
}

final class CandidateAdoptionClientException implements Exception {
  const CandidateAdoptionClientException(this.code);

  final String code;

  @override
  String toString() => 'CandidateAdoptionClientException($code)';
}
