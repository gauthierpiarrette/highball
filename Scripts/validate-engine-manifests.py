#!/usr/bin/env python3
"""Validate shipped manifests against the repository-owned v0 JSON Schema.

Run with jsonschema==4.25.1 installed. Optional arguments select other manifests.
No remote schemas or engine archives are fetched.
"""

from copy import deepcopy
import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator


def main():
    root = Path(__file__).resolve().parent.parent
    schema = json.loads((root / "schemas/engine-manifest-v0.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)
    fixture = json.loads((root / "Tests/Fixtures/engine-manifest-validation.json").read_text())
    failed = False
    for case in fixture["cases"]:
        document = deepcopy(fixture["base"])
        for change in case["changes"]:
            target = document
            for key in change["path"][:-1]:
                target = target[key]
            key = change["path"][-1]
            if change.get("remove"):
                target.pop(key)
            else:
                target[key] = change["value"]
        if validator.is_valid(document) != case["valid"]:
            print(f"Schema contract regression: {case['name']}", file=sys.stderr)
            failed = True
    files = [Path(arg) for arg in sys.argv[1:]] if sys.argv[1:] else [
        root / "spike/engine-manifest.json", *sorted((root / "spike/engines").glob("*.json"))
    ]
    for file in files:
        try:
            manifest = json.loads(file.read_text())
        except (OSError, ValueError) as error:
            print(f"{file}: {error}", file=sys.stderr)
            failed = True
            continue
        for error in sorted(validator.iter_errors(manifest), key=lambda e: str(list(e.absolute_path))):
            location = ".".join(map(str, error.absolute_path)) or "<root>"
            print(f"{file}: {location}: {error.message}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"Validated {len(files)} engine manifests and {len(fixture['cases'])} contract cases against the v0 schema.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
