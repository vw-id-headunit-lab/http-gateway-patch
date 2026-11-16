import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from audit_distribution import audit, tree_files
from generate_delta import ranges


class DistributionTests(unittest.TestCase):
    def test_clean_publication(self):
        self.assertEqual(audit(tree_files(ROOT))["complete_oem_files"], 0)

    def test_reject_original_executable(self):
        files = tree_files(ROOT)
        files["originals/http-gateway"] = b"\x7fELF" + b"private" * 100
        with self.assertRaises(ValueError):
            audit(files)

    def test_reject_disassembly_evidence(self):
        files = tree_files(ROOT)
        files["evidence/full-disassembly.json"] = b"{}"
        with self.assertRaises(ValueError):
            audit(files)

    def test_reject_hidden_executable(self):
        files = tree_files(ROOT)
        files["manage.sh"] = b"\x7fELF" + b"private" * 100
        with self.assertRaises(ValueError):
            audit(files)

    def test_reject_archive(self):
        files = tree_files(ROOT)
        files["old-release.zip"] = b"PK\x03\x04"
        with self.assertRaises(ValueError):
            audit(files)

    def test_reject_corrupt_chunk(self):
        files = tree_files(ROOT)
        name = next(n for n in files if n.endswith(".bin"))
        files[name] = bytes([files[name][0] ^ 1]) + files[name][1:]
        with self.assertRaises(ValueError):
            audit(files)

    def test_reject_range_traversal(self):
        files = tree_files(ROOT)
        name = next(n for n in files if n.endswith("ranges.tsv"))
        files[name] = b"0 1 ../../manage.sh\n"
        with self.assertRaises(ValueError):
            audit(files)

    def test_no_unchanged_gap_in_delta(self):
        self.assertEqual(list(ranges(b"abcdef", b"aBcDefMORE")),
                         [(1, b"B"), (3, b"D"), (6, b"MORE")])

    def test_installer_uses_local_factory_input(self):
        installer = (ROOT / "manage.sh").read_text(encoding="utf-8")
        self.assertIn("SOURCE=${GATEWAY_SOURCE:-/lge/app_ro/http-gateway}", installer)
        self.assertIn('cp -p "$SOURCE/$name" "$COPY/$name"', installer)
        self.assertIn('sh "$BASE/patch_binary.sh" apply "$COPY/$name"', installer)
        self.assertNotIn('"$BASE/bin/$name"', installer)

    def test_only_factory_inputs_listed(self):
        rows = [r.split() for r in (ROOT / "targets.tsv").read_text().splitlines() if not r.startswith("#")]
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row[1] == "factory" for row in rows))

    def test_reject_tls_helper_replacement(self):
        files = tree_files(ROOT)
        files["libgateway_tls.so"] += b"changed"
        with self.assertRaises(ValueError):
            audit(files)

    def test_all_python_sources_compile(self):
        for path in ROOT.rglob("*.py"):
            compile(path.read_text(encoding="utf-8"), str(path), "exec")


if __name__ == "__main__":
    unittest.main()
