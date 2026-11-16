"""Build exact factory-to-current-v5 deltas using files outside the repository."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def ranges(before, after):
    if len(after) < len(before):
        raise ValueError("shrinking outputs are unsupported")
    i = 0
    while i < len(before):
        if before[i] == after[i]:
            i += 1
            continue
        start = i
        while i < len(before) and before[i] != after[i]:
            i += 1
        yield start, after[start:i]
    if len(after) > len(before):
        yield len(before), after[len(before):]


def generate(factory, modified, output):
    for directory in (factory, modified, output):
        directory = directory.resolve()
        if directory == ROOT or ROOT in directory.parents:
            raise ValueError("OEM inputs and staging output must be outside the repository")
    if output.exists() and any(output.iterdir()):
        raise ValueError("output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "manifest.json").read_bytes())
    lines = ["# kind variant input_sha output_sha input_size output_size payload_directory\n"]
    stats = []
    for artifact in manifest["artifacts"]:
        name = artifact["name"]
        before = (factory / name).read_bytes()
        after = (modified / name).read_bytes()
        if sha(before) != artifact["original_sha256"] or sha(after) != artifact["modified_sha256"]:
            raise ValueError("factory/output hash differs: " + name)
        relative = Path("payload") / name / "factory"
        directory = output / relative
        directory.mkdir(parents=True)
        rebuilt = bytearray(before)
        rows = []
        for index, (offset, data) in enumerate(ranges(before, after)):
            filename = f"{index:03d}.bin"
            (directory / filename).write_bytes(data)
            rows.append(f"{offset} {len(data)} {filename}\n")
            rebuilt[offset:offset + len(data)] = data
        if bytes(rebuilt) != after:
            raise ValueError("delta output differs")
        (directory / "ranges.tsv").write_text("".join(rows), encoding="ascii", newline="\n")
        lines.append(f"{name} factory {sha(before)} {sha(after)} {len(before)} {len(after)} {relative.as_posix()}\n")
        stats.append({"name": name, "baseline": "factory", "changed_bytes": sum(len(x) for _, x in ranges(before, after)),
                      "exact_v5_output": True})
    (output / "targets.tsv").write_text("".join(lines), encoding="ascii", newline="\n")
    print(json.dumps({"result": "PASS", "artifacts": stats}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factory-dir", required=True, type=Path)
    parser.add_argument("--modified-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    generate(args.factory_dir, args.modified_dir, args.output)
