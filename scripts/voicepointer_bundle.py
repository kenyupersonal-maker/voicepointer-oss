#!/usr/bin/env python3
"""T9 repository-owned resource planner/assembler. Planning never builds, signs, launches or installs."""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import uuid

from version_registry import parse_registry

ROOT = Path(__file__).resolve().parent.parent
PACKAGING = "IntegratedPreview/Maintenance04/Resources/Packaging"
RESOURCE_MANIFEST = "Contents/Resources/resource-manifest.json"
SIGNING_ORDER = ("sign_nested_binary", "refresh_resource_manifest", "sign_app", "verify_app", "external_final_receipt")
MAINTENANCE_SCRIPTS = frozenset({"uninstall-voicepointer.py", "migrate-model-library.py", "app_data_safety.py"})
OLD_MODEL = "asr-lab/models/Qwen3-ASR-1.7B-7278e1e"
QUANT_MODEL = "asr-lab/models/Qwen3-ASR-1.7B-8bit-7278e1e"
AUDIO_SUFFIXES = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".aiff", ".caf", ".pcm"}
RESOURCE_SUFFIXES = {".py", ".json", ".sh", ".sb", ".png", ".icns", ".md", ".h", ".hsl"}
LICENSE_RESOURCE = "ModelDownloads/LICENSE-Qwen-Apache-2.0.txt"
ONBOARDING_DEMO_RESOURCE = "Onboarding/completion-demo.html"
HASH_CACHE = {}


def fail(code):
    raise ValueError(code)


def relative(value):
    if not isinstance(value, str) or not value or value.startswith("/"):
        fail("RESOURCE_PATH_INVALID")
    if any(part in ("", ".", "..") for part in value.split("/")):
        fail("RESOURCE_PATH_INVALID")
    return value


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def seal(value):
    unsigned = {key: val for key, val in value.items() if key != "manifest_sha256"}
    return {**unsigned, "manifest_sha256": hashlib.sha256(canonical(unsigned)).hexdigest()}


def valid_seal(value):
    return value.get("manifest_sha256") == seal(value)["manifest_sha256"]


def file_hashes(path):
    path = Path(path)
    info = path.stat()
    key = (str(path), info.st_size, info.st_mtime_ns)
    if key not in HASH_CACHE:
        sha, md5 = hashlib.sha256(), hashlib.md5()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                sha.update(chunk); md5.update(chunk)
        HASH_CACHE[key] = (info.st_size, sha.hexdigest(), md5.hexdigest())
    return HASH_CACHE[key]


def confined(path, root):
    path, root = Path(path), Path(root).resolve()
    resolved = path.resolve(strict=True)
    if resolved != root and root not in resolved.parents:
        fail("RESOURCE_SOURCE_ESCAPES_ROOT")
    return path


@dataclass
class Resource:
    path: str
    source: Path
    origin: str
    version: str
    role: str = "resource"
    body: bytes = None
    target: str = None

    def entry(self):
        relative(self.path)
        if self.target is not None:
            return dict(path=self.path, type="symlink", target=self.target, size=len(self.target.encode()),
                        sha256=hashlib.sha256(self.target.encode()).hexdigest(), version=self.version,
                        source=self.origin, role=self.role, mode=0o777)
        if self.body is not None:
            size, sha, md5 = len(self.body), hashlib.sha256(self.body).hexdigest(), hashlib.md5(self.body).hexdigest()
        else:
            size, sha, md5 = file_hashes(self.source)
        return dict(path=self.path, type="file", size=size, sha256=sha, md5=md5, version=self.version,
                    source=self.origin, role=self.role, mode=stat.S_IMODE(self.source.stat().st_mode),
                    source_sha256=file_hashes(self.source)[1])


def transform_resource(name, data, version, build):
    if name == "Info.plist":
        value = plistlib.loads(data)
        value.update(CFBundleShortVersionString=version, CFBundleVersion=build)
        if value.get("CFBundleIdentifier") != "com.kenyu.voicepointer.mac":
            fail("INFO_TEMPLATE_ID_INVALID")
        return plistlib.dumps(value, sort_keys=True)
    if name == "Backend/backend_worker.py":
        text = data.decode()
        if "model_directory(DATA_ROOT, pid)" in text:
            return data  # T11 uses the external index; no bundled-model path rewrite is needed.
        if OLD_MODEL.split("/")[-1] not in text:
            fail("WORKER_MODEL_MAPPING_MISSING")
        return text.replace(OLD_MODEL.split("/")[-1], QUANT_MODEL.split("/")[-1]).encode()
    if name == "Backend/catalog.json":
        profiles = json.loads(data)
        changed = set()
        for profile in profiles:
            required = profile.get("required_files", [])
            if not any(item.startswith(OLD_MODEL+"/") for item in required):
                continue
            profile["required_files"] = [item for item in required if not item.startswith(OLD_MODEL+"/")]
            profile["required_files"] += [QUANT_MODEL+"/"+item for item in
                ("config.json", "preprocessor_config.json", "tokenizer_config.json", "vocab.json", "merges.txt",
                 "chat_template.json", "quantization_config.json", "model.safetensors")]
            changed.add(profile["id"])
        if "qwen17-rolling" not in changed:
            fail("CATALOG_MODEL_MAPPING_MISSING")
        return (json.dumps(profiles, ensure_ascii=False, indent=2)+"\n").encode()
    if name in ("Backend/launch-local-worker.sh", "Backend/launch-punctuation-worker.sh"):
        old = "/*/com.kenyu.VoicePointer.IntegratedPreview"
        text = data.decode()
        if old not in text:
            fail("WORKER_DATA_GUARD_MISSING")
        return text.replace(old, "/*/com.kenyu.voicepointer.mac").encode()
    return data


def make_plan(root=ROOT, version="0.5.51", include_executables=True, external_models=None):
    root = Path(root).resolve()
    release = parse_registry((root/"VERSION").read_text()).entries.get(version)
    if release is None:
        fail("UNREGISTERED_VERSION")
    selector_path = confined(root/PACKAGING/"resource-sources.json", root)
    selector = json.loads(selector_path.read_bytes())
    if external_models is None:
        external_models = tuple(map(int, version.split("."))) >= (0, 5, 52)
    if external_models:
        selector["bundle_models"] = False
    if selector.get("schema_version") != 1 or tuple(selector.get("signing_order", [])) != SIGNING_ORDER \
            or selector.get("manifest_path") != RESOURCE_MANIFEST:
        fail("RESOURCE_SELECTOR_CONTRACT_INVALID")
    source_only = os.environ.get("VOICEPOINTER_SOURCE_BUILD") == "1"
    if source_only:
        selector["bundle_models"] = False
        seed_manifest = {"entries": []}
    else:
        seed = confined(root/relative(selector["seed_directory"]), root)
        payload = confined(seed/"payload", root)
        seed_data = (seed/"seed-manifest.json").read_bytes()
        if hashlib.sha256(seed_data).hexdigest() != selector.get("seed_manifest_sha256"):
            fail("SEED_MANIFEST_PIN_MISMATCH")
        seed_manifest = json.loads(seed_data)
    runtime = relative(selector["runtime_prefix"])
    if not runtime.startswith(".cache/venvs/"):
        fail("RUNTIME_ALLOWLIST_INVALID")
    models = selector.get("models", [])
    for model in models:
        prefix = relative(model["prefix"])
        if not prefix.startswith("asr-lab/models/") or model.get("source") not in ("seed", "repository"):
            fail("MODEL_ALLOWLIST_INVALID")
    resources = {}
    def add(value):
        if Path(value.path).suffix.lower() in AUDIO_SUFFIXES:
            fail("AUDIO_RESOURCE_FORBIDDEN")
        if value.path in resources:
            fail("RESOURCE_DESTINATION_DUPLICATE")
        resources[value.path] = value
    for entry in seed_manifest.get("entries", []):
        name = relative(entry["path"])
        is_runtime = name.startswith(runtime+"/")
        model = next((m for m in models if m["source"] == "seed" and name.startswith(m["prefix"]+"/")), None)
        if not is_runtime and not (model and selector.get("bundle_models", True)):
            continue
        if entry.get("type") == "directory":
            continue
        if Path(name).suffix.lower() in AUDIO_SUFFIXES:
            fail("AUDIO_RESOURCE_FORBIDDEN")
        source = confined(payload/name, payload)
        origin = "seed:"+selector["seed_directory"]+"/payload/"+name
        role = "runtime" if is_runtime else "model"
        resource_version = selector["runtime_version"] if is_runtime else model["version"]
        target = None
        if entry.get("type") == "symlink":
            target = entry.get("target")
            if not isinstance(target, str) or target.startswith("/") or not source.is_symlink() or os.readlink(source) != target:
                fail("RESOURCE_SYMLINK_INVALID")
            confined(source.parent/target, payload)
        elif entry.get("type") == "file":
            if source.is_symlink() or not source.is_file():
                fail("RESOURCE_FILE_INVALID")
            size, sha, _ = file_hashes(source)
            if size != entry.get("size") or sha != entry.get("sha256"):
                fail("SEED_RESOURCE_DIGEST_MISMATCH")
        else:
            fail("RESOURCE_TYPE_INVALID")
        add(Resource("Contents/Resources/Seed/payload/"+name, source, origin, resource_version, role, target=target))
    for model in models:
        if model["source"] != "repository" or not selector.get("bundle_models", True):
            continue
        source_root = confined(root/model["prefix"], root)
        allowed = {".json", ".safetensors", ".txt", ".md", ""}
        for file_name in model.get("files", []):
            relative(file_name)
            if "/" in file_name:
                fail("MODEL_FILE_ALLOWLIST_INVALID")
            source = confined(source_root/file_name, source_root)
            if not source.is_file() or source.is_symlink() or source.suffix.lower() not in allowed:
                fail("MODEL_RESOURCE_INVALID")
            add(Resource("Contents/Resources/Seed/payload/"+model["prefix"]+"/"+source.name, source,
                         "repository:"+model["prefix"]+"/"+source.name, model["version"], "model"))
    for model in models:
        if model.get("weight_sha256") and selector.get("bundle_models", True):
            path = "Contents/Resources/Seed/payload/"+model["prefix"]+"/model.safetensors"
            if path not in resources or resources[path].entry()["sha256"] != model["weight_sha256"]:
                fail("MODEL_WEIGHT_DIGEST_MISMATCH")
    repository_roots = selector["repository_resources"]
    repository_files = selector.get("repository_files", [])
    if len(repository_files) != len(set(repository_files)):
        fail("REPOSITORY_FILE_ALLOWLIST_DUPLICATE")
    for source_name in repository_files:
        relative(source_name)
        if not any(source_name.startswith(name+"/") for name in repository_roots):
            fail("REPOSITORY_FILE_ALLOWLIST_INVALID")
    for root_name in repository_roots:
        if root_name not in ("IntegratedPreview/Resources", "IntegratedPreview/Maintenance04/Resources"):
            fail("REPOSITORY_RESOURCE_ROOT_INVALID")
        for source_name in selector.get("repository_files", []):
            relative(source_name)
            if not source_name.startswith(root_name+"/"):
                continue
            source = confined(root/source_name, root)
            name = source_name[len(root_name)+1:]
            if not source.is_file() or name == "Info.plist" or name.startswith("Packaging/"):
                fail("REPOSITORY_FILE_ALLOWLIST_INVALID")
            if source.is_symlink() or (source.suffix.lower() not in RESOURCE_SUFFIXES and
                                      name not in (LICENSE_RESOURCE, ONBOARDING_DEMO_RESOURCE)):
                fail("REPOSITORY_RESOURCE_FORBIDDEN")
            destination = "Contents/Resources/"+name
            if destination in resources:
                fail("REPOSITORY_RESOURCE_OVERLAP")
            raw = source.read_bytes()
            body = transform_resource(name, raw, version, release.build)
            add(Resource(destination, source, "repository:"+root_name+"/"+name,
                         "sha256:"+hashlib.sha256(raw).hexdigest()[:12], body=body if body != raw else None))
    maintenance = selector.get("maintenance_scripts", [])
    if len(maintenance) != len(set(maintenance)) or set(maintenance) != MAINTENANCE_SCRIPTS:
        fail("MAINTENANCE_ALLOWLIST_INVALID")
    for name in maintenance:
        source = confined(root/"scripts"/name, root)
        if source.is_symlink() or not source.is_file(): fail("MAINTENANCE_RESOURCE_INVALID")
        add(Resource("Contents/Resources/Maintenance/"+name, source, "repository:scripts/"+name,
                     "sha256:"+file_hashes(source)[1][:12], "maintenance"))
    template = confined(root/PACKAGING/"Info.plist", root)
    add(Resource("Contents/Info.plist", template, "repository:"+PACKAGING+"/Info.plist", "registry:"+version,
                 "metadata", body=transform_resource("Info.plist", template.read_bytes(), version, release.build)))
    if include_executables:
        for source_name, destination, role in (
            ("VoicePointerPreview", "Contents/MacOS/VoicePointerPreview", "main_executable"),
            ("AliRealtimeWorker", "Contents/Resources/Backend/AliRealtimeWorker", "nested_executable")):
            source = confined(root/".cache/maintenance04-build"/source_name, root)
            if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK):
                fail("BUILT_EXECUTABLE_INVALID")
            add(Resource(destination, source, "build:"+source_name, "registry:"+version, role))
    if "Contents/Resources/Backend/qwen_confidence.py" not in resources:
        fail("CONFIDENCE_RESOURCE_MISSING")
    if external_models and "Contents/Resources/Backend/model_library.py" not in resources:
        fail("MODEL_LIBRARY_RESOURCE_MISSING")
    if not source_only and "Contents/Resources/Seed/payload/"+runtime+"/bin/python" not in resources:
        fail("RUNTIME_EXECUTABLE_MISSING")
    for name, value in resources.items():
        if value.target is not None:
            target_name = os.path.normpath(str(PurePosixPath(name).parent/value.target))
            if target_name not in resources:
                fail("RESOURCE_SYMLINK_TARGET_UNLISTED")
    payload_entries = []
    directories = set()
    prefix = "Contents/Resources/Seed/payload/"
    for name, value in sorted(resources.items()):
        if not name.startswith(prefix):
            continue
        entry = value.entry()
        relative_name = name[len(prefix):]
        seed_entry = {k: entry[k] for k in ("type", "mode")}
        seed_entry["path"] = relative_name
        if entry["type"] == "file":
            seed_entry.update(size=entry["size"], sha256=entry["sha256"])
        else:
            seed_entry["target"] = entry["target"]
        payload_entries.append(seed_entry)
        directories.update(str(parent) for parent in PurePosixPath(relative_name).parents if str(parent) != ".")
    payload_entries += [dict(path=name, type="directory", mode=0o755) for name in sorted(directories)]
    seed_output = dict(schema_version=1, engine_ids=seed_manifest.get("engine_ids", []),
                       entries=sorted(payload_entries, key=lambda item: item["path"]),
                       total_bytes=sum(item.get("size", 0) for item in payload_entries if item["type"] == "file"))
    add(Resource("Contents/Resources/Seed/seed-manifest.json", selector_path,
                 "generated:payload_allowlist", "registry:"+version, "metadata",
                 body=(json.dumps(seed_output, ensure_ascii=False, indent=1)+"\n").encode()))
    return resources, selector, release


def manifest_for(plan, selector, release, phase="planned"):
    # The main executable changes when the outer signature is applied. Its final raw SHA belongs only
    # in the external receipt, never in a sealed in-bundle manifest (which would cause a hash cycle).
    entries = [plan[name].entry() for name in sorted(plan) if plan[name].role != "main_executable"]
    return seal(dict(schema_version=1, phase=phase, version=release.version, build=release.build,
                     bundle_id="com.kenyu.voicepointer.mac", manifest_path=RESOURCE_MANIFEST,
                     signing_order=list(SIGNING_ORDER), main_executable_final_hash="external_receipt_only",
                     bundle_models=selector.get("bundle_models", True), entries=entries,
                     total_bytes=sum(e["size"] for e in entries if e["type"] == "file")))


def verify_manifest(app, manifest, allow_nested_change=False):
    app = Path(app).resolve()
    if not valid_seal(manifest) or manifest.get("manifest_path") != RESOURCE_MANIFEST \
            or tuple(manifest.get("signing_order", [])) != SIGNING_ORDER:
        fail("BUNDLE_MANIFEST_INVALID")
    seen = set()
    for entry in manifest.get("entries", []):
        name = relative(entry["path"])
        if name in seen or name == RESOURCE_MANIFEST or not (
                name.startswith("Contents/Resources/") or name == "Contents/Info.plist"):
            fail("BUNDLE_MANIFEST_SCOPE_INVALID")
        seen.add(name)
        target = confined(app/name, app)
        if entry["type"] == "symlink":
            if not target.is_symlink() or os.readlink(target) != entry["target"]:
                fail("BUNDLE_SYMLINK_MISMATCH")
        elif entry["type"] == "file":
            if target.is_symlink() or not target.is_file():
                fail("BUNDLE_FILE_MISMATCH")
            size, sha, _ = file_hashes(target)
            if not (allow_nested_change and entry.get("role") == "nested_executable") \
                    and (size != entry["size"] or sha != entry["sha256"]):
                fail("BUNDLE_RESOURCE_DIGEST_MISMATCH")
        else:
            fail("BUNDLE_MANIFEST_TYPE_INVALID")


def refresh_resource_manifest(app):
    app = Path(app).resolve()
    # A sealed app must never be mutated to make its recorded hashes look valid.
    if (app/"Contents/_CodeSignature").exists():
        fail("APP_ALREADY_SEALED")
    path = app/RESOURCE_MANIFEST
    manifest = json.loads(path.read_bytes())
    if manifest.get("phase") not in ("unsigned", "nested_signed"):
        fail("MANIFEST_SIGNING_PHASE_INVALID")
    verify_manifest(app, manifest, allow_nested_change=True)
    for entry in manifest["entries"]:
        if entry["type"] == "file" and entry.get("role") == "nested_executable":
            size, sha, md5 = file_hashes(app/entry["path"])
            entry.update(size=size, sha256=sha, md5=md5)
    manifest["phase"] = "nested_signed"
    manifest["total_bytes"] = sum(e["size"] for e in manifest["entries"] if e["type"] == "file")
    manifest = seal(manifest)
    path.write_bytes(json.dumps(manifest, ensure_ascii=False, indent=1).encode()+b"\n")
    verify_manifest(app, manifest)
    return manifest


def external_receipt(app):
    app = Path(app).resolve()
    manifest = json.loads((app/RESOURCE_MANIFEST).read_bytes())
    if manifest.get("phase") != "nested_signed" or not (app/"Contents/_CodeSignature").is_dir():
        fail("FINAL_RECEIPT_BEFORE_APP_SIGNING")
    verify_manifest(app, manifest)
    size, sha, md5 = file_hashes(app/"Contents/MacOS/VoicePointerPreview")
    return dict(schema_version=1, record_kind="final_hashes_after_signing", bundle_id=manifest["bundle_id"],
                version=manifest["version"], build=manifest["build"], manifest_sha256=manifest["manifest_sha256"],
                main_executable=dict(size=size, sha256=sha, md5=md5), signing_order=list(SIGNING_ORDER),
                verification="separate_signing_entrypoint_receipt")


def assemble(version, root=ROOT):
    root = Path(root).resolve()
    plan, selector, release = make_plan(root, version)
    directory = root/".cache/maintenance04-build"
    destination = directory/(release.stem+".app")
    report = directory/(release.stem+".package.json")
    if destination.exists() or destination.is_symlink() or report.exists():
        fail("CANDIDATE_ALREADY_EXISTS")
    # Rebuilt binaries are required. The old app is never a donor of either executable.
    for name in ("Contents/MacOS/VoicePointerPreview", "Contents/Resources/Backend/AliRealtimeWorker"):
        with plan[name].source.open("rb") as handle:
            if handle.read(8) != bytes.fromhex("cffaedfe0c000001"):
                fail("BUILT_EXECUTABLE_NOT_ARM64")
    stage = directory/(release.stem+".staging-"+uuid.uuid4().hex)
    stage.mkdir(parents=True, exist_ok=False)
    for name in sorted(plan, key=lambda value: (plan[value].target is not None, value)):
        value = plan[name]
        target = stage/name
        target.parent.mkdir(parents=True, exist_ok=True)
        if value.target is not None:
            os.symlink(value.target, target)
        elif value.body is not None:
            target.write_bytes(value.body); target.chmod(value.entry()["mode"])
        else:
            shutil.copy2(value.source, target)
    manifest = manifest_for(plan, selector, release, "unsigned")
    (stage/RESOURCE_MANIFEST).write_bytes(json.dumps(manifest, ensure_ascii=False, indent=1).encode()+b"\n")
    (stage/"Contents/PkgInfo").write_bytes(b"APPL????")
    verify_manifest(stage, manifest)
    # The main executable is outside the resource-manifest scope, but its build input is checked here.
    executable = stage/"Contents/MacOS/VoicePointerPreview"
    if file_hashes(executable) != file_hashes(plan["Contents/MacOS/VoicePointerPreview"].source):
        fail("MAIN_EXECUTABLE_COPY_MISMATCH")
    stage.rename(destination)
    base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    metadata = dict(assembly_status="ASSEMBLED_UNSIGNED", layout="repository_manifest", bundle_id=manifest["bundle_id"],
                    version=version, build=release.build, source_base_commit=base,
                    manifest_sha256=manifest["manifest_sha256"], resource_entries=len(manifest["entries"]),
                    bundle_models=selector.get("bundle_models", True), compiled_executable_sha256=file_hashes(executable if executable.exists() else destination/"Contents/MacOS/VoicePointerPreview")[1],
                    signing_order=list(SIGNING_ORDER), source_04_dependency=False)
    report.write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n")
    return destination, metadata


def compare_baseline(plan, baseline):
    """Only explicitly planned public resources are read; no recursive baseline or personal-data scan."""
    baseline = Path(baseline)
    if not baseline.is_dir() or baseline.is_symlink():
        fail("BASELINE_COMPARE_UNAVAILABLE")
    results = []
    changed_names = {"Contents/Info.plist", "Contents/MacOS/VoicePointerPreview",
                     "Contents/Resources/Backend/backend_worker.py", "Contents/Resources/Backend/backends.py",
                     "Contents/Resources/Backend/cloud_groq_worker.py",
                     "Contents/Resources/Backend/catalog.json", "Contents/Resources/Backend/AliRealtimeWorker",
                     "Contents/Resources/Backend/launch-local-worker.sh", "Contents/Resources/Backend/launch-punctuation-worker.sh",
                     "Contents/Resources/Seed/seed-manifest.json"}
    for name, value in sorted(plan.items()):
        entry = value.entry()
        target = baseline/name
        if not target.exists() and not target.is_symlink():
            state = "added_repository_resource"
        elif entry["type"] == "symlink":
            state = "equal" if target.is_symlink() and os.readlink(target) == entry["target"] else "unexpected_difference"
        elif target.is_symlink() or not target.is_file():
            state = "unexpected_difference"
        else:
            size, sha, md5 = file_hashes(confined(target, baseline))
            equal = size == entry["size"] and sha == entry["sha256"] and md5 == entry["md5"]
            state = "equal" if equal else ("expected_rebuilt_or_mapped" if name in changed_names else "unexpected_difference")
        results.append(dict(path=name, result=state, md5=entry.get("md5"), sha256=entry["sha256"]))
    return dict(schema_version=1, comparison="planned_public_resources_vs_04", assembled=False,
                results=results, equal=sum(v["result"] == "equal" for v in results),
                added=sum(v["result"] == "added_repository_resource" for v in results),
                expected_changed=sum(v["result"] == "expected_rebuilt_or_mapped" for v in results),
                unexpected=sum(v["result"] == "unexpected_difference" for v in results),
                intentionally_removed=[OLD_MODEL], source_04_deleted_or_renamed=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan-version")
    parser.add_argument("--snapshot")
    parser.add_argument("--external-models", action="store_true", help="Plan T11's external layout before registering the T15 release; never builds a package")
    parser.add_argument("--compare-baseline")
    parser.add_argument("--comparison-output")
    parser.add_argument("--refresh-manifest")
    parser.add_argument("--final-receipt")
    args = parser.parse_args()
    if args.refresh_manifest:
        value = refresh_resource_manifest(args.refresh_manifest)
        print("RESOURCE_MANIFEST_REFRESH_PASS nested_signed="+str(int(value["phase"] == "nested_signed")))
        return
    if args.final_receipt:
        app = Path(args.final_receipt)
        value = external_receipt(app)
        destination = app.parent/(app.stem+".signature.json")
        destination.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n")
        print("FINAL_SIGNATURE_RECEIPT_PASS external=1")
        return
    if not args.plan_version:
        parser.error("a plan version or a signing-stage operation is required")
    plan, selector, release = make_plan(ROOT, args.plan_version, external_models=True if args.external_models else None)
    manifest = manifest_for(plan, selector, release)
    if args.snapshot:
        Path(args.snapshot).write_text(json.dumps(manifest, ensure_ascii=False, indent=1)+"\n")
    if args.compare_baseline:
        comparison = compare_baseline(plan, args.compare_baseline)
        if args.comparison_output:
            Path(args.comparison_output).write_text(json.dumps(comparison, ensure_ascii=False, indent=1)+"\n")
        print(f'BASELINE_RESOURCE_COMPARE equal={comparison["equal"]} added={comparison["added"]} expected_changed={comparison["expected_changed"]} unexpected={comparison["unexpected"]} assembled=0')
    print(f'REPOSITORY_RESOURCE_PLAN_PASS entries={len(manifest["entries"])} bytes={manifest["total_bytes"]} source_04_dependency=0 assembled=0')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        # Numeric/enum failures only: public file paths stay in the local manifest, no raw external errors.
        code = str(error) if isinstance(error, ValueError) and str(error).isupper() else "RESOURCE_PLAN_INVALID"
        print("REPOSITORY_RESOURCE_PLAN_FAIL reason="+code)
        raise SystemExit(1)
