import 'dart:async';

enum ItineraryBasicInfoCommandState { committed, conflict, denied, rejected }

final class ItineraryBasicInfoCommandPatch {
  const ItineraryBasicInfoCommandPatch({
    required this.title,
    required this.destination,
    required this.startDate,
    required this.endDate,
    required this.budget,
    required this.actualCost,
    required this.tags,
  });

  final String title;
  final String destination;
  final DateTime startDate;
  final DateTime endDate;
  final String budget;
  final String actualCost;
  final List<String> tags;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'destination': destination,
    'start_date': _date(startDate),
    'end_date': _date(endDate),
    'budget': budget,
    'actual_cost': actualCost,
    'tags': List<String>.unmodifiable(tags),
  };

  static String _date(DateTime value) {
    final String year = value.year.toString().padLeft(4, '0');
    final String month = value.month.toString().padLeft(2, '0');
    final String day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}

final class ItineraryBasicInfoCommandRequest {
  const ItineraryBasicInfoCommandRequest({
    required this.commandId,
    required this.idempotencyKey,
    required this.targetItineraryId,
    required this.expectedVersion,
    required this.patch,
  });

  final String commandId;
  final String idempotencyKey;
  final String targetItineraryId;
  final int expectedVersion;
  final ItineraryBasicInfoCommandPatch patch;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': '1.0',
    'command_id': commandId,
    'expected_version': expectedVersion,
    'patch': patch.toJson(),
  };
}

final class ItineraryBasicInfoCommandReceipt {
  const ItineraryBasicInfoCommandReceipt({
    required this.commandId,
    required this.state,
    required this.expectedVersion,
    required this.actualVersion,
    required this.eventId,
    required this.outboxId,
    required this.recordedAt,
    required this.replayed,
  });

  final String commandId;
  final ItineraryBasicInfoCommandState state;
  final int expectedVersion;
  final int? actualVersion;
  final String? eventId;
  final String? outboxId;
  final DateTime recordedAt;
  final bool replayed;

  factory ItineraryBasicInfoCommandReceipt.fromJson(Map<String, dynamic> json) {
    const Set<String> allowed = <String>{
      'schema_version',
      'command_type',
      'command_id',
      'state',
      'target_digest',
      'principal_digest',
      'idempotency_digest',
      'command_hash',
      'approval_reference',
      'expected_version',
      'actual_version',
      'event_id',
      'outbox_id',
      'policy_digest',
      'schema_digest',
      'recorded_at',
      'replayed',
    };
    if (json.keys.toSet().difference(allowed).isNotEmpty ||
        json.keys.length != allowed.length ||
        json['schema_version'] != '1.0' ||
        json['command_type'] != 'itinerary.basic_info.update' ||
        json['approval_reference'] !=
            'policy:itinerary.basic_info.low-risk:v1') {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    for (final String key in <String>[
      'target_digest',
      'principal_digest',
      'idempotency_digest',
      'command_hash',
      'policy_digest',
      'schema_digest',
    ]) {
      _hash(json, key);
    }
    final String stateValue = _string(json, 'state');
    final ItineraryBasicInfoCommandState state = ItineraryBasicInfoCommandState
        .values
        .firstWhere(
          (ItineraryBasicInfoCommandState value) => value.name == stateValue,
          orElse: () => throw const ItineraryBasicInfoCommandClientException(
            'domain_command.receipt_invalid',
          ),
        );
    final Object? expectedRaw = json['expected_version'];
    final Object? actualRaw = json['actual_version'];
    final Object? replayedRaw = json['replayed'];
    final DateTime? recordedAt = DateTime.tryParse(
      _string(json, 'recorded_at'),
    );
    if (expectedRaw is! int ||
        expectedRaw < 0 ||
        (actualRaw != null && actualRaw is! int) ||
        replayedRaw is! bool ||
        recordedAt == null) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    final int? actualVersion = actualRaw as int?;
    final String? eventId = _nullableUuid(json, 'event_id');
    final String? outboxId = _nullableUuid(json, 'outbox_id');
    final bool committed = state == ItineraryBasicInfoCommandState.committed;
    if ((committed &&
            (actualVersion != expectedRaw + 1 ||
                eventId == null ||
                outboxId == null)) ||
        (!committed &&
            (actualVersion != null || eventId != null || outboxId != null))) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    return ItineraryBasicInfoCommandReceipt(
      commandId: _uuid(json, 'command_id'),
      state: state,
      expectedVersion: expectedRaw,
      actualVersion: actualVersion,
      eventId: eventId,
      outboxId: outboxId,
      recordedAt: recordedAt.toUtc(),
      replayed: replayedRaw,
    );
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  static String _string(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    return value;
  }

  static String _uuid(Map<String, dynamic> json, String key) {
    final String value = _string(json, key);
    if (!_uuidPattern.hasMatch(value)) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    return value;
  }

  static String? _nullableUuid(Map<String, dynamic> json, String key) {
    if (json[key] == null) return null;
    return _uuid(json, key);
  }

  static String _hash(Map<String, dynamic> json, String key) {
    final String value = _string(json, key);
    if (!_hashPattern.hasMatch(value)) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    return value;
  }
}

abstract interface class ItineraryBasicInfoCommandTransport {
  Future<Map<String, dynamic>> submit({
    required String targetItineraryId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  });

  Future<Map<String, dynamic>?> lookup({
    required String targetItineraryId,
    required String idempotencyKey,
  });
}

final class ItineraryBasicInfoCommandTransportException implements Exception {
  const ItineraryBasicInfoCommandTransportException(
    this.code, {
    required this.outcomeUnknown,
  });

  final String code;
  final bool outcomeUnknown;
}

final class ItineraryBasicInfoCommandClient {
  const ItineraryBasicInfoCommandClient({
    required ItineraryBasicInfoCommandTransport transport,
    Duration timeout = const Duration(seconds: 20),
  }) : _transport = transport,
       _timeout = timeout;

  final ItineraryBasicInfoCommandTransport _transport;
  final Duration _timeout;

  Future<ItineraryBasicInfoCommandReceipt> execute(
    ItineraryBasicInfoCommandRequest request,
  ) async {
    _validateRequest(request);
    try {
      final Map<String, dynamic> response = await _transport
          .submit(
            targetItineraryId: request.targetItineraryId,
            idempotencyKey: request.idempotencyKey,
            body: request.toJson(),
          )
          .timeout(_timeout);
      return _validateReceipt(response, request);
    } on ItineraryBasicInfoCommandTransportException catch (error) {
      if (!error.outcomeUnknown) {
        throw ItineraryBasicInfoCommandClientException(error.code);
      }
      return _recoverUnknownOutcome(request);
    } on TimeoutException {
      return _recoverUnknownOutcome(request);
    } on ItineraryBasicInfoCommandClientException {
      rethrow;
    } on Object {
      return _recoverUnknownOutcome(request);
    }
  }

  Future<ItineraryBasicInfoCommandReceipt?> lookup(
    ItineraryBasicInfoCommandRequest request,
  ) async {
    _validateRequest(request);
    try {
      final Map<String, dynamic>? response = await _transport
          .lookup(
            targetItineraryId: request.targetItineraryId,
            idempotencyKey: request.idempotencyKey,
          )
          .timeout(_timeout);
      return response == null ? null : _validateReceipt(response, request);
    } on ItineraryBasicInfoCommandClientException {
      rethrow;
    } on Object {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.outcome_unknown',
      );
    }
  }

  Future<ItineraryBasicInfoCommandReceipt> _recoverUnknownOutcome(
    ItineraryBasicInfoCommandRequest request,
  ) async {
    final ItineraryBasicInfoCommandReceipt? recovered = await lookup(request);
    if (recovered == null) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.outcome_unknown',
      );
    }
    return recovered;
  }

  static ItineraryBasicInfoCommandReceipt _validateReceipt(
    Map<String, dynamic> response,
    ItineraryBasicInfoCommandRequest request,
  ) {
    final ItineraryBasicInfoCommandReceipt receipt =
        ItineraryBasicInfoCommandReceipt.fromJson(response);
    if (receipt.commandId != request.commandId ||
        receipt.expectedVersion != request.expectedVersion) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.receipt_invalid',
      );
    }
    return receipt;
  }

  static void _validateRequest(ItineraryBasicInfoCommandRequest request) {
    final ItineraryBasicInfoCommandPatch patch = request.patch;
    final double? budget = double.tryParse(patch.budget);
    final double? actualCost = double.tryParse(patch.actualCost);
    final List<String> normalizedTags = patch.tags
        .map((String tag) => tag.trim().toLowerCase())
        .toList(growable: false);
    final bool invalid =
        !ItineraryBasicInfoCommandReceipt._uuidPattern.hasMatch(
          request.commandId,
        ) ||
        !ItineraryBasicInfoCommandReceipt._uuidPattern.hasMatch(
          request.targetItineraryId,
        ) ||
        request.idempotencyKey.length < 16 ||
        request.idempotencyKey.length > 128 ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9_.:/-]+$',
        ).hasMatch(request.idempotencyKey) ||
        request.expectedVersion < 0 ||
        patch.title.trim().isEmpty ||
        patch.title.length > 160 ||
        patch.destination.trim().isEmpty ||
        patch.destination.length > 160 ||
        patch.endDate.isBefore(patch.startDate) ||
        patch.tags.length > 16 ||
        patch.tags.any(
          (String tag) =>
              tag.trim().isEmpty ||
              tag.length > 48 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(tag),
        ) ||
        normalizedTags.toSet().length != normalizedTags.length ||
        !RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(patch.budget) ||
        budget == null ||
        !budget.isFinite ||
        budget < 0 ||
        budget > 9999999999.99 ||
        !RegExp(r'^\d{1,10}(?:\.\d{1,2})?$').hasMatch(patch.actualCost) ||
        actualCost == null ||
        !actualCost.isFinite ||
        actualCost < 0 ||
        actualCost > 9999999999.99;
    if (invalid) {
      throw const ItineraryBasicInfoCommandClientException(
        'domain_command.request_invalid',
      );
    }
  }
}

final class ItineraryBasicInfoCommandClientException implements Exception {
  const ItineraryBasicInfoCommandClientException(this.code);

  final String code;

  @override
  String toString() => 'ItineraryBasicInfoCommandClientException($code)';
}
