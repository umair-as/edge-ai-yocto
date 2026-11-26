#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""The Makefile's bitbake-running targets, the build launcher's BUILD_TARGETS
and the parallel-build hook's MAKE_BUILD_TARGETS name the same targets.

A target missing from either set starts a second bitbake beside a running
build. Reads files only; no make, kas or bitbake runs.

Usage: build-targets-selftest.py [MAKEFILE]
"""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK_NAME = "no-parallel-bitbake.py"
# Recipe text that ends in bitbake: the kas_run macro, an interactive kas
# shell, and the CI script behind `make ci`. `kas lock` and `kas
# for-all-repos` only resolve and visit the layer repositories.
BITBAKE_RECIPE = re.compile(r"\$\(call kas_run,|\$\(KAS\) shell\b|local-check\.sh")
RULE = re.compile(r"^([A-Za-z0-9_.-]+)\s*:(?!=)([^#\n]*)")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def makefile_targets(text):
    """(every rule target, the targets whose recipe or prerequisites run bitbake)."""
    recipes, prerequisites, current = {}, {}, None
    for line in text.splitlines():
        rule = RULE.match(line)
        if line.startswith("\t"):
            if current:
                recipes[current] = recipes.get(current, "") + line + "\n"
        elif rule:
            current, rest = rule.group(1), rule.group(2)
            if current.startswith("."):
                # .PHONY and the like list targets; they are not targets.
                current = None
                continue
            recipes.setdefault(current, "")
            # `target: VAR = value` sets a variable; it lists no prerequisites.
            if "=" not in rest:
                prerequisites.setdefault(current, set()).update(
                    rest.replace("|", " ").split()
                )
        elif line.strip() and not line.startswith("#"):
            current = None
    running = {
        target for target, recipe in recipes.items() if BITBAKE_RECIPE.search(recipe)
    }
    while True:
        more = {t for t, needs in prerequisites.items() if needs & running} - running
        if not more:
            return set(recipes), running
        running |= more


def check(makefile, launcher, hook):
    """Return the list of mismatches; empty when the three agree."""
    defined, running = makefile_targets(makefile)
    problems = []
    if launcher != hook:
        problems.append(f"launcher and hook differ: {sorted(launcher ^ hook)}")
    for name, targets in (
        ("launcher BUILD_TARGETS", launcher),
        ("hook MAKE_BUILD_TARGETS", hook),
    ):
        if running - targets:
            problems.append(
                f"{name} lacks bitbake-running Makefile targets: {sorted(running - targets)}"
            )
        # A name the Makefile does not define is harmless (a target that has
        # not landed here); a defined target that runs no bitbake is stale.
        stale = (targets & defined) - running
        if stale:
            problems.append(
                f"{name} lists Makefile targets that run no bitbake: {sorted(stale)}"
            )
    return problems


def selftest():
    sample = (
        "KAS = kas\nkas_run = $(1) $(KAS) shell -c '$(2)' $(STACK)\n.PHONY: a\n"
        "img: | $(DIRS) ## image\n\t@echo x\n\t$(call kas_run,P=1,bitbake img)\n"
        "img: VAR = 1\n"
        "gate: img ## depends on a bitbake target\n\tgate.py\n"
        "sh:\n\tP=1 $(KAS) shell $(STACK)\n"
        "ci:\n\tscripts/ci/local-check.sh\n"
        "lock:\n\t$(KAS) lock $(STACK)\n"
        "help: ## list\n\t@grep kas_run Makefile\n"
    )
    defined, running = makefile_targets(sample)
    assert running == {"img", "gate", "sh", "ci"}, running
    assert defined == {"img", "gate", "sh", "ci", "lock", "help"}, defined
    good = {"img", "gate", "sh", "ci"}
    assert check(sample, good, good) == []
    assert check(sample, good | {"not-defined-here"}, good | {"not-defined-here"}) == []
    assert (
        len(check(sample, good - {"gate"}, good)) == 2
    )  # sets differ; launcher lacks one
    assert len(check(sample, good | {"lock"}, good | {"lock"})) == 2  # stale in both


def main():
    selftest()
    makefile = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Makefile"
    launcher = load(
        ROOT / "scripts/agent-build/agent-build.py", "agent_build"
    ).BUILD_TARGETS
    # Located by name: scripts do not spell out the agent-tooling directory.
    found = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "--", f"*/{HOOK_NAME}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    if len(found) != 1:
        print(f"FAIL expected one tracked {HOOK_NAME}, found {found}")
        return 1
    hook = load(ROOT / found[0], "parallel_build_hook").MAKE_BUILD_TARGETS
    problems = check(makefile.read_text(), launcher, hook)
    for problem in problems:
        print(f"FAIL {problem}")
    if not problems:
        print(
            f"ok   {len(launcher)} build targets agree with {makefile.name} and the hook"
        )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
