"""Create and reopen a delta-only release ZIP using the same strict allowlist."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path

from audit_distribution import ROOT, audit, tree_files


def package(output):
    output = output.resolve()
    if ROOT == output or ROOT in output.parents:
        raise ValueError("release output must be outside the repository")
    files = tree_files(ROOT)
    audit(files)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(2026, 11, 16, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
            archive.writestr(entry, data)
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None or len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("ZIP CRC/duplicate name failure")
        unpacked = {name: archive.read(name) for name in archive.namelist()}
        if unpacked != files:
            raise ValueError("ZIP round trip differs")
        result = audit(unpacked)
    result.update(zip=str(output), zip_bytes=output.stat().st_size,
                  sha256=hashlib.sha256(output.read_bytes()).hexdigest(), zip_reopened=True)
    output.with_suffix(output.suffix + ".sha256").write_text(result["sha256"] + "  " + output.name + "\n", encoding="ascii")
    print(json.dumps(result, indent=2))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    package(parser.parse_args().output)
