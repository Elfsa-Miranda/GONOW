import 'package:flutter/foundation.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';

enum CandidateDecisionKind { requestAdoption, abandon }

enum CandidateDecisionState { pending, adoptionRequested, abandoned }

final class CandidateDecisionAuditEvent {
  const CandidateDecisionAuditEvent({
    required this.kind,
    required this.candidateId,
    required this.expectedVersion,
    required this.conflictAcknowledged,
  });

  final CandidateDecisionKind kind;
  final String candidateId;
  final int expectedVersion;
  final bool conflictAcknowledged;
}

abstract interface class CandidateDecisionAuditSink {
  Future<String> record(CandidateDecisionAuditEvent event);
}

final class CandidateDecisionReceipt {
  const CandidateDecisionReceipt({
    required this.kind,
    required this.candidateId,
    required this.expectedVersion,
    required this.auditReceiptId,
  });

  final CandidateDecisionKind kind;
  final String candidateId;
  final int expectedVersion;
  final String auditReceiptId;
}

final class CandidateDecisionController extends ChangeNotifier {
  CandidateDecisionController({
    required CandidatePreviewModel preview,
    required CandidateDecisionAuditSink auditSink,
  }) : _preview = preview,
       _auditSink = auditSink;

  final CandidatePreviewModel _preview;
  final CandidateDecisionAuditSink _auditSink;
  CandidateDecisionState _state = CandidateDecisionState.pending;
  bool _reviewAcknowledged = false;
  bool _conflictAcknowledged = false;
  bool _busy = false;

  CandidatePreviewModel get preview => _preview;
  CandidateDecisionState get state => _state;
  bool get reviewAcknowledged => _reviewAcknowledged;
  bool get conflictAcknowledged => _conflictAcknowledged;
  bool get busy => _busy;
  bool get canRequestAdoption =>
      !_busy &&
      _state == CandidateDecisionState.pending &&
      _reviewAcknowledged &&
      (!_preview.hasVersionConflict || _conflictAcknowledged);

  void setReviewAcknowledged(bool value) {
    if (_state != CandidateDecisionState.pending ||
        _reviewAcknowledged == value) {
      return;
    }
    _reviewAcknowledged = value;
    notifyListeners();
  }

  void setConflictAcknowledged(bool value) {
    if (_state != CandidateDecisionState.pending ||
        !_preview.hasVersionConflict ||
        _conflictAcknowledged == value) {
      return;
    }
    _conflictAcknowledged = value;
    notifyListeners();
  }

  Future<CandidateDecisionReceipt> requestAdoption() async {
    if (!canRequestAdoption) {
      throw const CandidateDecisionException('candidate.approval_required');
    }
    return _record(CandidateDecisionKind.requestAdoption);
  }

  Future<CandidateDecisionReceipt> abandon() {
    if (_busy || _state != CandidateDecisionState.pending) {
      throw const CandidateDecisionException('candidate.decision_final');
    }
    return _record(CandidateDecisionKind.abandon);
  }

  Future<CandidateDecisionReceipt> _record(CandidateDecisionKind kind) async {
    _busy = true;
    notifyListeners();
    try {
      final String auditReceiptId = await _auditSink.record(
        CandidateDecisionAuditEvent(
          kind: kind,
          candidateId: _preview.candidate.candidateId,
          expectedVersion: _preview.expectedVersion,
          conflictAcknowledged: _conflictAcknowledged,
        ),
      );
      if (auditReceiptId.trim().isEmpty) {
        throw const CandidateDecisionException(
          'candidate.audit_receipt_missing',
        );
      }
      _state = kind == CandidateDecisionKind.requestAdoption
          ? CandidateDecisionState.adoptionRequested
          : CandidateDecisionState.abandoned;
      return CandidateDecisionReceipt(
        kind: kind,
        candidateId: _preview.candidate.candidateId,
        expectedVersion: _preview.expectedVersion,
        auditReceiptId: auditReceiptId,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}

final class CandidateDecisionException implements Exception {
  const CandidateDecisionException(this.code);

  final String code;

  @override
  String toString() => 'CandidateDecisionException($code)';
}
