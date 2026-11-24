#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host self-test for scripts/ci/preflight.py: path classification against the
real layer tree, board coverage (dynamic layers, board includes, kas chains,
shared files/ directories, flag-gated fragments, COMPATIBLE_MACHINE), and the
bitbake-tier refusals (held locks, missing kas/local.yml). Runs no BitBake.

  scripts/ci/preflight-selftest.py
"""

import fcntl
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("preflight", HERE / "preflight.py")
assert spec is not None and spec.loader is not None
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)

KERNEL = "meta-edge-bsp/recipes-kernel/linux/"
RPI_KERNEL = "meta-edge-bsp/dynamic-layers/raspberrypi/recipes-kernel/linux/linux-edge-mainline_6.18.bb"


def plan(paths, board="rzv2l"):
    return pf.build_plan(paths, board)


def names(p):
    return [n for n, _ in p.bitbake_checks()]


def uncovered(p):
    return [path for path, _ in p.not_covered]


class Recipes(unittest.TestCase):
    def test_recipe_file_selects_do_patch_for_its_pns(self):
        p = plan(
            ["meta-edge-bsp/recipes-support/edge-systemd-presets/files/90-edge.preset"]
        )
        self.assertEqual(p.recipes, {"edge-systemd-presets"})
        self.assertEqual(names(p), ["recipe-patch"])

    def test_bbappend_pn_strips_version_and_wildcard(self):
        p = plan(["meta-edge-distro/recipes-devtools/python/x.patch"])
        self.assertIn("python3", p.recipes)

    def test_deleted_bbappend_still_patches_its_recipe(self):
        p = plan(["meta-edge-distro/recipes-gone/zstd/zstd_1.5.7.bbappend"])
        self.assertEqual(p.recipes, {"zstd"})

    def test_recipe_edit_implies_parse_without_a_separate_parse(self):
        p = plan(
            [
                "meta-edge-bsp/recipes-support/edge-systemd-presets/edge-systemd-presets_1.0.bb"
            ]
        )
        self.assertTrue(p.parse)
        self.assertEqual(names(p), ["recipe-patch"])

    def test_images_and_packagegroups_get_parse_only(self):
        p = plan(["meta-edge-bsp/recipes-core/images/edge-image-base.bb"])
        self.assertEqual(p.recipes, set())
        self.assertEqual(names(p), ["parse"])

    def test_shared_files_dir_reaches_its_consumer_recipe(self):
        path = "meta-edge-bsp/recipes-bsp/u-boot/files/patches/x.patch"
        self.assertIn("u-boot", plan([path], "rzv2l").recipes)
        p = plan([path], "raspberrypi5")
        self.assertNotIn("u-boot", p.recipes)
        self.assertEqual(uncovered(p), [path])

    def test_compatible_machine_excludes_with_a_note(self):
        path = "meta-edge-bsp/recipes-support/drpai-tvm-app/x"
        self.assertEqual(plan([path], "rzv2l").recipes, {"drpai-tvm-app"})
        p = plan([path], "raspberrypi5")
        self.assertEqual(p.recipes, set())
        self.assertTrue(any("COMPATIBLE_MACHINE" in n for n in p.notes))

    def test_compatible_machine_family_value_is_left_to_bitbake(self):
        # (rzg2h-family|rzg2l-family) matches MACHINEOVERRIDES, not the name.
        p = plan(["meta-edge-bsp/recipes-bsp/trusted-firmware-a/x"], "rzv2l")
        self.assertIn("trusted-firmware-a", p.recipes)

    def test_compatible_machine_override_form_is_left_to_bitbake(self):
        path = "meta-edge-bsp/recipes-security/optee/x"
        self.assertIn("optee-os", plan([path], "raspberrypi5").recipes)

    def test_bundle_recipe_is_parse_only(self):
        p = plan(["meta-edge-bsp/recipes-ota/bundles/x"])
        self.assertNotIn("edge-bundle", p.recipes)
        self.assertEqual(names(p), ["parse"])

    def test_path_no_recipe_applies_is_not_covered(self):
        path = "meta-edge-bsp/recipes-none/no-recipe-here/files/x"
        p = plan([path])
        self.assertEqual(names(p), [])
        self.assertEqual(uncovered(p), [path])


class Kernel(unittest.TestCase):
    def test_shared_kernel_patch_follows_the_kernels_that_use_it(self):
        path = KERNEL + "files/patches/x.patch"
        self.assertEqual(names(plan([path], "rzv2l")), ["kernel-configure"])
        p = plan([path], "raspberrypi5")
        self.assertEqual(names(p), [])
        self.assertEqual(uncovered(p), [path])

    def test_fragment_and_policy_add_the_kspp_gate_on_every_board(self):
        for board in ("rzv2l", "raspberrypi5"):
            for path in (
                KERNEL + "files/cfg/security-hardening.cfg",
                KERNEL + "edge-kernel-policy.inc",
            ):
                with self.subTest(board=board, path=path):
                    self.assertEqual(
                        names(plan([path], board)),
                        ["kernel-configure", "kernel-hardening-check"],
                    )

    def test_board_specific_fragment_follows_its_kernel(self):
        path = KERNEL + "files/cfg/display-rzv2l.cfg"
        self.assertEqual(
            names(plan([path], "rzv2l")), ["kernel-configure", "kernel-hardening-check"]
        )
        p = plan([path], "raspberrypi5")
        self.assertEqual(names(p), [])
        self.assertEqual(uncovered(p), [path])

    def test_negated_gate_applies_by_default(self):
        # nfs-off.cfg is applied unless EDGE_DEV_NETBOOT=1.
        path = KERNEL + "files/cfg/nfs-off.cfg"
        self.assertEqual(
            names(plan([path])), ["kernel-configure", "kernel-hardening-check"]
        )

    def test_shared_include_without_recipe_is_parsed(self):
        path = "meta-edge-bsp/recipes-kernel/include/edge-sign-kernel-module.inc"
        p = plan([path])
        self.assertEqual(names(p), ["parse"])
        self.assertEqual(uncovered(p), [])

    def test_unreferenced_fragment_is_not_covered(self):
        path = KERNEL + "files/cfg/no-such-fragment.cfg"
        self.assertEqual(uncovered(plan([path])), [path])

    def test_flag_gated_fragment_is_not_covered(self):
        p = plan([KERNEL + "files/cfg/jtag-debug.cfg"])
        self.assertEqual(names(p), [])
        self.assertIn("EDGE_ENABLE_JTAG_DEBUG", p.not_covered[0][1])

    def test_khc_baseline_is_per_board(self):
        path = KERNEL + "files/khc/raspberrypi5-prod.baseline.json"
        self.assertEqual(uncovered(plan([path], "rzv2l")), [path])
        self.assertEqual(
            names(plan([path], "raspberrypi5")), ["kernel-hardening-check"]
        )

    def test_board_kernel_recipe_selects_configure(self):
        self.assertEqual(
            names(plan([RPI_KERNEL], "raspberrypi5")), ["kernel-configure"]
        )


class BoardsAndKas(unittest.TestCase):
    def test_other_boards_dynamic_layer_is_not_covered(self):
        p = plan([RPI_KERNEL], board="rzv2l")
        self.assertEqual(names(p), [])
        self.assertEqual(uncovered(p), [RPI_KERNEL])

    def test_dynamic_recipe_dir_selects_its_recipe(self):
        p = plan(
            [
                "meta-edge-bsp/dynamic-layers/meta-deepx-m1/recipes-runtime/dx-driver/x.patch"
            ],
            board="raspberrypi5",
        )
        self.assertEqual(p.recipes, {"dx-driver"})

    def test_board_include_of_another_machine_is_not_covered(self):
        inc = "meta-edge-bsp/conf/machine/include/edge-board-{}.inc"
        self.assertEqual(names(plan([inc.format("smarc-rzv2l")])), ["parse"])
        self.assertEqual(
            uncovered(plan([inc.format("ventuno-q")])), [inc.format("ventuno-q")]
        )

    def test_distro_conf_and_kas_chain_select_parse(self):
        for path in (
            "meta-edge-distro/conf/distro/include/edge-floor.inc",
            "kas/base.yml",
            "kas/machines/rzv2l.yml",
            "kas/bsp/renesas-rz.yml",
            "kas/accel/drpai-v2l.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(names(plan([path])), ["parse"])

    def test_kas_fragment_outside_the_chain_is_not_covered(self):
        for path in ("kas/tpm.yml", "kas/jtag-debug.yml", "kas/machines/ventuno-q.yml"):
            with self.subTest(path=path):
                p = plan([path])
                self.assertEqual(names(p), [])
                self.assertEqual(uncovered(p), [path])

    def test_docs_and_scripts_need_no_bitbake_and_are_not_unmapped(self):
        p = plan(["docs/dev/ci.md", "README.md", "scripts/dev/serial-console-tee.py"])
        self.assertEqual(names(p), [])
        self.assertEqual(p.unmapped, [])

    def test_unmapped_path_is_reported(self):
        p = plan(["meta-edge-bsp/files/some-blob.bin"])
        self.assertEqual(p.unmapped, ["meta-edge-bsp/files/some-blob.bin"])

    def test_boards_follow_kas_machines(self):
        self.assertEqual(
            set(pf.BOARDS),
            {f.stem for f in (pf.REPO / "kas" / "machines").glob("*.yml")},
        )
        self.assertEqual(pf.board_machine("rzv2l"), "smarc-rzv2l")

    def test_every_dynamic_layer_has_a_board_mapping(self):
        for layer in pf.LAYERS:
            for d in (pf.REPO / layer / "dynamic-layers").iterdir():
                with self.subTest(collection=d.name):
                    self.assertIn(d.name, pf.COLLECTION_BOARDS)

    def test_make_argv_carries_the_board(self):
        p = plan(["kas/base.yml"], board="ventuno-q")
        self.assertEqual(
            p.bitbake_checks(), [("parse", ("make", "parse", "BOARD=ventuno-q"))]
        )

    def test_recipe_task_runs_in_the_boards_kas_shell(self):
        p = plan(
            ["meta-edge-bsp/recipes-support/edge-systemd-presets/files/90-edge.preset"],
            board="raspberrypi5",
        )
        [(_, argv)] = p.bitbake_checks()
        self.assertEqual(
            argv[:5], ("env", "BOARD=raspberrypi5", "EDGE_PROFILE=dev", "bash", "-c")
        )
        self.assertTrue(
            argv[5].startswith(". scripts/env.sh >/dev/null && kas shell -c ")
        )
        self.assertIn("'bitbake edge-systemd-presets -c patch'", argv[5])
        self.assertIn(" kas/base.yml:kas/machines/raspberrypi5.yml", argv[5])
        self.assertNotIn("make", argv)


class SecondReview(unittest.TestCase):
    def test_no_khc_without_a_board_baseline(self):
        p = plan([KERNEL + "edge-kernel-policy.inc"], "ventuno-q")
        self.assertEqual(names(p), ["kernel-configure"])
        self.assertTrue(any("no KHC baseline" in n for n in p.notes))

    def test_undecidable_compatible_machine_is_noted_and_excludable(self):
        path = "meta-edge-bsp/recipes-bsp/trusted-firmware-a/x"
        p = plan([path], "ventuno-q")
        self.assertIn("trusted-firmware-a", p.recipes)
        self.assertTrue(
            any("--exclude-recipe trusted-firmware-a" in n for n in p.notes)
        )
        p = pf.build_plan([path], "ventuno-q", ["trusted-firmware-a"])
        self.assertEqual(p.recipes, set())

    def test_kas_patch_follows_the_patched_repo(self):
        for board, covered in (("rzv2l", True), ("ventuno-q", False)):
            with self.subTest(board=board):
                p = plan(["kas/patches/meta-renesas/0001-x.patch"], board)
                self.assertEqual(names(p), ["parse"] if covered else [])

    def test_prod_profile_include_is_not_covered_by_a_dev_parse(self):
        path = "meta-edge-distro/conf/distro/include/edge-profile-prod.inc"
        self.assertEqual(uncovered(plan([path])), [path])

    def test_boot_chain_class_follows_the_board(self):
        path = "meta-edge-distro/classes/edge-ab-uefi-uki.bbclass"
        self.assertEqual(uncovered(plan([path], "rzv2l")), [path])
        self.assertEqual(names(plan([path], "ventuno-q")), ["parse"])

    def test_doc_paths_are_counted(self):
        self.assertEqual(
            plan(["meta-edge-bsp/README.md", "kas/local.yml.example"]).docs, 2
        )


class ChangedPaths(unittest.TestCase):
    """Default diff base: the merge base with main, not HEAD."""

    def test_committed_branch_work_is_seen(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)

            def git(*args):
                subprocess.run(
                    [
                        "git",
                        "-C",
                        tmp,
                        "-c",
                        "user.name=t",
                        "-c",
                        "user.email=t@t",
                        *args,
                    ],
                    check=True,
                    capture_output=True,
                )

            git("init", "-q", "-b", "main")
            (repo / "a").write_text("a")
            git("add", "a")
            git("commit", "-q", "-m", "base")
            git("checkout", "-q", "-b", "topic")
            (repo / "committed").write_text("c")
            git("add", "committed")
            git("commit", "-q", "-m", "topic")
            (repo / "a").write_text("changed")
            (repo / "untracked").write_text("u")
            with mock.patch.object(pf, "REPO", repo):
                self.assertEqual(
                    pf.changed_paths(None), ["a", "committed", "untracked"]
                )


class Refusal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name)
        (self.repo / "build" / "rzv2l").mkdir(parents=True)
        (self.repo / "kas").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_local_yml_refuses_unless_allowed(self):
        self.assertIn("kas/local.yml", pf.refusal("rzv2l", False, self.repo))
        self.assertIsNone(pf.refusal("rzv2l", True, self.repo))

    def test_stale_unheld_lock_does_not_refuse(self):
        (self.repo / "kas" / "local.yml").write_text("")
        (self.repo / "build" / "rzv2l" / "bitbake.lock").write_text("")
        self.assertIsNone(pf.refusal("rzv2l", False, self.repo))

    def test_held_locks_refuse_for_every_board(self):
        (self.repo / "kas" / "local.yml").write_text("")
        for lock in ("bitbake.lock", ".agent-build.lock"):
            with self.subTest(lock=lock):
                path = self.repo / "build" / "rzv2l" / lock
                path.write_text("")
                with path.open("r") as fh:
                    fcntl.flock(fh, fcntl.LOCK_EX)
                    self.assertIn(lock, pf.refusal("rzv2l", True, self.repo))
                    # One build per host: another board's run refuses too.
                    self.assertIn(lock, pf.refusal("raspberrypi5", True, self.repo))


if __name__ == "__main__":
    unittest.main()
