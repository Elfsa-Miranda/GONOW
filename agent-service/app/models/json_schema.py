"""Small fail-closed JSON Schema validator for provider output contracts.

The model adapters only need the deliberately small schema vocabulary used by
GoNow's typed model outputs.  Keeping this validator local avoids a new runtime
dependency while still enforcing the exact schema bytes sent to providers.
"""

from __future__ import annotations

import json
import math
import re
from typing import Any


SUPPORTED_KEYWORDS = frozenset(
    {
        "additionalProperties",
        "items",
        "maximum",
        "maxItems",
        "maxLength",
        "minimum",
        "minItems",
        "minLength",
        "pattern",
        "properties",
        "required",
        "type",
        "uniqueItems",
    }
)

GEMINI_RESPONSE_SCHEMA_KEYWORDS = frozenset(
    {
        "$anchor",
        "$defs",
        "$id",
        "$ref",
        "additionalProperties",
        "anyOf",
        "description",
        "enum",
        "format",
        "items",
        "maximum",
        "maxItems",
        "minimum",
        "minItems",
        "oneOf",
        "prefixItems",
        "properties",
        "propertyOrdering",
        "required",
        "title",
        "type",
    }
)


class JsonSchemaContractError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


def canonical_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """Copy and freeze a JSON-compatible schema or fail before any HTTP call."""

    try:
        value = json.loads(
            json.dumps(
                schema,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
        )
    except (TypeError, ValueError) as error:
        raise JsonSchemaContractError("schema.definition_invalid") from error
    if not isinstance(value, dict) or not value:
        raise JsonSchemaContractError("schema.definition_invalid")
    _validate_definition(value)
    return value


def canonical_schema_text(schema: dict[str, Any]) -> str:
    return json.dumps(
        schema,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def project_provider_schema(
    schema: dict[str, Any], *, allowed_keywords: frozenset[str]
) -> dict[str, Any]:
    """Remove unsupported provider hints while retaining the full local contract."""

    canonical = canonical_schema(schema)

    def project(node: Any, *, parent_keyword: str = "") -> Any:
        if isinstance(node, list):
            return [project(item, parent_keyword=parent_keyword) for item in node]
        if not isinstance(node, dict):
            return node
        if parent_keyword == "properties":
            return {
                str(name): project(child)
                for name, child in sorted(node.items())
            }
        return {
            str(keyword): project(child, parent_keyword=str(keyword))
            for keyword, child in sorted(node.items())
            if str(keyword) in allowed_keywords
        }

    projected = project(canonical)
    if not isinstance(projected, dict) or projected.get("type") != canonical.get("type"):
        raise JsonSchemaContractError("schema.provider_projection_invalid")
    return projected


def _validate_definition(schema: dict[str, Any]) -> None:
    unsupported = set(schema) - SUPPORTED_KEYWORDS
    if unsupported:
        raise JsonSchemaContractError("schema.keyword_unsupported")
    expected_type = schema.get("type")
    if expected_type not in {
        "object",
        "array",
        "string",
        "integer",
        "number",
        "boolean",
        "null",
    }:
        raise JsonSchemaContractError("schema.type_unsupported")
    properties = schema.get("properties", {})
    if expected_type == "object":
        if not isinstance(properties, dict):
            raise JsonSchemaContractError("schema.definition_invalid")
        required = schema.get("required", [])
        if not isinstance(required, list) or not all(
            isinstance(item, str) for item in required
        ):
            raise JsonSchemaContractError("schema.definition_invalid")
        if not set(required).issubset(properties):
            raise JsonSchemaContractError("schema.definition_invalid")
        if schema.get("additionalProperties", True) is not False:
            raise JsonSchemaContractError("schema.additional_properties_not_closed")
        for child in properties.values():
            if not isinstance(child, dict):
                raise JsonSchemaContractError("schema.definition_invalid")
            _validate_definition(child)
    if expected_type == "array":
        items = schema.get("items")
        if not isinstance(items, dict):
            raise JsonSchemaContractError("schema.definition_invalid")
        _validate_definition(items)


def validation_rule_codes(value: Any, schema: dict[str, Any]) -> tuple[str, ...]:
    """Return finite content-free rule codes; never return values or body text."""

    failures: set[str] = set()
    _validate_value(value, schema, failures)
    return tuple(sorted(failures))


def _validate_value(
    value: Any, schema: dict[str, Any], failures: set[str]
) -> None:
    expected_type = schema["type"]
    valid_type = {
        "object": lambda item: isinstance(item, dict),
        "array": lambda item: isinstance(item, list),
        "string": lambda item: isinstance(item, str),
        "integer": lambda item: isinstance(item, int) and not isinstance(item, bool),
        "number": lambda item: (
            isinstance(item, (int, float))
            and not isinstance(item, bool)
            and math.isfinite(float(item))
        ),
        "boolean": lambda item: isinstance(item, bool),
        "null": lambda item: item is None,
    }[expected_type](value)
    if not valid_type:
        failures.add("schema.type")
        return

    if expected_type == "object":
        properties = schema.get("properties", {})
        missing = set(schema.get("required", [])) - set(value)
        if missing:
            failures.add("schema.required")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            failures.add("schema.additional_properties")
        for name, child_schema in properties.items():
            if name in value:
                _validate_value(value[name], child_schema, failures)
        return

    if expected_type == "array":
        if len(value) < int(schema.get("minItems", 0)):
            failures.add("schema.min_items")
        maximum = schema.get("maxItems")
        if maximum is not None and len(value) > int(maximum):
            failures.add("schema.max_items")
        if schema.get("uniqueItems") is True:
            canonical_items = [
                json.dumps(
                    item,
                    allow_nan=False,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                )
                for item in value
            ]
            if len(canonical_items) != len(set(canonical_items)):
                failures.add("schema.unique_items")
        for item in value:
            _validate_value(item, schema["items"], failures)
        return

    if expected_type == "string":
        if len(value) < int(schema.get("minLength", 0)):
            failures.add("schema.min_length")
        maximum = schema.get("maxLength")
        if maximum is not None and len(value) > int(maximum):
            failures.add("schema.max_length")
        pattern = schema.get("pattern")
        if pattern is not None and re.fullmatch(str(pattern), value) is None:
            failures.add("schema.pattern")
        return

    if expected_type in {"boolean", "null"}:
        return

    minimum = schema.get("minimum")
    maximum = schema.get("maximum")
    if minimum is not None and value < minimum:
        failures.add("schema.minimum")
    if maximum is not None and value > maximum:
        failures.add("schema.maximum")
