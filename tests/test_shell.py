"""Real shell file transactions using generated data, not bundled OEM fixtures."""
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from generate_delta import ranges

SHELL = shutil.which("bash") or shutil.which("sh")
if os.name == "nt" and Path(r"C:\Program Files\Git\bin\bash.exe").exists():
    SHELL = r"C:\Program Files\Git\bin\bash.exe"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def posix(path):
    value = Path(path).resolve().as_posix()
    return "/" + value[0].lower() + value[2:] if len(value) > 1 and value[1] == ":" else value


@unittest.skipUnless(SHELL, "POSIX shell required")
class ShellTests(unittest.TestCase):
    def scenario(self, name, variant, mode):
        with tempfile.TemporaryDirectory(prefix="gateway-synthetic-") as directory:
            temp = Path(directory)
            package = temp / "package"
            package.mkdir()
            for script in ("patch_binary.sh", "metadata.sh"):
                shutil.copyfile(ROOT / script, package / script)
            before = bytes(i % 251 for i in range(16384))
            after = before[:100] + b"DIFF" + before[104:] + b"APPENDED-HELPER" * 400
            payload = package / "payload"
            payload.mkdir()
            rows = []
            for i, (offset, data) in enumerate(ranges(before, after)):
                chunk = f"{i:03d}.bin"
                (payload / chunk).write_bytes(data)
                rows.append(f"{offset} {len(data)} {chunk}\n")
            (payload / "ranges.tsv").write_text("".join(rows), encoding="ascii", newline="\n")
            (package / "targets.tsv").write_text(
                f"{name} {variant} {sha(before)} {sha(after)} {len(before)} {len(after)} payload\n",
                encoding="ascii", newline="\n")
            target = temp / name
            target.write_bytes(before)
            inode = target.stat().st_ino
            backups = temp / "backups"
            env = os.environ.copy()
            env["MSYS_NO_PATHCONV"] = "1"

            def run(action, success=True):
                result = subprocess.run([SHELL, (package / "patch_binary.sh").as_posix(), action,
                                         target.as_posix(), backups.as_posix()], cwd=package, env=env,
                                        capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                self.assertEqual(target.stat().st_ino, inode)
                return result

            if mode == "corrupt-payload":
                (payload / "000.bin").write_bytes(b"BAD!")
                run("apply", False)
                self.assertEqual(target.read_bytes(), before)
            elif mode == "unknown-input":
                target.write_bytes(b"?" + before[1:])
                unknown = target.read_bytes()
                run("apply", False)
                self.assertEqual(target.read_bytes(), unknown)
                self.assertFalse(backups.exists())
            elif mode == "partial-commit":
                commands = temp / "commands"
                commands.mkdir()
                real_cat = subprocess.run([SHELL, "-c", "command -v cat"], capture_output=True,
                                          text=True, check=True).stdout.strip()
                marker = temp / "fault-fired"
                wrapper = ('#!/bin/sh\ncase "$1" in */candidate)\n'
                           ' if [ ! -f "$FAULT_MARKER" ]; then\n'
                           '  : > "$FAULT_MARKER"\n'
                           '  dd if="$1" bs=1 count=4096 2>/dev/null\n'
                           '  exit 2\n fi;;\nesac\nexec ' + shlex.quote(real_cat) + ' "$@"\n')
                (commands / "cat").write_text(wrapper, encoding="utf-8", newline="\n")
                (commands / "cat").chmod(0o755)
                init = temp / "bash-env"
                init.write_text("export PATH=" + shlex.quote(posix(commands)) + ':"$PATH"\n',
                                encoding="utf-8", newline="\n")
                env.update(BASH_ENV=init.as_posix(), FAULT_MARKER=posix(marker))
                result = run("apply", False)
                self.assertIn("BINARY_ROLLBACK_OK", result.stdout)
                self.assertTrue(marker.exists())
                self.assertEqual(target.read_bytes(), before)
            else:
                baseline = run("check")
                self.assertIn("ORIGINAL", baseline.stdout)
                run("apply")
                self.assertEqual(target.read_bytes(), after)
                self.assertIn("ALREADY_PATCHED", run("apply").stdout)
                if mode == "external-edit":
                    target.write_bytes(b"?" + after[1:])
                    edited = target.read_bytes()
                    run("rollback", False)
                    self.assertEqual(target.read_bytes(), edited)
                else:
                    run("rollback")
                    run("rollback")
                    self.assertEqual(target.read_bytes(), before)
            if (backups / name / "original").exists():
                self.assertEqual((backups / name / "original").read_bytes(), before)

    def test_file_transactions(self):
        for name in ("http-gateway", "http-gateway-b2b"):
            for variant in ("factory",):
                for mode in ("normal", "unknown-input", "corrupt-payload", "external-edit", "partial-commit"):
                    with self.subTest(name=name, variant=variant, mode=mode):
                        self.scenario(name, variant, mode)


if __name__ == "__main__":
    unittest.main()
