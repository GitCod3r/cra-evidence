#!/usr/bin/env python3
"""Minimal JSON-Schema validator for the evidence-bundle manifest (SPEC §4).

No third-party deps (CLAUDE.md rule). Supports exactly the keywords used by
schema/evidence-bundle.schema.json: type (incl. union), required, properties,
additionalProperties (bool), enum, const, pattern, minLength, minimum,
minItems, items. Usage: validate_manifest.py <schema.json> <document.json>
"""
import json
import re
import sys

TYPES = {
    "object": dict, "array": list, "string": str,
    "integer": int, "number": (int, float), "boolean": bool,
    "null": type(None),
}


def check(schema, doc, path="$"):
    errors = []

    def err(msg):
        errors.append(f"{path}: {msg}")

    if "const" in schema and doc != schema["const"]:
        err(f"expected const {schema['const']!r}, got {doc!r}")
    if "enum" in schema and doc not in schema["enum"]:
        err(f"{doc!r} not in enum {schema['enum']}")

    if "type" in schema:
        allowed = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        # bool is a subclass of int in Python — exclude it from integer/number.
        ok = any(
            isinstance(doc, TYPES[t]) and not (t in ("integer", "number") and isinstance(doc, bool))
            for t in allowed
        )
        if not ok:
            err(f"expected type {allowed}, got {type(doc).__name__}")
            return errors  # type mismatch: further keyword checks are noise

    if isinstance(doc, str):
        if "pattern" in schema and not re.search(schema["pattern"], doc):
            err(f"{doc!r} does not match pattern {schema['pattern']!r}")
        if "minLength" in schema and len(doc) < schema["minLength"]:
            err(f"shorter than minLength {schema['minLength']}")

    if isinstance(doc, (int, float)) and not isinstance(doc, bool):
        if "minimum" in schema and doc < schema["minimum"]:
            err(f"{doc} below minimum {schema['minimum']}")

    if isinstance(doc, dict):
        for key in schema.get("required", []):
            if key not in doc:
                err(f"missing required property {key!r}")
        props = schema.get("properties", {})
        for key, value in doc.items():
            if key in props:
                errors += check(props[key], value, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                err(f"additional property {key!r} not allowed")
            elif isinstance(schema.get("additionalProperties"), dict):
                errors += check(schema["additionalProperties"], value, f"{path}.{key}")

    if isinstance(doc, list):
        if "minItems" in schema and len(doc) < schema["minItems"]:
            err(f"fewer than minItems {schema['minItems']}")
        if "items" in schema:
            for i, item in enumerate(doc):
                errors += check(schema["items"], item, f"{path}[{i}]")

    return errors


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        schema = json.load(f)
    with open(sys.argv[2]) as f:
        doc = json.load(f)
    problems = check(schema, doc)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)
    print(f"validate_manifest: OK — {sys.argv[2]} conforms to {sys.argv[1]}")


if __name__ == "__main__":
    main()
