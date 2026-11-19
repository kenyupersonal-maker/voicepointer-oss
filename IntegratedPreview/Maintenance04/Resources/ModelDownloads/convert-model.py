#!/usr/bin/env python3
"""T10 offline 0.4.0 conversion/reload. No inference/capture/network; diagnostics are fixed enums/counts."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import sys

PHASE = "initializing"


class ConversionFailure(Exception):
    def __init__(self, status):
        self.status = status


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_directory(path):
    path = Path(path).absolute()
    if any(parent.is_symlink() for parent in [path, *path.parents]):
        raise ConversionFailure("unsafe_path")
    return path


def verify_source(spec, source):
    for entry in spec["files"]:
        name = entry["name"]
        if not name or Path(name).name != name or name in (".", ".."):
            raise ConversionFailure("unsafe_path")
        path = source / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
            raise ConversionFailure("source_checksum")


def check_reloaded(model, expected_shapes, mx, tree_flatten):
    parameters = dict(tree_flatten(model.parameters()))
    shapes = {name: list(value.shape) for name, value in parameters.items()}
    if shapes != expected_shapes or not parameters:
        raise ConversionFailure("reload_shape")
    quantized = [name[:-7] for name in parameters if name.endswith(".scales")]
    if not quantized or any(name + ".biases" not in parameters or parameters[name + ".weight"].dtype != mx.uint32 for name in quantized):
        raise ConversionFailure("quantization")
    mx.eval(model.parameters())
    return len(parameters), len(quantized)


def convert(catalog, model_id, source, stage):
    global PHASE
    spec = next((entry for entry in catalog["models"] if entry["id"] == model_id), None)
    if spec is None or spec.get("conversion", {}).get("runtimeVersion") != "0.4.0":
        raise ConversionFailure("config_invalid")
    plan = spec["conversion"]
    if (plan["bits"], plan["groupSize"]) != (8, 64):
        raise ConversionFailure("config_invalid")
    source, stage = safe_directory(source), safe_directory(stage)
    if not source.is_dir() or source == stage:
        raise ConversionFailure("unsafe_path")
    PHASE = "source_verification"
    verify_source(spec, source)
    stage.mkdir(parents=True, exist_ok=True)
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false", PYTHONDONTWRITEBYTECODE="1")
    if importlib.metadata.version("mlx-qwen3-asr") != "0.4.0":
        raise ConversionFailure("library_version")
    PHASE = "importing"
    import mlx.core as mx
    from mlx.utils import tree_flatten
    from mlx_qwen3_asr import load_model
    from mlx_qwen3_asr.convert import quantize_model

    receipt_path = stage / "conversion-receipt.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt["sourceVersion"] != spec["version"] or receipt["inputFiles"] != spec["files"]:
            raise ConversionFailure("source_checksum")
        for entry in receipt["files"]:
            path = stage / entry["name"]
            if path.is_symlink() or Path(entry["name"]).name != entry["name"] or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
                raise ConversionFailure("output_checksum")
        shapes = receipt["parameterShapes"]
    else:
        if list(stage.glob("*.safetensors")):
            raise ConversionFailure("incomplete_stage")
        PHASE = "loading"
        model, _ = load_model(str(source), dtype=mx.float16)
        PHASE = "quantizing"
        quantize_model(model, bits=8, group_size=64)
        mx.eval(model.parameters())
        parameters = dict(tree_flatten(model.parameters()))
        shapes = {name: list(value.shape) for name, value in parameters.items()}
        # A crash leaves an isolated .partial file; it never becomes a loadable weight.
        temporary_directory = stage / ".conversion-tmp"
        temporary_directory.mkdir(exist_ok=True)
        temporary = temporary_directory / "model.safetensors"
        PHASE = "saving"
        mx.save_safetensors(str(temporary), parameters)
        os.replace(temporary, stage / "model.safetensors")
        del model, parameters
        mx.clear_cache()
        for name in ["config.json", "tokenizer_config.json", "preprocessor_config.json", "chat_template.json", "vocab.json", "merges.txt", "generation_config.json", "README.md"]:
            if (source / name).is_file():
                shutil.copyfile(source / name, stage / name)
        shutil.copyfile(Path(__file__).with_name("LICENSE-Qwen-Apache-2.0.txt"), stage / "LICENSE")
        (stage / "NOTICE").write_text("Qwen/Qwen3-ASR-1.7B; Apache-2.0. Local 8-bit/group64 conversion using mlx-qwen3-asr 0.4.0. See conversion-receipt.json for pinned input provenance.\n")
        (stage / "quantization_config.json").write_text(json.dumps({"bits": 8, "group_size": 64, "scope": "all_supported_layers"}, sort_keys=True) + "\n")
    if [path.name for path in stage.glob("*.safetensors")] != ["model.safetensors"]:
        raise ConversionFailure("quantization")
    quant = json.loads((stage / "quantization_config.json").read_text())
    if quant != {"bits": 8, "group_size": 64, "scope": "all_supported_layers"}:
        raise ConversionFailure("quantization")
    PHASE = "reloading"
    reloaded, _ = load_model(str(stage), dtype=mx.float16)
    parameter_count, quantized_count = check_reloaded(reloaded, shapes, mx, tree_flatten)
    del reloaded
    mx.clear_cache()
    PHASE = "output_verification"
    files = [{"name": path.name, "bytes": path.stat().st_size, "sha256": digest(path)} for path in sorted(stage.iterdir()) if path.is_file() and path.name != "conversion-receipt.json"]
    receipt = {
        "schemaVersion": 1, "sourceVersion": spec["version"], "inputFiles": spec["files"],
        "hf_revision": spec["hf_revision"], "ms_revision": spec["ms_revision"],
        "mlxVersion": importlib.metadata.version("mlx"), "runtimeVersion": "0.4.0", "dtype": "float16",
        "bits": 8, "groupSize": 64, "reloadVerified": True,
        "parameterCount": parameter_count, "quantizedLayers": quantized_count,
        "parameterShapes": shapes, "files": files,
    }
    receipt_path.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    return parameter_count, quantized_count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--id", required=True, choices=["qwen17-rolling"])
    parser.add_argument("--source", required=True)
    parser.add_argument("--stage", required=True)
    args = parser.parse_args()
    # Suppress Python AND native library output before importing MLX. Never expose model/library text.
    original_out, original_err = os.dup(1), os.dup(2)
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), 1); os.dup2(sink.fileno(), 2)
        status, parameters, quantized, error_type = "io", 0, 0, "none"
        try:
            parameters, quantized = convert(json.loads(Path(args.catalog).read_text()), args.id, args.source, args.stage)
            status = "passed"
        except ConversionFailure as error:
            status = error.status
        except Exception as error:
            status = "io"
            error_type = type(error).__name__ if type(error).__name__ in {"OSError", "ValueError", "TypeError", "RuntimeError", "ImportError", "FileNotFoundError", "AttributeError", "KeyError"} else "unknown"
        finally:
            sys.stdout.flush(); sys.stderr.flush()
            os.dup2(original_out, 1); os.dup2(original_err, 2)
            os.close(original_out); os.close(original_err)
    assert status in {"passed", "io", "unsafe_path", "source_checksum", "output_checksum", "incomplete_stage", "config_invalid", "library_version", "reload_shape", "quantization"}
    assert PHASE in {"initializing", "source_verification", "importing", "loading", "quantizing", "saving", "reloading", "output_verification"}
    print(f"event=model_conversion,status={status},phase={PHASE},error_type={error_type},parameters={parameters},quantized_layers={quantized}", flush=True)
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
