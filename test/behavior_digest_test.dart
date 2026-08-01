import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/agent/behavior_digest.dart';

Map<String, dynamic> _loadVectors() =>
    jsonDecode(File('contracts/digest-vectors-v1.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, Object?> _copyManifest(Map<String, dynamic> source) =>
    (jsonDecode(jsonEncode(source)) as Map).cast<String, Object?>();

void _mutate(Map<String, Object?> document, Map<String, dynamic> mutation) {
  final tokens = (mutation['path'] as String)
      .split('/')
      .where((token) => token.isNotEmpty)
      .toList();
  Map target = document;
  for (final token in tokens.take(tokens.length - 1)) {
    target = target[token] as Map;
  }
  if (mutation['delete'] == true) {
    target.remove(tokens.last);
  } else {
    target[tokens.last] = mutation['value'];
  }
}

double _doubleFromHex(String hexadecimal) {
  final value = BigInt.parse(hexadecimal, radix: 16);
  final bytes = ByteData(8)
    ..setUint32(0, (value >> 32).toInt(), Endian.big)
    ..setUint32(4, (value & BigInt.from(0xffffffff)).toInt(), Endian.big);
  return bytes.getFloat64(0, Endian.big);
}

void main() {
  test('Python and Dart share canonical bytes and digest vectors', () {
    final vectors = _loadVectors();
    final observed = <Map<String, String>>[];
    for (final vectorValue in vectors['positive_vectors'] as List) {
      final vector = (vectorValue as Map).cast<String, dynamic>();
      late final String canonical;
      late final String digest;
      if (vector['kind'] == 'behavior_manifest') {
        final result = digestBehaviorManifest(
          (vector['input'] as Map).cast<String, Object?>(),
        );
        canonical = utf8.decode(result.canonicalUtf8);
        digest = result.sha256;
      } else {
        canonical = canonicalizeJcs(vector['input']);
        digest = sha256Jcs(vector['input']);
      }
      expect(
        canonical,
        vector['expected_canonical'],
        reason: vector['id'] as String,
      );
      expect(digest, vector['expected_sha256'], reason: vector['id'] as String);
      observed.add(<String, String>{
        'id': vector['id'] as String,
        'sha256': vector['expected_sha256'] as String,
      });
    }
    final report = <String, Object?>{
      'schema_version': '1.0',
      'task_id': 'TASK-P03-005',
      'algorithm': vectors['algorithm'],
      'dart_vector_count': observed.length,
      'dart_vectors': observed,
      'negative_vector_count': (vectors['negative_vectors'] as List).length,
      'python_dart_digest_match': true,
      'production': false,
    };
    final reportPath =
        Platform.environment['GONOW_P03_DART_MANIFEST_REPORT'] ??
        'docs/execution/evidence/phase-03/P03-005/dart-digest-report.json';
    File(reportPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
  });

  test('negative manifest vectors fail closed', () {
    final vectors = _loadVectors();
    final baseline =
        (vectors['positive_vectors'] as List).first['input']
            as Map<String, dynamic>;
    for (final vectorValue in vectors['negative_vectors'] as List) {
      final vector = (vectorValue as Map).cast<String, dynamic>();
      final mutated = _copyManifest(baseline);
      _mutate(mutated, (vector['mutation'] as Map).cast<String, dynamic>());
      expect(
        () => normalizeBehaviorManifest(mutated),
        throwsA(
          isA<BehaviorManifestException>().having(
            (error) => error.code,
            'code',
            vector['error_code'],
          ),
        ),
        reason: vector['id'] as String,
      );
    }
  });

  test('RFC 8785 Appendix B number samples use ECMAScript serialization', () {
    const samples = <String, String>{
      '0000000000000000': '0',
      '8000000000000000': '0',
      '0000000000000001': '5e-324',
      '8000000000000001': '-5e-324',
      '7fefffffffffffff': '1.7976931348623157e+308',
      'ffefffffffffffff': '-1.7976931348623157e+308',
      '4340000000000000': '9007199254740992',
      'c340000000000000': '-9007199254740992',
      '4430000000000000': '295147905179352830000',
      '44b52d02c7e14af5': '9.999999999999997e+22',
      '44b52d02c7e14af6': '1e+23',
      '44b52d02c7e14af7': '1.0000000000000001e+23',
      '444b1ae4d6e2ef4e': '999999999999999700000',
      '444b1ae4d6e2ef4f': '999999999999999900000',
      '444b1ae4d6e2ef50': '1e+21',
      '3eb0c6f7a0b5ed8c': '9.999999999999997e-7',
      '3eb0c6f7a0b5ed8d': '0.000001',
      '41b3de4355555553': '333333333.3333332',
      '41b3de4355555554': '333333333.33333325',
      '41b3de4355555555': '333333333.3333333',
      '41b3de4355555556': '333333333.3333334',
      '41b3de4355555557': '333333333.33333343',
      'becbf647612f3696': '-0.0000033333333333333333',
      '43143ff3c1cb0959': '1424953923781206.2',
    };
    for (final sample in samples.entries) {
      expect(canonicalizeJcs(_doubleFromHex(sample.key)), sample.value);
    }
  });

  test('non-I-JSON values are rejected', () {
    for (final value in <double>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        () => canonicalizeJcs(value),
        throwsA(
          isA<BehaviorManifestException>().having(
            (error) => error.code,
            'code',
            'behavior_manifest.number_out_of_range',
          ),
        ),
      );
    }
    expect(
      () => canonicalizeJcs(String.fromCharCode(0xd800)),
      throwsA(
        isA<BehaviorManifestException>().having(
          (error) => error.code,
          'code',
          'behavior_manifest.invalid_unicode',
        ),
      ),
    );
  });
}
