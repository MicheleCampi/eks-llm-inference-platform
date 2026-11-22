#!/usr/bin/env python3
"""Repair JSON schemas written by kubeconform's openapi2jsonschema.py.

The converter adds "additionalProperties": false to every object that has a
"properties" key (strict mode). When a CRD has a field that is itself named
"properties", the converter also adds it inside that field map, as if the map
were a schema. The result is a property named "additionalProperties" whose
schema is the boolean false: invalid in draft 4, so kubeconform cannot compile
the schema and reports "could not find schema". Upstream:
https://github.com/yannh/kubeconform/issues/295 (open on 2026-11-21).

External Secrets 2.15 has such a field (SecretStore
spec.provider.crd.whitelist.rules[].properties). A real CRD field is always a
schema object, never a boolean, so removing boolean entries from a properties
map removes only what the converter added. Rewrites each file in place, prints
how many entries it removed.

Usage: fix-crd-schema.py SCHEMA.json...
"""
import json
import sys


def fix(node):
    removed = 0
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict) and isinstance(props.get("additionalProperties"), bool):
            del props["additionalProperties"]
            removed += 1
        for value in node.values():
            removed += fix(value)
    elif isinstance(node, list):
        for value in node:
            removed += fix(value)
    return removed


def self_test():
    schema = {"type": "object", "properties": {
        "properties": {"type": "array"},
        "nested": {"type": "object", "properties": {"properties": {"type": "array"},
                                                    "additionalProperties": False},
                   "additionalProperties": False},
        "additionalProperties": False},
        "additionalProperties": False}
    assert fix(schema) == 2, schema
    assert schema["additionalProperties"] is False
    assert schema["properties"]["nested"]["additionalProperties"] is False
    assert "additionalProperties" not in schema["properties"]["nested"]["properties"]
    # A real field named additionalProperties is a schema object: kept.
    real = {"properties": {"additionalProperties": {"type": "string"}}}
    assert fix(real) == 0 and "additionalProperties" in real["properties"]


if __name__ == "__main__":
    self_test()
    for path in sys.argv[1:]:
        with open(path) as f:
            schema = json.load(f)
        n = fix(schema)
        if n:
            with open(path, "w") as f:
                json.dump(schema, f, indent=2)
            print(f"{path}: removed {n} converter-added additionalProperties (kubeconform#295)")
