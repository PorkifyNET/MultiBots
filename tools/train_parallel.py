"""Run independent Lua training experiments concurrently."""

from __future__ import annotations

import argparse
import io
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


TRAINING_PROGRESS = re.compile(r"TRAIN_PROGRESS=(?P<completed>\d+)/(?P<total>\d+)")


class ProgressDisplay:
    def __init__(self, stream: io.TextIOBase = sys.stdout) -> None:
        self.stream = stream
        self.interactive = stream.isatty()
        self.rows = 0
        if self.interactive:
            self._set_scroll_region()

    def _set_scroll_region(self) -> None:
        rows = shutil.get_terminal_size().lines
        if rows < 3 or rows == self.rows:
            return
        self.rows = rows
        self.stream.write(f"\x1b[s\x1b[1;{rows - 1}r\x1b[u")
        self.stream.flush()

    def message(self, text: str) -> None:
        self.stream.write(text + "\n")
        self.stream.flush()

    def update(self, text: str) -> None:
        if not self.interactive:
            self.message(text)
            return
        self._set_scroll_region()
        if not self.rows:
            self.message(text)
            return
        self.stream.write(
            f"\x1b[s\x1b[{self.rows};1H\x1b[2K{text[:shutil.get_terminal_size().columns]}\x1b[u"
        )
        self.stream.flush()

    def close(self) -> None:
        if self.interactive and self.rows:
            self.stream.write(f"\x1b[s\x1b[{self.rows};1H\x1b[2K\x1b[u\x1b[r")
            self.stream.flush()
            self.rows = 0


def training_fraction(line: str) -> tuple[float, int, int] | None:
    match = TRAINING_PROGRESS.search(line)
    if not match:
        return None
    completed = int(match.group("completed"))
    total = int(match.group("total"))
    if total < 1:
        return None
    return min(1.0, max(0.0, completed / total)), completed, total


def progress_line(fractions: list[float], finished: int, total: int,
                  completed_matches: list[int], planned_matches: list[int]) -> str:
    fraction = sum(fractions) / max(1, len(fractions))
    percentage = 100 if finished == total else min(99, int(fraction * 100))
    width = 30
    filled = percentage * width // 100
    bar = "#" * filled + "-" * (width - filled)
    matches_done, matches_planned = sum(completed_matches), sum(planned_matches)
    match_progress = (f" | matches {matches_done}/{matches_planned}"
                      if matches_planned else "")
    return (f"Training [{bar}] {percentage:3d}%{match_progress} | "
            f"experiments {finished}/{total} finished")


def run_experiment(index: int, seed: str, args: argparse.Namespace,
                   fractions: list[float], finished: list[int],
                   completed_matches: list[int], planned_matches: list[int],
                   output_queue: queue.Queue[str], output_lock: threading.Lock) -> tuple[int, str]:
    output_dir = Path(args.output_dir) / f"experiment_{index:03d}"
    command = [
        args.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", args.script,
        "-Mode", "train", "-Config", args.config,
        "-OutputDirectory", str(output_dir), "-ExperimentSeed", seed,
        "-ExperimentCount", "1", "-PopulationSize", str(args.population_size),
        "-Generations", str(args.generations), "-BalatroPath", args.balatro_path,
    ]
    if args.start_weights_path:
        command.extend(["-StartWeightsPath", args.start_weights_path])
    if args.player_logs:
        command.append("-PlayerLogs")
        command.extend(args.player_logs)
    process = subprocess.Popen(
        command, cwd=args.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    tail: list[str] = []
    pending = ""

    def process_line(line: str) -> None:
        tail.append(line)
        del tail[:-20]
        progress = training_fraction(line)
        if progress is not None:
            fraction, completed, total = progress
            with output_lock:
                fractions[index - 1] = fraction
                completed_matches[index - 1] = completed
                planned_matches[index - 1] = total
                output_queue.put(progress_line(
                    fractions, finished[0], args.experiment_count,
                    completed_matches, planned_matches,
                ))
        if not line.startswith("TRAIN_PROGRESS=") and not line.startswith("[Generation "):
            output_queue.put(f"Experiment {index:03d}: {line}")

    assert process.stdout is not None
    with process.stdout:
        while True:
            chunk = process.stdout.read1(4096)
            if not chunk:
                break
            pending += chunk.decode("utf-8", errors="replace")
            while "\r" in pending or "\n" in pending:
                cr = pending.find("\r") if "\r" in pending else len(pending)
                lf = pending.find("\n") if "\n" in pending else len(pending)
                split_at = min(cr, lf)
                line, pending = pending[:split_at], pending[split_at + 1:]
                if line:
                    process_line(line)
    if pending:
        process_line(pending)
    return_code = process.wait()
    with output_lock:
        fractions[index - 1] = 1.0
        finished[0] += 1
        output_queue.put(progress_line(
            fractions, finished[0], args.experiment_count,
            completed_matches, planned_matches,
        ))
    if return_code == 0:
        return return_code, f"Experiment {index:03d} complete: {output_dir}"
    return return_code, (
        f"Experiment {index:03d} failed with exit code {return_code}:\n"
        + "\n".join(f"  {line}" for line in tail)
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--powershell", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--experiment-count", type=int, required=True)
    parser.add_argument("--max-workers", type=int, default=0)
    parser.add_argument("--experiment-seed", default="")
    parser.add_argument("--population-size", type=int, default=0)
    parser.add_argument("--generations", type=int, default=0)
    parser.add_argument("--start-weights-path", default="")
    parser.add_argument("--player-logs", nargs="*", default=[])
    parser.add_argument("--balatro-path", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.experiment_count < 1:
        raise SystemExit("--experiment-count must be at least 1")
    cpu_count = os.cpu_count() or 1
    worker_count = args.max_workers or cpu_count
    if worker_count < 1:
        raise SystemExit("--max-workers must be positive")
    worker_count = min(worker_count, args.experiment_count)
    Path(args.output_dir).mkdir(parents=True, exist_ok=True)
    seeds = [
        f"{args.experiment_seed}-{index:03d}" if args.experiment_seed
        else uuid.uuid4().hex
        for index in range(1, args.experiment_count + 1)
    ]
    fractions = [0.0] * args.experiment_count
    completed_matches = [0] * args.experiment_count
    planned_matches = [0] * args.experiment_count
    finished = [0]
    output_queue: queue.Queue[str] = queue.Queue()
    output_lock = threading.Lock()
    print(
        f"Launching {args.experiment_count} independent experiments "
        f"with {worker_count} workers (logical CPUs: {cpu_count}).",
        flush=True,
    )
    display = ProgressDisplay()
    failures: list[str] = []

    def render_output(line: str) -> None:
        if line.startswith("Training ["):
            display.update(line)
        else:
            display.message(line)

    display.update(progress_line(
        fractions, finished[0], args.experiment_count, completed_matches, planned_matches
    ))
    try:
        with ThreadPoolExecutor(max_workers=worker_count) as executor:
            futures = {
                executor.submit(run_experiment, index, seed, args, fractions, finished,
                                completed_matches, planned_matches, output_queue, output_lock): index
                for index, seed in enumerate(seeds, start=1)
            }
            pending_futures = set(futures)
            while pending_futures:
                try:
                    line = output_queue.get(timeout=0.1)
                    render_output(line)
                except queue.Empty:
                    pass
                done = {future for future in pending_futures if future.done()}
                for future in done:
                    pending_futures.remove(future)
                    index = futures[future]
                    try:
                        return_code, message = future.result()
                    except Exception as error:
                        return_code = 1
                        message = f"Experiment {index:03d} failed to start: {error}"
                        with output_lock:
                            fractions[index - 1] = 1.0
                            finished[0] += 1
                            output_queue.put(progress_line(
                                fractions, finished[0], args.experiment_count,
                                completed_matches, planned_matches,
                            ))
                    display.message(message)
                    render_output(progress_line(
                        fractions, finished[0], args.experiment_count,
                        completed_matches, planned_matches,
                    ))
                    if return_code:
                        failures.append(message)
            while not output_queue.empty():
                render_output(output_queue.get())
    finally:
        display.close()
    if failures:
        print(f"{len(failures)} of {args.experiment_count} experiments failed.", flush=True)
        return 1
    print(f"All experiments complete: {args.output_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
