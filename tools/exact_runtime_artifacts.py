#!/usr/bin/env python3
"""Shared exact-byte runtime artifact resolver for stable verification/packaging."""

import base64
import hashlib
import json
import lzma
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def load_registry(current):
    rel = current.get("exact_artifact_registry") or "runtime/exact_artifacts.json"
    path = ROOT / rel
    if not path.is_file():
        return {}, rel
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not isinstance(data.get("artifacts"), dict):
        raise RuntimeError(f"invalid exact-artifact registry: {rel}")
    return data["artifacts"], rel


def _decode_spec(spec):
    kind = spec.get("kind") or spec.get("format") or "xz"
    if kind == "xz":
        rel = spec.get("path")
        if not rel:
            raise RuntimeError("xz exact-artifact spec has no path")
        path = ROOT / rel
        if not path.is_file():
            raise RuntimeError(f"exact XZ artifact missing: {rel}")
        try:
            return lzma.decompress(path.read_bytes()), rel, "xz"
        except Exception as exc:
            raise RuntimeError(f"exact XZ decode failed: {rel}: {exc}") from exc

    if kind == "xz_b64_parts":
        prefix = spec.get("path_prefix")
        if not prefix:
            raise RuntimeError("xz_b64_parts exact-artifact spec has no path_prefix")
        parts = sorted(ROOT.glob(prefix + "*"))
        if not parts:
            raise RuntimeError(f"exact XZ base64 parts missing: {prefix}*")
        try:
            text = "".join("".join(p.read_text(encoding="utf-8").split()) for p in parts)
            packed = base64.b64decode(text, validate=True)
            data = lzma.decompress(packed)
        except Exception as exc:
            raise RuntimeError(f"exact XZ base64-part recovery failed: {prefix}*: {exc}") from exc
        rels = [str(p.relative_to(ROOT)).replace("\\", "/") for p in parts]
        return data, rels, "xz_b64_parts"

    raise RuntimeError(f"unsupported exact-artifact kind: {kind!r}")


def resolve_exact_bytes(item, current, registry=None):
    name = item.get("name", "<unnamed>")
    expected_hash = str(item.get("sha256", "")).lower()
    if len(expected_hash) != 64:
        raise RuntimeError(f"invalid runtime SHA256: {name}")

    if registry is None:
        registry, _ = load_registry(current)

    item_artifact = item.get("binary_artifact")
    source_kind = None
    spec = None
    if isinstance(item_artifact, dict):
        spec = dict(item_artifact)
        source_kind = "runtime_binary_artifact"
    elif expected_hash in registry:
        spec = dict(registry[expected_hash])
        source_kind = "exact_artifact_registry"
    else:
        cache_root = current.get("runtime_binary_cache") or "artifacts/runtime_cache"
        spec = {
            "kind": "xz",
            "path": f"{cache_root}/{expected_hash}.dll.xz",
            "sha256": expected_hash,
        }
        source_kind = "content_addressed_cache"

    declared_hash = str(spec.get("sha256", "")).lower()
    if declared_hash and declared_hash != expected_hash:
        raise RuntimeError(f"exact-artifact SHA metadata differs from runtime SHA: {name}")

    runtime_size = item.get("size")
    artifact_size = spec.get("size")
    if isinstance(runtime_size, int) and runtime_size > 0 and isinstance(artifact_size, int) and artifact_size > 0 and runtime_size != artifact_size:
        raise RuntimeError(f"exact-artifact size metadata differs from runtime size: {name}")
    expected_size = runtime_size if isinstance(runtime_size, int) and runtime_size > 0 else artifact_size

    data, source, encoding_kind = _decode_spec(spec)
    got_hash = sha256_bytes(data)
    if got_hash != expected_hash:
        raise RuntimeError(f"exact artifact hash mismatch: {name} got={got_hash} expected={expected_hash}")
    if isinstance(expected_size, int) and expected_size > 0 and len(data) != expected_size:
        raise RuntimeError(f"exact artifact size mismatch: {name} got={len(data)} expected={expected_size}")

    return data, {
        "name": name,
        "sha256": got_hash,
        "size": len(data),
        "source": source,
        "source_kind": source_kind,
        "encoding_kind": encoding_kind,
        "byte_identical_current": True,
    }
