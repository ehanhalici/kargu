#!/usr/bin/env python3
"""Print model roots affected by changed TLA+/CFG sources, following local imports."""
from pathlib import Path
import re
import subprocess
import sys


def select_models(proof, changed):
    """Select configured roots transitively; reject unmapped model edits."""
    sources = {path.stem: path.read_text() for path in proof.glob("*.tla")}
    dependencies = {}
    for name, source in sources.items():
        source = re.sub(r"\(\*.*?\*\)", "", source, flags=re.S)
        source = re.sub(r"\\\*[^\n]*", "", source)
        imports = set(re.findall(r"\bINSTANCE\s+(\w+)", source))
        for match in re.finditer(r"\bEXTENDS\s+(\w+(?:\s*,\s*\w+)*)", source):
            imports.update(re.findall(r"\w+", match.group(1)))
        dependencies[name] = imports & sources.keys()
    roots = {path.stem for path in proof.glob("*.cfg") if path.stem in sources}
    closure = {}
    for root in roots:
        seen, pending = set(), [root]
        while pending:
            name = pending.pop()
            if name not in seen:
                seen.add(name)
                pending.extend(dependencies[name])
        closure[root] = seen
    result = set()
    for path in changed:
        path = Path(path)
        if path.parent != Path("proof") or path.suffix not in (".tla", ".cfg"):
            continue
        affected = ({path.stem} & roots if path.suffix == ".cfg" else
                    {root for root, imports in closure.items() if path.stem in imports})
        if not affected:
            raise ValueError(f"Changed model source has no configured acceptance root: {path}")
        result.update(affected)
    return sorted(result)


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    changed = subprocess.check_output(
        ["git", "diff", "--name-only", "-z", sys.argv[1], "HEAD"], cwd=root,
    ).decode().split("\0")
    print("\n".join(select_models(root / "proof", filter(None, changed))))
