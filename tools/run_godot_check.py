#!/usr/bin/env python3
"""Godot can exit zero after a script exception. Treat that as a failed check."""
import subprocess
import sys


def run(command):
    try:
        result = subprocess.run(command,capture_output=True,text=True,timeout=180)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Godot check timed out; incomplete output must not be accepted") from error
    output = result.stdout+result.stderr
    errors = [line for line in output.splitlines() if
              "SCRIPT ERROR:" in line or "Parse Error:" in line or
              ("ERROR:" in line and "resources still in use at exit" not in line)]
    if result.returncode or errors:
        raise RuntimeError("Godot check failed:\n"+"\n".join(errors[:20] or output.splitlines()[-20:]))
    return output


if __name__ == "__main__":
    try:
        print(run(sys.argv[1:]),end="")
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as error:
        print(error,file=sys.stderr)
        raise SystemExit(1)
