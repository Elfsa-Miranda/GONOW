"""RFC 8785 canonicalization and Behavior Manifest digesting.

The manifest carries immutable content-addressed references only. Runtime secrets,
prompt bodies, responses, and reasoning are deliberately outside this boundary.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from typing import Any


COMPONENTS = (
    "graph",
    "state",
    "prompt",
    "context",
    "tools",
    "model",
    "schemas",
    "eval",
    "slo",
    "budget",
    "rollback",
)
TOP_LEVEL_FIELDS = frozenset({"schema_version", "behavior_key", "release_version", "components"})
FORBIDDEN_BODY_FIELDS = frozenset(
    {
        "api_key",
        "credential",
        "prompt_body",
        "reasoning",
        "response_body",
        "secret",
        "token",
    }
)
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
BEHAVIOR_KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
RELEASE_VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


class BehaviorManifestError(ValueError):
    """Stable fail-closed error for manifest or JCS input violations."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class BehaviorManifestDigest:
    normalized: dict[str, Any]
    canonical_utf8: bytes
    sha256: str


def _fail(code: str) -> None:
    raise BehaviorManifestError(code)


def _assert_unicode(value: str) -> None:
    if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
        _fail("behavior_manifest.invalid_unicode")


def _quote_string(value: str) -> str:
    _assert_unicode(value)
    output = ['"']
    short_escapes = {
        0x08: "\\b",
        0x09: "\\t",
        0x0A: "\\n",
        0x0C: "\\f",
        0x0D: "\\r",
    }
    for character in value:
        codepoint = ord(character)
        if codepoint in short_escapes:
            output.append(short_escapes[codepoint])
        elif codepoint <= 0x1F:
            output.append(f"\\u{codepoint:04x}")
        elif character == '"':
            output.append('\\"')
        elif character == "\\":
            output.append("\\\\")
        else:
            output.append(character)
    output.append('"')
    return "".join(output)


def _expand_scientific(mantissa: str, exponent: int) -> str:
    negative = mantissa.startswith("-")
    unsigned = mantissa[1:] if negative else mantissa
    digits = unsigned.replace(".", "")
    decimal_position = 1 + exponent
    if decimal_position <= 0:
        expanded = "0." + ("0" * -decimal_position) + digits
    elif decimal_position >= len(digits):
        expanded = digits + ("0" * (decimal_position - len(digits)))
    else:
        expanded = digits[:decimal_position] + "." + digits[decimal_position:]
    return ("-" if negative else "") + expanded


def _serialize_number(value: int | float) -> str:
    number = float(value)
    if not math.isfinite(number):
        _fail("behavior_manifest.number_out_of_range")
    if number == 0:
        return "0"

    rendered = repr(number).lower()
    absolute = abs(number)
    if "e" in rendered:
        mantissa, raw_exponent = rendered.split("e", maxsplit=1)
        exponent = int(raw_exponent)
        if 1e-6 <= absolute < 1e21:
            return _expand_scientific(mantissa, exponent)
        if mantissa.endswith(".0"):
            mantissa = mantissa[:-2]
        exponent_text = f"+{exponent}" if exponent >= 0 else str(exponent)
        return f"{mantissa}e{exponent_text}"
    if rendered.endswith(".0"):
        return rendered[:-2]
    return rendered


def _utf16_sort_key(value: str) -> bytes:
    _assert_unicode(value)
    return value.encode("utf-16-be")


def canonicalize_jcs(value: Any) -> bytes:
    """Return RFC 8785 canonical UTF-8 bytes for an I-JSON value."""

    def serialize(item: Any) -> str:
        if item is None:
            return "null"
        if item is True:
            return "true"
        if item is False:
            return "false"
        if isinstance(item, str):
            return _quote_string(item)
        if isinstance(item, (int, float)) and not isinstance(item, bool):
            return _serialize_number(item)
        if isinstance(item, list):
            return "[" + ",".join(serialize(element) for element in item) + "]"
        if isinstance(item, dict):
            if any(not isinstance(key, str) for key in item):
                _fail("behavior_manifest.non_string_key")
            properties = sorted(item, key=_utf16_sort_key)
            return "{" + ",".join(
                f"{_quote_string(key)}:{serialize(item[key])}" for key in properties
            ) + "}"
        _fail("behavior_manifest.unsupported_json_type")

    return serialize(value).encode("utf-8")


def _reject_constant(_: str) -> None:
    _fail("behavior_manifest.number_out_of_range")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("behavior_manifest.duplicate_property")
        result[key] = value
    return result


def parse_manifest_json(raw_json: str) -> dict[str, Any]:
    """Parse JSON while rejecting duplicate names and non-I-JSON constants."""

    try:
        value = json.loads(
            raw_json,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except BehaviorManifestError:
        raise
    except (json.JSONDecodeError, UnicodeError) as error:
        raise BehaviorManifestError("behavior_manifest.invalid_json") from error
    if not isinstance(value, dict):
        _fail("behavior_manifest.schema_invalid")
    return value


def normalize_behavior_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    """Apply the v1 schema normalization before JCS hashing."""

    if not isinstance(manifest, dict) or set(manifest) != TOP_LEVEL_FIELDS:
        _fail("behavior_manifest.schema_invalid")
    schema_version = manifest.get("schema_version")
    behavior_key = manifest.get("behavior_key")
    release_version = manifest.get("release_version")
    components = manifest.get("components")
    if (
        schema_version != "1.0"
        or not isinstance(behavior_key, str)
        or BEHAVIOR_KEY_PATTERN.fullmatch(behavior_key) is None
        or not isinstance(release_version, str)
        or RELEASE_VERSION_PATTERN.fullmatch(release_version) is None
        or not isinstance(components, dict)
        or set(components) != set(COMPONENTS)
    ):
        _fail("behavior_manifest.schema_invalid")

    normalized_components: dict[str, dict[str, str]] = {}
    for component_name in COMPONENTS:
        component = components[component_name]
        if not isinstance(component, dict) or set(component) != {"artifact_ref", "sha256"}:
            _fail("behavior_manifest.schema_invalid")
        artifact_ref = component.get("artifact_ref")
        digest = component.get("sha256")
        if (
            not isinstance(artifact_ref, str)
            or not isinstance(digest, str)
            or DIGEST_PATTERN.fullmatch(digest) is None
            or artifact_ref != f"{component_name}://sha256/{digest}"
        ):
            _fail("behavior_manifest.schema_invalid")
        normalized_components[component_name] = {
            "artifact_ref": artifact_ref,
            "sha256": digest,
        }

    def reject_body_fields(value: Any) -> None:
        if isinstance(value, dict):
            if any(key.lower() in FORBIDDEN_BODY_FIELDS for key in value):
                _fail("behavior_manifest.unsafe_content")
            for nested in value.values():
                reject_body_fields(nested)
        elif isinstance(value, list):
            for nested in value:
                reject_body_fields(nested)
        elif isinstance(value, str):
            _assert_unicode(value)

    reject_body_fields(manifest)
    return {
        "schema_version": "1.0",
        "behavior_key": behavior_key,
        "release_version": release_version,
        "components": normalized_components,
    }


def digest_behavior_manifest(manifest: dict[str, Any]) -> BehaviorManifestDigest:
    normalized = normalize_behavior_manifest(manifest)
    canonical = canonicalize_jcs(normalized)
    return BehaviorManifestDigest(
        normalized=normalized,
        canonical_utf8=canonical,
        sha256=hashlib.sha256(canonical).hexdigest(),
    )
