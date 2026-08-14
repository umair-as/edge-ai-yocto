---
name: devtool-workflow
description: "Modify, build, and export patches for a recipe in meta-edge-bsp using devtool. Use when iterating on recipe source (U-Boot, linux-renesas, app) instead of hand-editing patch files. Covers modify, build, commit, finish, and patch verification on Yocto 6.0 wrynose."
metadata:
  argument-hint: "<recipe-name> [modify|build|finish|reset]"
allowed-tools: "Read, Edit, Grep, Glob, Bash(kas *), Bash(bitbake*), Bash(devtool *), Bash(git *), Bash(make *), Bash(find *), Bash(ls *)"
---

# devtool workflow (edge-ai-yocto)

Read `.claude/rules/yocto-patterns.md` first — its "Patch headers",
"Patch + sstate cascade", and "Patch iteration — when to reach for
devtool" sections govern every patch this workflow emits, and
`recipe-metadata.md` covers `SRC_URI` operators.

## Wrynose changed how devtool handles local files

**`oe-local-files` no longer exists.** It was removed upstream in
OE-Core `ce8190c5190` ("devtool: Drop oe-local-files and simplify",
2024-05-01) — after scarthgap, so it is gone in wrynose. Guidance
written for scarthgap or earlier (including older versions of this
skill) is wrong on this point.

Do **not** look for `build/workspace/sources/<recipe>/oe-local-files/`.
It is never created. Its absence means nothing and destroys nothing.
The old "devtool reads that directory as the file list, so an absent
directory means delete them from the layer" failure mode disappeared
with the `_ls_tree` code path that caused it.

What `devtool finish` does now (`_export_local_files` in
`scripts/lib/devtool/standard.py`):

- **Committed** changes in the workspace source tree → extracted as
  numbered `.patch` files into the layer.
- **Uncommitted but tracked** changes (literally `git status
  --porcelain`, untracked `??` entries excluded) → classified against
  the recipe's non-patch `file://` list and copied directly over the
  files in recipe space.

For BSP recipes here (`u-boot`, `linux-renesas`) the workspace source
tree is the upstream git checkout. Your layer's `.cfg` fragments unpack
to `UNPACKDIR`, not into that tree, so devtool neither sees nor rewrites
them — **edit fragments directly in the layer**. That makes "commit
everything before finishing" the right habit here, but for a plain
reason: uncommitted work does not become a patch.

## 1. Enter the build environment

```bash
make shell
```

Or explicitly, when you need a specific composition:

```bash
kas shell kas/base.yml:kas/machines/rzv2l.yml
```

Prefer `make` — it resolves the kas composition for you (AGENTS.md,
"Build commands").

**Check the meta-arm U-Boot trap before `devtool modify u-boot`.**
`meta-arm` sets `BBCLASSEXTEND = "devupstream:target"` on every U-Boot
recipe and repoints `SRC_URI:class-devupstream` at denx mainline HEAD,
producing a sibling `virtual:devupstream:target:u-boot_<ver>.bb` that
inherits our patch list against a completely different upstream. We
drop it in `meta-edge-bsp/recipes-bsp/u-boot/u-boot_2024.07.bbappend`
with `BBCLASSEXTEND:remove = "devupstream:target"`. If you see
`virtual:devupstream:target:.../do_patch` failing with `can't find file
to patch`, that is the cause — see `.claude/rules/yocto-patterns.md`,
"meta-arm BBCLASSEXTEND trap on U-Boot".

## 2. Check workspace state

```bash
devtool status
devtool reset <recipe>    # only if you want a clean start
```

## 3. Modify

Conditional `SRC_URI` operations break override-branch handling — and
this layer uses `SRC_URI:append:smarc-rzv2l` in places. Check first:

```bash
bitbake-getvar -r <recipe> SRC_URI | grep -E '(:append:|:prepend:|:remove:)' || true
```

If any are present, or a previous `devtool modify` complained about
override branches:

```bash
devtool modify --no-overrides <recipe>     # -O
```

Otherwise `devtool modify <recipe>`.

This is not cosmetic: `_export_local_files` returns empty on any
override branch, so finishing from one silently exports nothing.

Verify immediately:

```bash
cd build/workspace/sources/<recipe>
git branch          # must show: * devtool  (or your --branch name)
git log --oneline   # upstream base + existing layer patches as commits
```

## 4. Build

```bash
devtool build <recipe>
```

Full image rebuild goes through the Makefile:

```bash
make base      # or dev
```

## 5. Edit and commit

```bash
cd build/workspace/sources/<recipe>
git branch                  # confirm before every commit
git add -p
git commit -m "component: what and why"
```

- One logical change per commit — `devtool finish` emits one numbered
  patch per commit.
- The commit body becomes the patch header. **`Upstream-Status:` is a
  build gate here**, not a style preference: `do_patch` fails with
  `Missing Upstream-Status in patch ... [patch-status]`. Default for
  repo-local DTS patches is `Inappropriate [board-specific
  configuration]`. Full vocabulary in `.claude/rules/yocto-patterns.md`.
- Never `git commit --amend` here — it moves the commit boundary devtool
  uses to decide what becomes a patch.
- Never `git format-patch` by hand — it bypasses numbering and
  `SRC_URI` wiring.

## 6. Finish

```bash
devtool finish <recipe> meta-edge-bsp/
```

Writes patches to the layer, updates `SRC_URI` in the recipe or
bbappend, removes the workspace bbappend, and resets the workspace
entry.

Destinations in this layer:

| Recipe | Patches land in |
|---|---|
| `u-boot` | `meta-edge-bsp/recipes-bsp/u-boot/files/patches/` |
| `linux-renesas` | `meta-edge-bsp/recipes-kernel/linux/files/` |

Kernel config fragments live in
`meta-edge-bsp/recipes-kernel/linux/files/cfg/` and U-Boot fragments in
`meta-edge-bsp/recipes-bsp/u-boot/files/` — both edited in the layer
directly, not through devtool.

Check where `devtool finish` actually put things; it does not know about
the `files/patches/` split and may write to `files/`. Move and fix
`SRC_URI` if so.

## 6a. Verify the generated patches (mandatory)

Do not rebuild or commit the layer until these pass.

```bash
L=meta-edge-bsp/recipes-bsp/u-boot/files/patches      # adjust per recipe

# Only expected files touched in the layer
git status --short $L

# Each patch touches only intended files (defconfig example)
grep '^---\|^+++' $L/00*.patch | grep -v 'configs/smarc-rzv2l_defconfig\|/dev/null'
# Expected: empty. Non-empty means the patch is contaminated.

# No upstream release artifacts crept in
grep -lE 'Makefile|CHANGELOG|release notes' $L/00*.patch
# Expected: no output.

# Patch count matches commit count
ls $L/00*.patch | wc -l
git -C build/workspace/sources/<recipe> log --oneline devtool ^devtool-base | wc -l
```

If any check fails: `devtool reset <recipe>`, `devtool modify
<recipe>`, re-apply cleanly, finish, re-verify.

Note from `.claude/rules/yocto-patterns.md` ("Patch + sstate cascade")
that editing a patch header alone invalidates sstate and reruns
`do_patch → do_compile → do_install → do_deploy`. Batch header edits
before kicking off a build.

## 7. Reset

```bash
devtool reset <recipe>
```

Workspace bbappend removed; the layer recipe takes over again. Source is
left in place under `build/workspace/sources/<recipe>/`. With `-r`,
devtool may preserve a modified tree under
`build/workspace/attic/sources/<recipe>.<timestamp>/`; reuse it with
`devtool modify <recipe> <attic-path>` or delete it manually.

## Defconfig workflow (U-Boot)

Kconfig dependency resolution means the effective config delta is larger
than a raw fragment declares. Capture the resolved truth:

```bash
cd build/workspace/sources/u-boot
git branch                       # confirm first

make smarc-rzv2l_defconfig
make savedefconfig
cp defconfig defconfig.upstream

scripts/kconfig/merge_config.sh .config \
  <repo>/meta-edge-bsp/recipes-bsp/u-boot/files/edge-uboot-hardening.cfg
# "value redefined" warnings are expected — upstream Kconfig already
# resolved those symbols.

make savedefconfig
grep -c CONFIG_OPTION_YOU_EXPECT defconfig

git add configs/smarc-rzv2l_defconfig    # ONLY this file
git commit -m "defconfig: apply edge base hardening"
```

We use the Renesas CIP fork precisely because mainline does not carry
`smarc-rzv2l_defconfig` — confirm you are on the vendor tree before
assuming a missing defconfig is your mistake.

Then finish + 6a. Head the patch with its regeneration recipe:

```
# Generated by savedefconfig against u-boot <version>.
# Regenerate on version bump: devtool modify u-boot →
#   make smarc-rzv2l_defconfig → merge_config.sh + edge-uboot*.cfg →
#   make savedefconfig → devtool finish
```

## Pitfalls

- **Wrong branch** — `git branch` before every `git add`. Committing on
  `master` puts upstream content in your diff.
- **Override branch** — finishing from one exports nothing at all. Use
  `--no-overrides`; this layer has `:append:smarc-rzv2l` operations.
- **`virtual:devupstream:target:...:do_patch` failures** — the meta-arm
  `BBCLASSEXTEND` trap, not your patch.
- **Missing `Upstream-Status:`** — hard build failure at `do_patch`.
- **Uncommitted work** — does not become a patch.
- **`AUTOREV` recipes** — pin `SRCREV` explicitly after finishing. The
  CVE-DB recipes are AUTOREV by design; leave those alone.
- **"already in your workspace"** — `devtool reset <recipe>` first.
- **Version bump breaks a defconfig patch** — regenerate via the
  defconfig workflow. Do not rebase hunks manually.
