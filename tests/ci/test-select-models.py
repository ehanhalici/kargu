#!/usr/bin/env python3
"""Offline model selection contracts; these tests never execute TLC."""
import importlib.util
from pathlib import Path
import tempfile
import os
import subprocess
import sys

sys.dont_write_bytecode = True
import unittest

spec = importlib.util.spec_from_file_location("selector", Path(__file__).with_name("select-models.py"))
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class ModelSelectionTests(unittest.TestCase):
    def test_repository_sources_are_mapped(self):
        proof = Path(__file__).resolve().parents[2] / "proof"
        for source in list(proof.glob("*.tla")) + list(proof.glob("*.cfg")):
            with self.subTest(source=source.name):
                self.assertTrue(selector.select_models(proof, [f"proof/{source.name}"]))
        self.assertEqual(selector.select_models(proof, ["todo.md", "proof/README.md"]), [])
        self.assertEqual(selector.select_models(proof, ["proof/EditJournalMC.cfg"]), ["EditJournalMC"])

    def test_transitive_import_and_instance(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = Path(directory)
            for name, text in {"Root": "EXTENDS Middle", "Middle": "LOCAL X == INSTANCE Leaf",
                               "Leaf": "", "Other": ""}.items():
                (proof / f"{name}.tla").write_text(text)
            (proof / "Root.cfg").touch()
            (proof / "Other.cfg").touch()
            self.assertEqual(selector.select_models(proof, ["proof/Leaf.tla"]), ["Root"])
            with self.assertRaises(ValueError):
                selector.select_models(proof, ["proof/Unmapped.tla"])

    def test_configured_runner_arguments_without_model_execution(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "tlc"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$KARGU_TEST_TLC_ARGS"\n'
                            'echo "Model checking completed. No error has been found."\n')
            fake.chmod(0o755)
            record = Path(directory) / "args"
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       KARGU_TEST_TLC_ARGS=str(record))
            result = subprocess.run(["bash", "proof/run_tlc.sh", "--model", "EditJournalMC"],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(record.read_text().splitlines()[-3:],
                             ["-config", "EditJournalMC.cfg", "EditJournalMC.tla"])
            record.unlink()
            result = subprocess.run(["bash", "proof/run_tlc.sh", "--model", "../invalid"],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(record.exists())


if __name__ == "__main__":
    unittest.main()
