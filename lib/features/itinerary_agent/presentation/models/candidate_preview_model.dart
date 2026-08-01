enum CandidateDiffKind { added, removed, changed }

final class CandidateDiffEntry {
  const CandidateDiffEntry({
    required this.path,
    required this.kind,
    required this.before,
    required this.after,
  });

  final String path;
  final CandidateDiffKind kind;
  final String? before;
  final String? after;
}

final class CandidateWarning {
  const CandidateWarning({required this.code, required this.message});

  final String code;
  final String message;
}

final class CandidateCitationView {
  const CandidateCitationView({
    required this.claimId,
    required this.evidenceId,
    required this.sourceRef,
    required this.sha256,
  });

  final String claimId;
  final String evidenceId;
  final String sourceRef;
  final String sha256;
}

final class CandidateItemView {
  const CandidateItemView({
    required this.itemId,
    required this.title,
    required this.startMinute,
    required this.durationMinutes,
    required this.claimIds,
  });

  final String itemId;
  final String title;
  final int startMinute;
  final int durationMinutes;
  final List<String> claimIds;

  String get startLabel {
    final int hour = startMinute ~/ 60;
    final int minute = startMinute % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}

final class CandidateDayView {
  const CandidateDayView({required this.dayNumber, required this.items});

  final int dayNumber;
  final List<CandidateItemView> items;
}

final class ItineraryCandidateView {
  const ItineraryCandidateView({
    required this.candidateId,
    required this.runId,
    required this.behaviorDigest,
    required this.inputDigest,
    required this.title,
    required this.days,
    required this.citations,
    required this.evidenceRefs,
  });

  factory ItineraryCandidateView.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const <String>{
      'schema_version',
      'candidate_id',
      'run_id',
      'behavior_digest',
      'input_digest',
      'title',
      'days',
      'citations',
      'evidence_refs',
      'status',
    });
    if (json['schema_version'] != '1.0' || json['status'] != 'candidate') {
      throw const CandidatePreviewException('candidate.invalid_schema');
    }
    final String candidateId = _string(json, 'candidate_id');
    final String behaviorDigest = _string(json, 'behavior_digest');
    final String inputDigest = _string(json, 'input_digest');
    if (!RegExp(r'^cand_[0-9a-f]{32}$').hasMatch(candidateId) ||
        !_sha256.hasMatch(behaviorDigest) ||
        !_sha256.hasMatch(inputDigest)) {
      throw const CandidatePreviewException('candidate.invalid_identity');
    }

    final List<dynamic> rawDays = _list(json, 'days');
    if (rawDays.isEmpty || rawDays.length > 31) {
      throw const CandidatePreviewException('candidate.invalid_days');
    }
    final List<CandidateDayView> days = rawDays
        .map((Object? value) {
          final Map<String, dynamic> day = _map(value);
          _requireExactKeys(day, const <String>{'day_number', 'items'});
          final int dayNumber = _integer(day, 'day_number');
          final List<dynamic> rawItems = _list(day, 'items');
          if (dayNumber < 1 ||
              dayNumber > 31 ||
              rawItems.isEmpty ||
              rawItems.length > 30) {
            throw const CandidatePreviewException('candidate.invalid_day');
          }
          return CandidateDayView(
            dayNumber: dayNumber,
            items: rawItems
                .map((Object? itemValue) {
                  final Map<String, dynamic> item = _map(itemValue);
                  _requireExactKeys(item, const <String>{
                    'item_id',
                    'title',
                    'start_minute',
                    'duration_minutes',
                    'claim_ids',
                  });
                  final String itemId = _string(item, 'item_id');
                  final String title = _string(item, 'title');
                  final int start = _integer(item, 'start_minute');
                  final int duration = _integer(item, 'duration_minutes');
                  final List<dynamic> rawClaims = _list(item, 'claim_ids');
                  if (!RegExp(r'^item_[a-z0-9_-]{1,80}$').hasMatch(itemId) ||
                      title.length > 160 ||
                      start < 0 ||
                      start >= 1440 ||
                      duration < 1 ||
                      duration > 1440 ||
                      rawClaims.any((Object? value) => value is! String)) {
                    throw const CandidatePreviewException(
                      'candidate.invalid_item',
                    );
                  }
                  return CandidateItemView(
                    itemId: itemId,
                    title: title,
                    startMinute: start,
                    durationMinutes: duration,
                    claimIds: List<String>.unmodifiable(
                      rawClaims.cast<String>(),
                    ),
                  );
                })
                .toList(growable: false),
          );
        })
        .toList(growable: false);

    final List<CandidateCitationView> citations = _list(json, 'citations')
        .map((Object? value) {
          final Map<String, dynamic> citation = _map(value);
          _requireExactKeys(citation, const <String>{
            'claim_id',
            'evidence_id',
            'source_ref',
            'sha256',
          });
          final String sourceRef = _string(citation, 'source_ref');
          final String digest = _string(citation, 'sha256');
          if (!sourceRef.startsWith('evidence://') ||
              !_sha256.hasMatch(digest)) {
            throw const CandidatePreviewException('candidate.invalid_citation');
          }
          return CandidateCitationView(
            claimId: _string(citation, 'claim_id'),
            evidenceId: _string(citation, 'evidence_id'),
            sourceRef: sourceRef,
            sha256: digest,
          );
        })
        .toList(growable: false);
    final List<dynamic> rawRefs = _list(json, 'evidence_refs');
    if (rawRefs.any((Object? value) => value is! String)) {
      throw const CandidatePreviewException('candidate.invalid_evidence_refs');
    }
    final List<String> evidenceRefs = rawRefs.cast<String>();
    if (evidenceRefs.any((String value) => !value.startsWith('evidence://')) ||
        evidenceRefs.toSet().length != evidenceRefs.length) {
      throw const CandidatePreviewException('candidate.invalid_evidence_refs');
    }
    return ItineraryCandidateView(
      candidateId: candidateId,
      runId: _string(json, 'run_id'),
      behaviorDigest: behaviorDigest,
      inputDigest: inputDigest,
      title: _string(json, 'title'),
      days: List<CandidateDayView>.unmodifiable(days),
      citations: List<CandidateCitationView>.unmodifiable(citations),
      evidenceRefs: List<String>.unmodifiable(evidenceRefs),
    );
  }

  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

  final String candidateId;
  final String runId;
  final String behaviorDigest;
  final String inputDigest;
  final String title;
  final List<CandidateDayView> days;
  final List<CandidateCitationView> citations;
  final List<String> evidenceRefs;
}

final class CurrentItineraryItem {
  const CurrentItineraryItem({
    required this.itemId,
    required this.title,
    required this.startMinute,
    required this.durationMinutes,
  });

  final String itemId;
  final String title;
  final int startMinute;
  final int durationMinutes;
}

final class CurrentItinerarySnapshot {
  const CurrentItinerarySnapshot({
    required this.version,
    required this.title,
    required this.items,
  });

  final int version;
  final String title;
  final List<CurrentItineraryItem> items;
}

final class CandidatePreviewModel {
  CandidatePreviewModel({
    required this.candidate,
    required this.current,
    required this.expectedVersion,
    List<CandidateWarning> warnings = const <CandidateWarning>[],
  }) : warnings = List<CandidateWarning>.unmodifiable(warnings),
       diff = List<CandidateDiffEntry>.unmodifiable(
         _buildDiff(candidate, current),
       );

  final ItineraryCandidateView candidate;
  final CurrentItinerarySnapshot current;
  final int expectedVersion;
  final List<CandidateWarning> warnings;
  final List<CandidateDiffEntry> diff;

  bool get hasVersionConflict => current.version != expectedVersion;

  static List<CandidateDiffEntry> _buildDiff(
    ItineraryCandidateView candidate,
    CurrentItinerarySnapshot current,
  ) {
    final List<CandidateDiffEntry> entries = <CandidateDiffEntry>[];
    if (candidate.title != current.title) {
      entries.add(
        CandidateDiffEntry(
          path: 'title',
          kind: CandidateDiffKind.changed,
          before: current.title,
          after: candidate.title,
        ),
      );
    }
    final Map<String, CurrentItineraryItem> before =
        <String, CurrentItineraryItem>{
          for (final CurrentItineraryItem item in current.items)
            item.itemId: item,
        };
    final Map<String, CandidateItemView> after = <String, CandidateItemView>{
      for (final CandidateDayView day in candidate.days)
        for (final CandidateItemView item in day.items) item.itemId: item,
    };
    final List<String> ids = <String>{...before.keys, ...after.keys}.toList()
      ..sort();
    for (final String id in ids) {
      final CurrentItineraryItem? oldItem = before[id];
      final CandidateItemView? newItem = after[id];
      if (oldItem == null) {
        entries.add(
          CandidateDiffEntry(
            path: 'items.$id',
            kind: CandidateDiffKind.added,
            before: null,
            after: newItem!.title,
          ),
        );
        continue;
      }
      if (newItem == null) {
        entries.add(
          CandidateDiffEntry(
            path: 'items.$id',
            kind: CandidateDiffKind.removed,
            before: oldItem.title,
            after: null,
          ),
        );
        continue;
      }
      _changed(entries, 'items.$id.title', oldItem.title, newItem.title);
      _changed(
        entries,
        'items.$id.start_minute',
        '${oldItem.startMinute}',
        '${newItem.startMinute}',
      );
      _changed(
        entries,
        'items.$id.duration_minutes',
        '${oldItem.durationMinutes}',
        '${newItem.durationMinutes}',
      );
    }
    return entries;
  }

  static void _changed(
    List<CandidateDiffEntry> entries,
    String path,
    String before,
    String after,
  ) {
    if (before != after) {
      entries.add(
        CandidateDiffEntry(
          path: path,
          kind: CandidateDiffKind.changed,
          before: before,
          after: after,
        ),
      );
    }
  }
}

final class CandidatePreviewException implements Exception {
  const CandidatePreviewException(this.code);

  final String code;

  @override
  String toString() => 'CandidatePreviewException($code)';
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) {
    throw const CandidatePreviewException('candidate.invalid_object');
  }
  try {
    return Map<String, dynamic>.from(value);
  } on Object {
    throw const CandidatePreviewException('candidate.invalid_object');
  }
}

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! List) {
    throw CandidatePreviewException('candidate.invalid_$key');
  }
  return value;
}

String _string(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw CandidatePreviewException('candidate.invalid_$key');
  }
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw CandidatePreviewException('candidate.invalid_$key');
  }
  return value;
}

void _requireExactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.length != expected.length ||
      json.keys.any((String key) => !expected.contains(key))) {
    throw const CandidatePreviewException('candidate.unknown_field');
  }
}
