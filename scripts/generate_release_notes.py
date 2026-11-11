#!/usr/bin/env python3
"""Package branch changes since main as About page release notes."""

import json
import subprocess
import sys
from pathlib import Path


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def main() -> None:
    repo = Path(sys.argv[1])
    output = Path(sys.argv[2])
    try:
        base = git(repo, "rev-parse", "--verify", "refs/remotes/origin/main")
    except subprocess.CalledProcessError:
        base = git(repo, "rev-parse", "--verify", "refs/heads/main")
    fork = git(repo, "merge-base", base, "HEAD")
    changed = git(repo, "diff", "--name-only", fork, "HEAD")
    notes = []
    if changed:
        notes = [line for line in git(repo, "log", "--reverse", "--format=%s", f"{fork}..HEAD").splitlines() if line]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(notes, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
