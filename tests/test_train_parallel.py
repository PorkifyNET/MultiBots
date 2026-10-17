import argparse
import importlib.util
import io
import os
import queue
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "train_parallel.py"
SPEC = importlib.util.spec_from_file_location("train_parallel", MODULE_PATH)
assert SPEC and SPEC.loader
train_parallel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(train_parallel)


class TrainingProgressTests(unittest.TestCase):
    def test_interactive_display_pins_progress_below_scrolling_messages(self) -> None:
        class Terminal(io.StringIO):
            def isatty(self) -> bool:
                return True

        terminal = Terminal()
        with patch.object(train_parallel.shutil, "get_terminal_size",
                          return_value=os.terminal_size((80, 24))):
            display = train_parallel.ProgressDisplay(terminal)
            display.message("Experiment 001: match finished")
            display.update("Training [###---------------------------]  10%")
            display.close()

        output = terminal.getvalue()
        self.assertIn("\x1b[1;23r", output)
        self.assertIn("\x1b[24;1H\x1b[2KTraining [###", output)
        self.assertLess(output.index("Experiment 001: match finished"),
                        output.index("\x1b[24;1H\x1b[2KTraining"))
        self.assertTrue(output.endswith("\x1b[r"))

    def test_match_progress_maps_to_experiment_fraction(self) -> None:
        self.assertEqual(
            train_parallel.training_fraction("[Match] seed finished; TRAIN_PROGRESS=25/100"),
            (0.25, 25, 100),
        )

    def test_invalid_match_progress_is_ignored(self) -> None:
        self.assertIsNone(train_parallel.training_fraction("TRAIN_PROGRESS=3/0"))
        self.assertIsNone(train_parallel.training_fraction("Generation 3 complete"))

    def test_parallel_progress_reaches_100_only_when_workers_finish(self) -> None:
        self.assertIn(
            " 99% ",
            train_parallel.progress_line([1.0, 0.99], 1, 2, [100, 99], [100, 100]),
        )
        self.assertIn(
            "100%",
            train_parallel.progress_line([1.0, 0.99], 2, 2, [100, 99], [100, 100]),
        )

    @unittest.skipUnless(os.name == "nt" and shutil.which("powershell.exe"),
                         "requires Windows PowerShell")
    def test_worker_output_is_echoed_and_updates_progress(self) -> None:
        powershell = shutil.which("powershell.exe")
        assert powershell
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            worker_script = root / "worker.ps1"
            worker_script.write_text(
                "Write-Output '[Match] Selecting validation seeds: starting 1/2'\n"
                "Write-Output '[Match] Selecting validation seeds: finished 1/2'\n"
                "Write-Output 'TRAIN_PROGRESS=1/2'\n",
                encoding="utf-8",
            )
            args = argparse.Namespace(
                output_dir=str(root), powershell=powershell, script=str(worker_script),
                config="unused", root=str(root), population_size=2, generations=2,
                balatro_path=str(root), experiment_count=1,
                start_weights_path="", player_logs=[],
            )
            fractions = [0.0]
            finished = [0]
            completed_matches = [0]
            planned_matches = [0]
            output_queue = queue.Queue()
            result = train_parallel.run_experiment(
                1, "test-seed", args, fractions, finished, completed_matches,
                planned_matches, output_queue, threading.Lock()
            )

        self.assertEqual(result[0], 0)
        self.assertEqual(finished[0], 1)
        self.assertEqual(fractions[0], 1.0)
        self.assertEqual(completed_matches[0], 1)
        self.assertEqual(planned_matches[0], 2)
        updates = []
        while not output_queue.empty():
            updates.append(output_queue.get())
        self.assertTrue(any("Experiment 001: [Match] Selecting validation seeds: starting" in update
                            for update in updates))
        self.assertTrue(any(" 50% " in update and "matches 1/2" in update for update in updates))
        self.assertIn("100%", updates[-1])


if __name__ == "__main__":
    unittest.main()
