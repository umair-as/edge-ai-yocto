#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Map changed paths to the cheapest check that exercises them.

Run before an image build. A broken patch or kernel fragment caught here costs
minutes; caught by the image build it costs the whole build.

Two tiers:
  host     scripts/ci/check.sh (repo invariants, shellcheck, host selftests).
           No BitBake. Always run unless --no-host.
  bitbake  one targeted task per affected area for --board: do_patch on the
           touched recipes, kernel do_configure, the KSPP gate, or a parse.
           Run only with --bitbake. Refused while any board's build directory
           is in use (one build per host), and when kas/local.yml is missing
           (no shared DL_DIR/SSTATE_DIR: a cold build) unless --allow-cold.

A path that the --board run does not exercise is reported as not covered,
with the reason: another board's dynamic layer or board include, a kas
fragment outside the board's default chain, a kernel fragment gated by a make
flag, a shared files/ directory applied by another board's recipe. A recipe
whose COMPATIBLE_MACHINE lists only other boards' machines is left out with a
note; image and bundle recipes get a parse only.

Changed paths default to everything since the merge base with origin/main
(else main): the branch's commits, uncommitted changes and untracked files.
--base REF compares against REF instead; --paths takes a list.

  scripts/ci/preflight.py [--plan] [--bitbake] [--board B] [--allow-cold]
                          [--no-host] [--base REF | --paths P ...]

Exit status: 0 the selected checks passed (or --plan), 1 a check failed,
3 the bitbake tier was refused.
"""

import argparse
import fcntl
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, field

REPO = pathlib.Path(__file__).resolve().parents[2]
LAYERS = ("meta-edge-bsp/", "meta-edge-distro/")
BOARDS = tuple(sorted(f.stem for f in (REPO / "kas" / "machines").glob("*.yml")))

# dynamic-layers/<collection> -> boards whose kas composition includes the
# collection (kas/machines/*.yml and the fragments they include).
COLLECTION_BOARDS = {
    "meta-rz-bsp": {"rzv2l"},
    "meta-rz-distro": {"rzv2l"},
    "raspberrypi": {"raspberrypi5"},
    "meta-deepx-m1": {"raspberrypi5"},
    "qcom": {"ventuno-q"},
    "virtualization-layer": set(BOARDS),
}

RECIPE_DIR_RE = re.compile(
    r"^(meta-edge-(?:bsp|distro)/(?:dynamic-layers/[^/]+/)?recipes-[^/]+/[^/]+)/"
)
KERNEL_DIR_RE = re.compile(
    r"^meta-edge-bsp/(?:dynamic-layers/[^/]+/)?recipes-kernel/linux/"
)
SHARED_KERNEL = "meta-edge-bsp/recipes-kernel/linux/"
KERNEL_POLICY = SHARED_KERNEL + "edge-kernel-policy.inc"
BOARD_INC_RE = re.compile(r"^meta-edge-bsp/conf/machine/include/edge-board-(.+)\.inc$")
KHC_BASELINE_RE = re.compile(
    re.escape(SHARED_KERNEL) + r"files/khc/(.+)-[a-z]+\.baseline\.json$"
)
INCLUDE_RE = re.compile(r"^\s*-\s*(kas/\S+\.ya?ml)\s*$")
METADATA_SUFFIXES = (".bb", ".bbappend", ".bbclass", ".inc", ".conf")
# Recipe directories with no source to patch; parse covers them.
NO_PATCH_DIRS = ("recipes-core/images", "recipes-core/packagegroups")
IMAGE_CLASSES = {"image", "core-image", "edge-ab-image", "bundle"}


def board_machine(board):
    f = REPO / "kas" / "machines" / f"{board}.yml"
    m = (
        re.search(r"^machine:\s*(\S+)", f.read_text(), re.MULTILINE)
        if f.is_file()
        else None
    )
    return m.group(1) if m else board


def kas_chain(board):
    """kas files the default `make <target> BOARD=<board>` composes."""
    todo, seen = ["kas/base.yml", f"kas/machines/{board}.yml"], set()
    while todo:
        f = todo.pop()
        if f in seen or not (REPO / f).is_file():
            continue
        seen.add(f)
        in_includes = False
        for line in (REPO / f).read_text().splitlines():
            if re.match(r"^\s*includes:\s*$", line):
                in_includes = True
            elif in_includes and (m := INCLUDE_RE.match(line)):
                todo.append(m.group(1))
            elif in_includes and line.strip() and not line.lstrip().startswith("#"):
                in_includes = False
    return seen


@dataclass
class Plan:
    board: str
    machine: str = ""
    chain: set = field(default_factory=set)
    recipes: set = field(default_factory=set)
    kernel: bool = False
    khc: bool = False
    parse: bool = False
    # (path, why this board's run does not exercise it)
    not_covered: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    docs: int = 0
    exclude: set = field(default_factory=set)
    unmapped: list = field(default_factory=list)
    evidence: dict = field(default_factory=dict)

    def bitbake_checks(self):
        """(name, make argv) for each selected bitbake-tier check, cheapest first."""
        b = f"BOARD={self.board}"
        out = []
        if self.recipes:
            task = " ".join(sorted(self.recipes)) + " -c patch"
            out.append(("recipe-patch", ("make", "bitbake-task", b, "BB_TASK=" + task)))
        if self.kernel:
            out.append(
                (
                    "kernel-configure",
                    ("make", "bitbake-task", b, "BB_TASK=virtual/kernel -c configure"),
                )
            )
        if self.khc:
            out.append(
                ("kernel-hardening-check", ("make", "kernel-hardening-check", b))
            )
        # Any targeted task parses the whole layer set first.
        if self.parse and not out:
            out.append(("parse", ("make", "parse", b)))
        return out

    def skip(self, path, why):
        self.not_covered.append((path, why))

    def want_khc(self, path):
        baseline = (
            REPO / SHARED_KERNEL / "files" / "khc" / f"{self.board}-prod.baseline.json"
        )
        if baseline.is_file():
            self.khc = True
            self.evidence.setdefault("kernel-hardening-check", path)
        else:
            self.note(f"no KHC baseline for {self.board}: KSPP gate not planned")

    def note(self, text):
        if text not in self.notes:
            self.notes.append(text)


def collection_of(path):
    m = re.match(r"^meta-edge-(?:bsp|distro)/dynamic-layers/([^/]+)/", path)
    return m.group(1) if m else None


def boards_of(path):
    coll = collection_of(path)
    return set(BOARDS) if coll is None else COLLECTION_BOARDS.get(coll, set())


def pn_of(filename):
    return re.split(r"[_%]", filename.rsplit(".", 1)[0], maxsplit=1)[0]


def recipe_files(recipe_dir):
    d = REPO / recipe_dir
    return sorted(d.glob("*.bb")) + sorted(d.glob("*.bbappend"))


def shared_consumers(rel_dir):
    """Recipe files that add ${EDGE_BSP_LAYERDIR}/<rel_dir>/files to their search
    path: a shared files/ directory is applied by a recipe elsewhere."""
    needle = "${EDGE_BSP_LAYERDIR}/" + rel_dir + "/files"
    out = []
    for layer in LAYERS:
        for f in sorted((REPO / layer).rglob("*.bb*")):
            if f.suffix in (".bb", ".bbappend") and needle in f.read_text(
                errors="replace"
            ):
                out.append(f.relative_to(REPO).as_posix())
    return out


def boot_chain(machine):
    inc = (
        REPO
        / "meta-edge-bsp"
        / "conf"
        / "machine"
        / "include"
        / f"edge-board-{machine}.inc"
    )
    m = (
        re.search(
            r'^EDGE_BOOT_CHAIN\s*[?]*=\s*"([^"]*)"', inc.read_text(), re.MULTILINE
        )
        if inc.is_file()
        else None
    )
    return m.group(1) if m else ""


def known_machines():
    return {board_machine(b) for b in BOARDS}


def machine_decision(recipe_file, machine):
    """("in"|"out"|"unknown"|None, value) for the recipe's COMPATIBLE_MACHINE.

    Decided only for a plain list of this repo's machine names. A value naming
    SoC families or other overrides (matched by BitBake against
    MACHINEOVERRIDES), or the :<machine> override form, is "unknown" and left
    to BitBake: a loud "was skipped" beats a silent drop. None: not set.
    """
    text = recipe_file.read_text(errors="replace")
    found = None
    for m in re.finditer(
        r'^COMPATIBLE_MACHINE(:[\w-]+)?\s*[?:]*=\s*"([^"]*)"', text, re.MULTILINE
    ):
        tokens = set(re.sub(r"[\^$()]", "", m.group(2)).split("|"))
        if m.group(1) or not tokens <= known_machines():
            found = ("unknown", m.group(2))
        elif machine not in tokens:
            return ("out", m.group(2))
        elif found is None:
            found = ("in", m.group(2))
    return found or (None, "")


def builds_image(recipe_file):
    """True for an image or bundle recipe: its do_unpack depends on a built
    image, so do_patch is not cheap. A same-directory require counts."""
    texts = [recipe_file.read_text(errors="replace")]
    for inc in re.findall(r"^(?:require|include)\s+(\S+)\s*$", texts[0], re.MULTILINE):
        f = recipe_file.parent / inc
        if f.is_file():
            texts.append(f.read_text(errors="replace"))
    for t in texts:
        for line in re.findall(r"^inherit\s+(.*)$", t, re.MULTILINE):
            if IMAGE_CLASSES & set(line.split()):
                return True
    return False


def add_recipes(plan, path, recipe_dir):
    """Add the recipes of recipe_dir to the do_patch set; return how many
    recipes were added or accounted for with a note."""
    n = 0
    for f in recipe_files(recipe_dir):
        pn = pn_of(f.name)
        if pn.startswith("packagegroup-"):
            continue
        n += 1
        if builds_image(f):
            plan.note(f"{pn}: image or bundle recipe, parse only")
            plan.parse = True
            plan.evidence.setdefault("parse", path)
            continue
        if pn in plan.exclude:
            plan.note(f"{pn}: excluded by --exclude-recipe")
            continue
        state, value = machine_decision(f, plan.machine)
        if state == "out":
            plan.note(f"{pn}: COMPATIBLE_MACHINE {value} skips it on {plan.machine}")
            continue
        if state == "unknown":
            plan.note(
                f"{pn}: COMPATIBLE_MACHINE {value} not decidable here; if do_patch "
                f"reports it skipped, rerun with --exclude-recipe {pn}"
            )
        plan.recipes.add(pn)
        plan.evidence.setdefault("recipe-patch", path)
    # A deleted bbappend still changes the recipe it amended.
    if path.endswith((".bb", ".bbappend")) and not (REPO / path).exists():
        plan.recipes.add(pn_of(path.rsplit("/", 1)[-1]))
        plan.evidence.setdefault("recipe-patch", path)
        n += 1
    return n


def fragment_users(name):
    """(recipe or include file, line) for each reference to file://cfg/<name>."""
    out = []
    for f in sorted((REPO / "meta-edge-bsp").rglob("*")):
        if f.suffix in (".bb", ".bbappend", ".inc") and f.is_file():
            for line in f.read_text(errors="replace").splitlines():
                if f"file://cfg/{name}" in line:
                    out.append((f.relative_to(REPO).as_posix(), line))
    return out


def classify_fragment(path, name, plan):
    """True when the board's default kernel configure applies the fragment."""
    users = fragment_users(name)
    if not users:
        plan.skip(path, "fragment not referenced by any recipe")
        return False
    # The shared kernel policy is required by every board's kernel.
    active = [
        (f, ln) for f, ln in users if f == KERNEL_POLICY or plan.board in boards_of(f)
    ]
    if not active:
        where = ", ".join(sorted({b for f, _ in users for b in boards_of(f)}))
        plan.skip(path, f"fragment applied by the kernel of {where}")
        return False
    # Opt-in only: `getVar('X') == '1'`. A `!= '1'` gate applies by default.
    gates = [re.search(r"getVar\('([A-Z0-9_]+)'\)\s*==\s*'1'", ln) for _, ln in active]
    if all(gates):
        var = ", ".join(sorted({g.group(1) for g in gates if g}))
        plan.skip(path, f"fragment applied only with {var}=1 (set by a make flag)")
        return False
    return True


def classify_kernel(path, plan):
    """Shared kernel policy, fragments, KHC baselines and patches."""
    if path.startswith(SHARED_KERNEL) and path != KERNEL_POLICY:
        rel = path[len(SHARED_KERNEL) :]
        m = KHC_BASELINE_RE.match(path)
        if m:
            if m.group(1) != plan.board:
                plan.skip(path, f"KHC baseline of board {m.group(1)}")
                return
            plan.want_khc(path)
            return
        if rel.startswith("files/cfg/"):
            if not classify_fragment(path, rel[len("files/cfg/") :], plan):
                return
        elif not rel.startswith("files/khc/"):
            # Patches and includes in the shared files/ reach only the kernels
            # whose recipe adds this directory to FILESEXTRAPATHS.
            users = shared_consumers("recipes-kernel/linux")
            boards = set().union(*(boards_of(u) for u in users)) if users else set()
            if plan.board not in boards:
                plan.skip(
                    path,
                    f"used by the kernel of {', '.join(sorted(boards)) or 'no board'}",
                )
                return
    plan.kernel = True
    plan.evidence.setdefault("kernel-configure", path)
    if path == KERNEL_POLICY or path.endswith(".cfg") or "/files/khc/" in path:
        plan.want_khc(path)


def classify(path, plan):
    """Record what exercises one changed path on plan.board."""
    if path.startswith("docs/") or path.endswith((".md", ".example")):
        plan.docs += 1
        return
    coll = collection_of(path)
    if coll is not None and coll not in COLLECTION_BOARDS:
        plan.unmapped.append(path)
        return
    if plan.board not in boards_of(path):
        plan.skip(
            path, f"dynamic layer composed only on {', '.join(sorted(boards_of(path)))}"
        )
        return
    m = re.match(r"^meta-edge-distro/conf/distro/include/edge-profile-(.+)\.inc$", path)
    if m and m.group(1) != "dev":
        plan.skip(
            path,
            f"loaded only with EDGE_PROFILE={m.group(1)} (make parse EDGE_PROFILE={m.group(1)})",
        )
        return
    m = re.match(r"^meta-edge-distro/classes/edge-ab-(.+)\.bbclass$", path)
    if m and m.group(1) != boot_chain(plan.machine):
        plan.skip(path, f"inherited only for EDGE_BOOT_CHAIN = {m.group(1)}")
        return
    m = BOARD_INC_RE.match(path)
    if m and m.group(1) != plan.machine:
        plan.skip(path, f"board include of MACHINE {m.group(1)}")
        return
    if path.startswith("kas/"):
        if path.startswith("kas/patches/"):
            repo = path.split("/")[2] if path.count("/") >= 3 else ""
            if any(
                re.search(
                    rf"^  {re.escape(repo)}:\s*$", (REPO / f).read_text(), re.MULTILINE
                )
                for f in plan.chain
                if repo
            ):
                plan.parse = True
                plan.evidence.setdefault("parse", path)
            else:
                plan.skip(
                    path, f"patches {repo or 'a repo'}, not composed on this board"
                )
        elif path in plan.chain:
            plan.parse = True
            plan.evidence.setdefault("parse", path)
        elif path.endswith((".yml", ".yaml")):
            plan.skip(
                path,
                "not in this board's default kas chain (a make flag or another board)",
            )
        else:
            plan.unmapped.append(path)
        return
    hit = False
    if KERNEL_DIR_RE.match(path):
        classify_kernel(path, plan)
        hit = True
    else:
        rd = RECIPE_DIR_RE.match(path)
        if rd and not rd.group(1).endswith(NO_PATCH_DIRS):
            recipe_dir = rd.group(1)
            hit = True
            found = add_recipes(plan, path, recipe_dir)
            if path.startswith(recipe_dir + "/files/") and recipe_dir.startswith(
                "meta-edge-bsp/"
            ):
                for user in shared_consumers(recipe_dir[len("meta-edge-bsp/") :]):
                    if plan.board in boards_of(user):
                        found += add_recipes(plan, user, user.rsplit("/", 1)[0])
                    else:
                        found += 1
                        plan.skip(
                            path,
                            f"also applied by {user.rsplit('/', 1)[-1]} "
                            f"({', '.join(sorted(boards_of(user)))})",
                        )
            if not found and not path.endswith(METADATA_SUFFIXES):
                # Fail closed: nothing here applies the path on this board.
                plan.skip(path, f"no recipe in {recipe_dir} applies it")
    if path.startswith(LAYERS) and path.endswith(METADATA_SUFFIXES):
        plan.parse = hit = True
        plan.evidence.setdefault("parse", path)
    if not hit and not path.startswith("scripts/"):
        plan.unmapped.append(path)


def build_plan(paths, board, exclude=()):
    plan = Plan(
        board=board,
        machine=board_machine(board),
        chain=kas_chain(board),
        exclude=set(exclude),
    )
    for p in sorted(set(paths)):
        classify(p, plan)
    return plan


def changed_paths(base):
    def git(*args):
        out = subprocess.run(
            ("git", *args), cwd=REPO, check=True, capture_output=True, text=True
        ).stdout
        return [line for line in out.splitlines() if line]

    if not base:
        base = "HEAD"
        for ref in ("origin/main", "main"):
            probe = subprocess.run(
                ("git", "rev-parse", "--quiet", "--verify", ref),
                cwd=REPO,
                capture_output=True,
                check=False,
            )
            if probe.returncode == 0:
                base = git("merge-base", ref, "HEAD")[0]
                break
    # git diff <commit> compares that commit with the working tree: committed
    # and uncommitted changes alike.
    paths = git("diff", "--name-only", "--no-renames", base)
    paths += git("ls-files", "--others", "--exclude-standard")
    return sorted(set(paths))


def lock_held(path):
    """True if another process holds an flock on path (absent file: False)."""
    try:
        fh = path.open("r")
    except FileNotFoundError:
        return False
    except PermissionError:
        return True
    with fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(fh, fcntl.LOCK_UN)
    return False


def refusal(board, allow_cold, repo=REPO):
    """Reason the bitbake tier must not run now, or None.

    Locks are probed with flock, not by existence: bitbake.lock stays behind
    after a clean exit (`make clean-lock`), and a stale file must not block.
    """
    # One build per host, whatever the board: probe every board's build dir.
    for build in sorted(d for d in (repo / "build").glob("*") if d.is_dir()):
        rel = build.relative_to(repo).as_posix()
        if lock_held(build / ".agent-build.lock"):
            return f"{rel}/.agent-build.lock is held (an agent-build.py run is active)"
        if lock_held(build / "bitbake.lock"):
            return f"{rel}/bitbake.lock is held (a BitBake server is running)"
    if not allow_cold and not (repo / "kas" / "local.yml").is_file():
        return (
            "kas/local.yml is missing: no shared DL_DIR/SSTATE_DIR, so the tasks "
            "would fetch and build cold (see kas/local.yml.example; --allow-cold overrides)"
        )
    return None


def run(argv):
    print("  $ " + " ".join(argv), flush=True)
    return subprocess.run(argv, cwd=REPO, check=False).returncode


def report(plan, paths, ran_bitbake):
    docs = f", {plan.docs} doc-only skipped" if plan.docs else ""
    print(f"preflight: {len(paths)} changed path(s){docs}, board {plan.board}")
    if not paths:
        print(
            "  WARNING: no changed paths, so nothing is checked; give --base REF or --paths"
        )
    for name, argv in plan.bitbake_checks():
        ev = plan.evidence.get(name) or plan.evidence.get("parse", "")
        print(f"  [bitbake] {name:24} {' '.join(argv[1:])}  (e.g. {ev})")
    if plan.recipes and len(plan.recipes) > 10:
        print(
            f"  note: do_patch spans {len(plan.recipes)} recipes and recreates their "
            "WORKDIRs; narrow with --base REF or --paths"
        )
    for note in plan.notes:
        print(f"  note: {note}")
    for p, why in plan.not_covered:
        print(f"  not covered on {plan.board}: {p}: {why}")
    if plan.unmapped:
        print(f"  no fast BitBake check for {len(plan.unmapped)} path(s):")
        for p in plan.unmapped[:15]:
            print(f"    {p}")
        if len(plan.unmapped) > 15:
            print(f"    ... {len(plan.unmapped) - 15} more")
    if plan.bitbake_checks() and not ran_bitbake:
        print(
            "  bitbake tier not run (pass --bitbake, or PREFLIGHT_ARGS=--bitbake via make)"
        )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--plan", action="store_true", help="print the plan, run nothing")
    ap.add_argument("--bitbake", action="store_true", help="also run the bitbake tier")
    ap.add_argument("--board", default=os.environ.get("BOARD", "rzv2l"), choices=BOARDS)
    ap.add_argument(
        "--allow-cold", action="store_true", help="run without kas/local.yml"
    )
    ap.add_argument("--no-host", action="store_true", help="skip scripts/ci/check.sh")
    ap.add_argument(
        "--exclude-recipe",
        action="append",
        default=[],
        metavar="PN",
        help="leave a recipe out of do_patch (one the board skips)",
    )
    src = ap.add_mutually_exclusive_group()
    src.add_argument(
        "--base", help="compare against REF instead of the working tree vs HEAD"
    )
    src.add_argument(
        "--paths", nargs="+", help="explicit changed paths (repo-relative)"
    )
    args = ap.parse_args(argv)

    paths = sorted(set(args.paths)) if args.paths else changed_paths(args.base)
    plan = build_plan(paths, args.board, args.exclude_recipe)
    report(plan, paths, args.bitbake)
    if args.plan:
        return 0

    failed = []
    if not args.no_host:
        print("\n== host: scripts/ci/check.sh", flush=True)
        if run(["scripts/ci/check.sh"]) != 0:
            failed.append("host")

    checks = plan.bitbake_checks()
    if args.bitbake and checks:
        why = refusal(args.board, args.allow_cold)
        if why:
            print(f"\npreflight: bitbake tier refused: {why}", file=sys.stderr)
            print(
                "  Coordinate with whoever owns the build; never remove a lock.",
                file=sys.stderr,
            )
            return 3
        for name, argv_ in checks:
            print(f"\n== bitbake: {name}", flush=True)
            if run(list(argv_)) != 0:
                failed.append(name)

    gap = (
        f"; {len(plan.not_covered)} path(s) not covered on {args.board}"
        if plan.not_covered
        else ""
    )
    print(
        "\npreflight: "
        + ("FAILED: " + ", ".join(failed) if failed else "all selected checks passed")
        + gap
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
