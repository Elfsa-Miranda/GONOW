import 'dart:convert';

const List<String> behaviorComponentNames = <String>[
  'graph',
  'state',
  'prompt',
  'context',
  'tools',
  'model',
  'schemas',
  'eval',
  'slo',
  'budget',
  'rollback',
];

const Set<String> _topLevelFields = <String>{
  'schema_version',
  'behavior_key',
  'release_version',
  'components',
};

const Set<String> _forbiddenBodyFields = <String>{
  'api_key',
  'credential',
  'prompt_body',
  'reasoning',
  'response_body',
  'secret',
  'token',
};

final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _behaviorKeyPattern = RegExp(r'^[a-z][a-z0-9_.-]{0,126}$');
final RegExp _releaseVersionPattern = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$');

class BehaviorManifestException implements Exception {
  const BehaviorManifestException(this.code);

  final String code;

  @override
  String toString() => code;
}

class BehaviorManifestDigest {
  const BehaviorManifestDigest({
    required this.normalized,
    required this.canonicalUtf8,
    required this.sha256,
  });

  final Map<String, Object?> normalized;
  final List<int> canonicalUtf8;
  final String sha256;
}

Never _fail(String code) => throw BehaviorManifestException(code);

bool _sameKeys(Iterable<Object?> actual, Set<String> expected) {
  final keys = actual.whereType<String>().toSet();
  return keys.length == actual.length &&
      keys.length == expected.length &&
      keys.containsAll(expected);
}

void _assertValidUnicode(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length ||
          units[index + 1] < 0xdc00 ||
          units[index + 1] > 0xdfff) {
        _fail('behavior_manifest.invalid_unicode');
      }
      index++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _fail('behavior_manifest.invalid_unicode');
    }
  }
}

String _quoteString(String value) {
  _assertValidUnicode(value);
  final output = StringBuffer('"');
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index++) {
    final unit = units[index];
    switch (unit) {
      case 0x08:
        output.write(r'\b');
      case 0x09:
        output.write(r'\t');
      case 0x0a:
        output.write(r'\n');
      case 0x0c:
        output.write(r'\f');
      case 0x0d:
        output.write(r'\r');
      case 0x22:
        output.write(r'\"');
      case 0x5c:
        output.write(r'\\');
      default:
        if (unit <= 0x1f) {
          output.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else if (unit >= 0xd800 && unit <= 0xdbff) {
          final low = units[++index];
          final rune = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
          output.writeCharCode(rune);
        } else {
          output.writeCharCode(unit);
        }
    }
  }
  output.write('"');
  return output.toString();
}

String _expandScientific(String mantissa, int exponent) {
  final negative = mantissa.startsWith('-');
  final unsigned = negative ? mantissa.substring(1) : mantissa;
  final digits = unsigned.replaceAll('.', '');
  final decimalPosition = 1 + exponent;
  late final String expanded;
  if (decimalPosition <= 0) {
    expanded = '0.${'0' * -decimalPosition}$digits';
  } else if (decimalPosition >= digits.length) {
    expanded = '$digits${'0' * (decimalPosition - digits.length)}';
  } else {
    expanded =
        '${digits.substring(0, decimalPosition)}.'
        '${digits.substring(decimalPosition)}';
  }
  return '${negative ? '-' : ''}$expanded';
}

String _serializeNumber(num value) {
  final number = value.toDouble();
  if (!number.isFinite) {
    _fail('behavior_manifest.number_out_of_range');
  }
  if (number == 0) {
    return '0';
  }
  final rendered = number.toString().toLowerCase();
  final exponentIndex = rendered.indexOf('e');
  if (exponentIndex >= 0) {
    var mantissa = rendered.substring(0, exponentIndex);
    final exponent = int.parse(rendered.substring(exponentIndex + 1));
    final absolute = number.abs();
    if (absolute >= 1e-6 && absolute < 1e21) {
      return _expandScientific(mantissa, exponent);
    }
    if (mantissa.endsWith('.0')) {
      mantissa = mantissa.substring(0, mantissa.length - 2);
    }
    return '$mantissa${exponent >= 0 ? 'e+' : 'e'}$exponent';
  }
  return rendered.endsWith('.0')
      ? rendered.substring(0, rendered.length - 2)
      : rendered;
}

int _compareUtf16(String left, String right) {
  _assertValidUnicode(left);
  _assertValidUnicode(right);
  final leftUnits = left.codeUnits;
  final rightUnits = right.codeUnits;
  final sharedLength = leftUnits.length < rightUnits.length
      ? leftUnits.length
      : rightUnits.length;
  for (var index = 0; index < sharedLength; index++) {
    final difference = leftUnits[index] - rightUnits[index];
    if (difference != 0) {
      return difference;
    }
  }
  return leftUnits.length - rightUnits.length;
}

String canonicalizeJcs(Object? value) {
  String serialize(Object? item) {
    if (item == null) {
      return 'null';
    }
    if (item is bool) {
      return item ? 'true' : 'false';
    }
    if (item is String) {
      return _quoteString(item);
    }
    if (item is num) {
      return _serializeNumber(item);
    }
    if (item is List<Object?>) {
      return '[${item.map(serialize).join(',')}]';
    }
    if (item is Map) {
      if (item.keys.any((key) => key is! String)) {
        _fail('behavior_manifest.non_string_key');
      }
      final keys = item.keys.cast<String>().toList()..sort(_compareUtf16);
      return '{${keys.map((key) => '${_quoteString(key)}:${serialize(item[key])}').join(',')}}';
    }
    return _fail('behavior_manifest.unsupported_json_type');
  }

  return serialize(value);
}

String sha256Jcs(Object? value) =>
    _sha256Hex(utf8.encode(canonicalizeJcs(value)));

void _rejectBodyFields(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String &&
          _forbiddenBodyFields.contains((entry.key as String).toLowerCase())) {
        _fail('behavior_manifest.unsafe_content');
      }
      _rejectBodyFields(entry.value);
    }
  } else if (value is List) {
    for (final nested in value) {
      _rejectBodyFields(nested);
    }
  } else if (value is String) {
    _assertValidUnicode(value);
  }
}

Map<String, Object?> normalizeBehaviorManifest(Map<String, Object?> manifest) {
  if (!_sameKeys(manifest.keys, _topLevelFields)) {
    _fail('behavior_manifest.schema_invalid');
  }
  final schemaVersion = manifest['schema_version'];
  final behaviorKey = manifest['behavior_key'];
  final releaseVersion = manifest['release_version'];
  final components = manifest['components'];
  if (schemaVersion != '1.0' ||
      behaviorKey is! String ||
      !_behaviorKeyPattern.hasMatch(behaviorKey) ||
      releaseVersion is! String ||
      !_releaseVersionPattern.hasMatch(releaseVersion) ||
      components is! Map ||
      !_sameKeys(components.keys, behaviorComponentNames.toSet())) {
    _fail('behavior_manifest.schema_invalid');
  }

  final normalizedComponents = <String, Object?>{};
  for (final componentName in behaviorComponentNames) {
    final component = components[componentName];
    if (component is! Map ||
        !_sameKeys(component.keys, <String>{'artifact_ref', 'sha256'})) {
      _fail('behavior_manifest.schema_invalid');
    }
    final artifactRef = component['artifact_ref'];
    final digest = component['sha256'];
    if (artifactRef is! String ||
        digest is! String ||
        !_digestPattern.hasMatch(digest) ||
        artifactRef != '$componentName://sha256/$digest') {
      _fail('behavior_manifest.schema_invalid');
    }
    normalizedComponents[componentName] = <String, Object?>{
      'artifact_ref': artifactRef,
      'sha256': digest,
    };
  }
  _rejectBodyFields(manifest);
  return <String, Object?>{
    'schema_version': '1.0',
    'behavior_key': behaviorKey,
    'release_version': releaseVersion,
    'components': normalizedComponents,
  };
}

BehaviorManifestDigest digestBehaviorManifest(Map<String, Object?> manifest) {
  final normalized = normalizeBehaviorManifest(manifest);
  final canonicalUtf8 = utf8.encode(canonicalizeJcs(normalized));
  return BehaviorManifestDigest(
    normalized: normalized,
    canonicalUtf8: canonicalUtf8,
    sha256: _sha256Hex(canonicalUtf8),
  );
}

const List<int> _sha256Constants = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotateRight(int value, int amount) =>
    ((value >> amount) | (value << (32 - amount))) & 0xffffffff;

String _sha256Hex(List<int> input) {
  final message = List<int>.from(input)..add(0x80);
  while (message.length % 64 != 56) {
    message.add(0);
  }
  final bitLength = input.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    message.add((bitLength >> shift) & 0xff);
  }

  final hash = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final words = List<int>.filled(64, 0);
  for (var offset = 0; offset < message.length; offset += 64) {
    for (var index = 0; index < 16; index++) {
      final position = offset + index * 4;
      words[index] =
          (message[position] << 24) |
          (message[position + 1] << 16) |
          (message[position + 2] << 8) |
          message[position + 3];
    }
    for (var index = 16; index < 64; index++) {
      final s0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }

    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var index = 0; index < 64; index++) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temporary1 =
          (h + sum1 + choose + _sha256Constants[index] + words[index]) &
          0xffffffff;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temporary2 = (sum0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temporary1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temporary1 + temporary2) & 0xffffffff;
    }
    hash[0] = (hash[0] + a) & 0xffffffff;
    hash[1] = (hash[1] + b) & 0xffffffff;
    hash[2] = (hash[2] + c) & 0xffffffff;
    hash[3] = (hash[3] + d) & 0xffffffff;
    hash[4] = (hash[4] + e) & 0xffffffff;
    hash[5] = (hash[5] + f) & 0xffffffff;
    hash[6] = (hash[6] + g) & 0xffffffff;
    hash[7] = (hash[7] + h) & 0xffffffff;
  }
  return hash.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}
