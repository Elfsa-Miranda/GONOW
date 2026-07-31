import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _fixturePath =
    'test/fixtures/validation/validation_semantics_cases.json';
const String _schemaPath = 'contracts/validation-semantics-v1.schema.json';

Map<String, dynamic> _asMap(Object? value) =>
    Map<String, dynamic>.from(value! as Map<dynamic, dynamic>);

List<String> _validateResult(Map<String, dynamic> result) {
  final List<String> errors = <String>[];
  const Set<String> classifications = <String>{
    'hard',
    'warning',
    'unverified',
    'verified',
  };
  if (result['schema_version'] != '1.0') errors.add('schema_version');
  final String resultId = result['result_id']?.toString() ?? '';
  if (!RegExp(r'^val_[a-z0-9][a-z0-9_-]{7,63}$').hasMatch(resultId)) {
    errors.add('result_id');
  }
  final String classification = result['classification']?.toString() ?? '';
  if (!classifications.contains(classification)) errors.add('classification');

  final Object? findingsRaw = result['findings'];
  if (findingsRaw is! List<dynamic> || findingsRaw.length > 100) {
    errors.add('findings');
    return errors;
  }
  final List<Map<String, dynamic>> findings = findingsRaw
      .whereType<Map<dynamic, dynamic>>()
      .map(Map<String, dynamic>.from)
      .toList(growable: false);
  if (findings.length != findingsRaw.length) errors.add('finding_type');
  for (final Map<String, dynamic> finding in findings) {
    if (!const <String>{
      'hard',
      'warning',
      'unverified',
    }.contains(finding['classification'])) {
      errors.add('finding_classification');
    }
    if (!RegExp(
      r'^[A-Z][A-Z0-9_]{2,63}$',
    ).hasMatch(finding['code']?.toString() ?? '')) {
      errors.add('finding_code');
    }
    if (!RegExp(
      r'^(/([^/~]|~[01])*)*$',
    ).hasMatch(finding['field_path']?.toString() ?? '')) {
      errors.add('field_path');
    }
  }

  final Map<String, dynamic> candidate = _asMap(result['candidate_import']);
  if (candidate['allowed'] != true) errors.add('candidate_allowed');
  if (candidate['requires_user_confirmation'] != true) {
    errors.add('confirmation');
  }
  if (candidate['domain_write_allowed'] != false) {
    errors.add('candidate_domain_write');
  }
  final Map<String, dynamic> fallback = _asMap(result['fallback']);
  if (fallback['available'] != true) errors.add('fallback_available');
  if (fallback['preserves_user_input'] != true) {
    errors.add('fallback_preserves_input');
  }
  if (fallback['domain_write_allowed'] != false) {
    errors.add('fallback_domain_write');
  }

  bool hasFinding(String value) => findings.any(
    (Map<String, dynamic> finding) => finding['classification'] == value,
  );
  switch (classification) {
    case 'hard':
      if (!hasFinding('hard')) errors.add('hard_finding');
      if (candidate['mode'] != 'raw_candidate_draft') {
        errors.add('hard_import_mode');
      }
      if (fallback['mode'] != 'raw_input_draft') {
        errors.add('hard_fallback_mode');
      }
      break;
    case 'warning':
      if (!hasFinding('warning')) errors.add('warning_finding');
      if (candidate['mode'] != 'normalized_candidate_draft') {
        errors.add('warning_import_mode');
      }
      if (fallback['mode'] != 'normalized_candidate') {
        errors.add('warning_fallback_mode');
      }
      break;
    case 'unverified':
      if (!hasFinding('unverified')) errors.add('unverified_finding');
      if (candidate['mode'] != 'original_candidate_draft') {
        errors.add('unverified_import_mode');
      }
      if (fallback['mode'] != 'original_candidate') {
        errors.add('unverified_fallback_mode');
      }
      break;
    case 'verified':
      if (findings.isNotEmpty) errors.add('verified_findings');
      if (candidate['mode'] != 'normalized_candidate_draft') {
        errors.add('verified_import_mode');
      }
      if (fallback['mode'] != 'normalized_candidate') {
        errors.add('verified_fallback_mode');
      }
      break;
  }

  final Map<String, dynamic> provenance = _asMap(result['provenance']);
  if (provenance.values.any(
    (Object? value) => value.toString().trim().isEmpty,
  )) {
    errors.add('provenance');
  }
  if (DateTime.tryParse(provenance['validated_at']?.toString() ?? '') == null) {
    errors.add('validated_at');
  }
  return errors;
}

void main() {
  late Map<String, dynamic> fixtureDocument;
  late List<Map<String, dynamic>> cases;

  setUpAll(() {
    fixtureDocument = _asMap(jsonDecode(File(_fixturePath).readAsStringSync()));
    cases = (fixtureDocument['cases']! as List<dynamic>)
        .map((dynamic value) => _asMap(value))
        .toList(growable: false);
  });

  test('contract keeps Candidate import separate from domain writes', () {
    final Map<String, dynamic> schema = _asMap(
      jsonDecode(File(_schemaPath).readAsStringSync()),
    );
    final Map<String, dynamic> properties = _asMap(schema['properties']);
    final Set<String> classifications =
        (_asMap(properties['classification'])['enum']! as List<dynamic>)
            .cast<String>()
            .toSet();
    expect(classifications, <String>{
      'hard',
      'warning',
      'unverified',
      'verified',
    });
    final Map<String, dynamic> definitions = _asMap(schema[r'$defs']);
    final Map<String, dynamic> candidateProperties = _asMap(
      _asMap(definitions['candidateImport'])['properties'],
    );
    final Map<String, dynamic> fallbackProperties = _asMap(
      _asMap(definitions['fallback'])['properties'],
    );
    expect(_asMap(candidateProperties['allowed'])['const'], isTrue);
    expect(
      _asMap(candidateProperties['domain_write_allowed'])['const'],
      isFalse,
    );
    expect(_asMap(fallbackProperties['preserves_user_input'])['const'], isTrue);
    expect(
      _asMap(fallbackProperties['domain_write_allowed'])['const'],
      isFalse,
    );
  });

  test('numbered synthetic fixtures are complete and deterministic', () {
    expect(fixtureDocument['synthetic_only'], isTrue);
    expect(cases, hasLength(8));
    final Set<String> ids = cases
        .map((Map<String, dynamic> value) => value['fixture_id']! as String)
        .toSet();
    expect(ids, hasLength(cases.length));
    for (final String classification in <String>[
      'hard',
      'warning',
      'unverified',
    ]) {
      expect(
        cases.where(
          (Map<String, dynamic> value) =>
              value['class_under_test'] == classification &&
              value['polarity'] == 'positive',
        ),
        hasLength(1),
      );
      expect(
        cases.where(
          (Map<String, dynamic> value) =>
              value['class_under_test'] == classification &&
              value['polarity'] == 'negative',
        ),
        hasLength(1),
      );
    }
  });

  test('fixture expected_result matches validation outcome', () {
    for (final Map<String, dynamic> fixture in cases) {
      final Map<String, dynamic> result = _asMap(fixture['result']);
      final Map<String, dynamic> expected = _asMap(fixture['expected_result']);
      final List<String> errors = _validateResult(result);
      expect(
        errors.isEmpty,
        expected['schema_valid'],
        reason: '${fixture['fixture_id']}: $errors',
      );
      expect(expected['reason_code'].toString(), isNotEmpty);
      expect(expected['domain_write_count'], 0);
    }
  });
}
