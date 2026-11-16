"""Fail closed on files outside the explicit delta-only publication allowlist."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
TEXT_FILES = {
    ".gitignore", ".gitattributes", ".github/workflows/ci.yml", "README.md", "MIGRATION.md",
    "manage.sh", "boot-restore.sh", "patch_binary.sh", "metadata.sh", "libgateway_tls.so", "resolv.conf",
    "manifest.json", "targets.tsv", "SHA256SUMS", "PAYLOADSUMS.sha256",
    "scripts/generate_delta.py", "scripts/audit_distribution.py", "scripts/package.py",
    "tests/test_distribution.py", "tests/test_shell.py",
}
PAYLOAD = re.compile(r"payload/(http-gateway|http-gateway-b2b)/(factory)/(ranges\.tsv|[0-9]{3}\.bin)\Z")
NAMES = {"http-gateway", "http-gateway-b2b"}
VARIANTS = {"factory"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def allowed(name):
    return name in TEXT_FILES or bool(PAYLOAD.fullmatch(name))


def audit(files):
    """files maps archive-relative names to bytes; works identically for ZIP/tree."""
    missing = TEXT_FILES - set(files)
    if missing:
        raise ValueError("missing publication files: " + str(sorted(missing)))
    for name, data in files.items():
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or not allowed(name):
            raise ValueError("unlisted publication file: " + name)
        if name == "libgateway_tls.so":
            if digest(data) != "1356c2e31f2f306cc4f74611b6ac4221894c37e883d0850ad3a12ec4d2907f3a":
                raise ValueError("existing TLS helper hash differs")
            continue
        if data.startswith((b"\x7fELF", b"MZ", b"PK\x03\x04")):
            raise ValueError("full executable/archive found: " + name)
        if not name.endswith(".bin"):
            data.decode("utf-8")
            if b"\x00" in data or b"\r\n" in data:
                raise ValueError("text must be UTF-8/LF without NUL: " + name)
    manifest = json.loads(files["manifest.json"])
    if manifest["distribution"] != "delta-only" or len(manifest["artifacts"]) != 2:
        raise ValueError("invalid distribution manifest")
    serialized = files["manifest.json"]
    for forbidden in (b"original_src", b"modified_file", b"build_commands", b"C:\\\\", b"selected_instruction_lines"):
        if forbidden in serialized:
            raise ValueError("private build/evidence field in publication manifest")
    artifacts = {a["name"]: a for a in manifest["artifacts"]}
    if set(artifacts) != NAMES:
        raise ValueError("unexpected artifacts")
    referenced = set()
    variants = set()
    for line in files["targets.tsv"].decode("ascii").splitlines():
        if not line or line.startswith("#"):
            continue
        name, variant, before, after, input_size, output_size, directory = line.split()
        if name not in NAMES or variant not in VARIANTS or (name, variant) in variants:
            raise ValueError("unexpected/duplicate target")
        variants.add((name, variant))
        a = artifacts[name]
        if (before != a["original_sha256"] or
                after != a["modified_sha256"] or int(input_size) != a["original_size"] or
                int(output_size) != a["modified_size"] or directory != f"payload/{name}/{variant}"):
            raise ValueError("target differs from pinned manifest")
        index = directory + "/ranges.tsv"
        referenced.add(index)
        end = 0
        total = 0
        for row in files[index].decode("ascii").splitlines():
            offset, length, filename = row.split()
            offset, length = int(offset), int(length)
            if not re.fullmatch(r"[0-9]{3}\.bin", filename):
                raise ValueError("invalid chunk filename")
            chunk = directory + "/" + filename
            if chunk in referenced or offset < end or length <= 0 or offset + length > int(output_size):
                raise ValueError("overlapping/out-of-bounds/duplicate delta")
            if len(files[chunk]) != length:
                raise ValueError("chunk size differs")
            referenced.add(chunk)
            total += length
            end = offset + length
        # These version-pinned patches should be small, never a disguised whole ELF.
        if total != a["changed_byte_count"] or total != 57 or int(input_size) != int(output_size):
            raise ValueError("factory delta byte count/size differs")
    if variants != {(n, v) for n in NAMES for v in VARIANTS}:
        raise ValueError("missing target variant")
    payload = {n for n in files if n.startswith("payload/")}
    if payload != referenced:
        raise ValueError("unreferenced/missing payload files")
    sums = {}
    for row in files["PAYLOADSUMS.sha256"].decode("ascii").splitlines():
        checksum, name = row.split("  ", 1)
        if name in sums or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError("invalid checksum list")
        sums[name] = checksum
    if set(sums) != payload | {"targets.tsv", "manifest.json"}:
        raise ValueError("checksum coverage differs")
    for name, checksum in sums.items():
        if digest(files[name]) != checksum:
            raise ValueError("checksum mismatch: " + name)
    runtime = {"manage.sh", "boot-restore.sh", "patch_binary.sh", "metadata.sh", "libgateway_tls.so",
               "resolv.conf", "manifest.json", "targets.tsv", "PAYLOADSUMS.sha256"} | payload
    runtime_sums = {}
    for row in files["SHA256SUMS"].decode("ascii").splitlines():
        checksum, name = row.split("  ", 1)
        if name in runtime_sums or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError("invalid runtime checksums")
        runtime_sums[name] = checksum
    if set(runtime_sums) != runtime:
        raise ValueError("runtime checksum coverage differs")
    for name, checksum in runtime_sums.items():
        if digest(files[name]) != checksum:
            raise ValueError("runtime checksum mismatch: " + name)
    return {"result": "PASS", "files": len(files), "bytes": sum(map(len, files.values())),
            "complete_oem_files": 0, "full_disassemblies": 0, "target_variants": len(variants), "preserved_tls_helper": True}


def tree_files(root):
    files = {}
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ".git" in relative.parts or "__pycache__" in relative.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise ValueError("symlink in publication tree: " + str(relative))
        if path.is_file():
            files[relative.as_posix()] = path.read_bytes()
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    print(json.dumps(audit(tree_files(args.root)), indent=2))
