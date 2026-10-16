// SPDX-License-Identifier: MIT
/*
 * Regression test for slot hooks on RAUC's boot-emmc handler, built inside a
 * RAUC source tree (test/) and linked against librauc. Runs the real handler
 * from get_update_handler() with a real hook script; only the eMMC is
 * replaced (emmc_shim.so via LD_PRELOAD).
 *
 * RAUC 1.15.2 hands the hooks a temporary slot without name/class, so
 * run_slot_hook_extra_env() refuses and every hooked boot-emmc install fails
 * before writing. With the fix: pre-install runs before the inactive partition
 * is written, post-install after it and before EXT_CSD is flipped, and a
 * failing post-install leaves EXT_CSD unchanged.
 */
#include <locale.h>
#include <glib.h>
#include <glib/gstdio.h>

#include "context.h"
#include "manifest.h"
#include "slot.h"
#include "update_handler.h"

typedef struct {
	gchar *tmpdir;
	gchar *log;
	gchar *extcsd;
} Fixture;

static void set_up(Fixture *f, gconstpointer data)
{
	if (g_getenv("BOOT_EMMC_DEVDIR")) {
		f->tmpdir = g_strdup(g_getenv("BOOT_EMMC_DEVDIR"));
		g_assert_cmpint(g_mkdir_with_parents(f->tmpdir, 0700), ==, 0);
	} else {
		f->tmpdir = g_dir_make_tmp("rauc-boot-emmc-XXXXXX", NULL);
	}
	g_assert_nonnull(f->tmpdir);
	f->log = g_getenv("SHIM_LOG") ? g_strdup(g_getenv("SHIM_LOG")) : NULL;
	f->extcsd = g_strdup(g_getenv("SHIM_EXTCSD"));
	g_assert_nonnull(f->log);
	g_assert_nonnull(f->extcsd);
	g_assert_true(g_file_set_contents(f->log, "", 0, NULL));
	g_assert_true(g_file_set_contents(f->extcsd, "0x08\n", -1, NULL)); /* boot0 enabled */
}

static void tear_down(Fixture *f, gconstpointer data)
{
	g_free(f->tmpdir);
	g_free(f->log);
	g_free(f->extcsd);
}

static gchar *dev_path(Fixture *f, const gchar *name)
{
	return g_build_filename(f->tmpdir, name, NULL);
}

/* hooks: "", "pre", "post" or "both"; fail: "", "pre" or "post" */
static gboolean run(Fixture *f, const gchar *hooks, const gchar *fail, GError **error)
{
	g_autofree gchar *base = dev_path(f, "mmcblk0");
	g_autofree gchar *b0 = dev_path(f, "mmcblk0boot0");
	g_autofree gchar *b1 = dev_path(f, "mmcblk0boot1");
	g_autofree gchar *img = dev_path(f, "bootchain.img");
	g_autofree gchar *hook = dev_path(f, "hook.sh");
	g_autofree gchar *script = NULL;
	g_autofree gchar *seed0 = g_malloc(1 << 20);
	g_autofree gchar *seed1 = g_malloc(1 << 20);
	g_autofree gchar *payload = g_malloc(64 << 10);
	g_autoptr(RaucImage) image = g_new0(RaucImage, 1);
	g_autoptr(RaucSlot) slot = g_new0(RaucSlot, 1);
	img_to_slot_handler handler;

	/* Distinct non-zero contents, so an erase is as visible as a write. */
	memset(payload, 0x5a, 64 << 10);
	memset(seed0, 0xa5, 1 << 20);
	memset(seed1, 0xc3, 1 << 20);
	g_assert_true(g_file_set_contents(base, "", 0, NULL));
	g_assert_true(g_file_set_contents(b0, seed0, 1 << 20, NULL));
	g_assert_true(g_file_set_contents(b1, seed1, 1 << 20, NULL));
	g_assert_true(g_file_set_contents(img, payload, 64 << 10, NULL));

	if (g_str_equal(hooks, "guard"))
		script = g_strdup_printf("#!/bin/sh\necho \"hook $1 (guard)\" >> %s\nexec %s \"$@\"\n",
				f->log, g_getenv("RZB_SLOT_HOOK"));
	else
	script = g_strdup_printf(
			"#!/bin/sh\n"
			"echo \"hook $1 name=$RAUC_SLOT_NAME class=$RAUC_SLOT_CLASS type=$RAUC_SLOT_TYPE "
			"dev=$RAUC_SLOT_DEVICE activating=$RAUC_BOOT_PARTITION_ACTIVATING "
			"b1=$(head -c 1 %s | od -An -tx1 | tr -d ' ')\" >> %s\n"
			"case \"$1\" in slot-%s-install) exit 1 ;; esac\n"
			"exit 0\n",
			b1, f->log, (fail && *fail) ? fail : "none");
	g_assert_true(g_file_set_contents(hook, script, -1, NULL));
	g_assert_cmpint(g_chmod(hook, 0755), ==, 0);

	image->slotclass = g_strdup("bootloader");
	image->filename = g_strdup(img);
	image->type = g_strdup(derive_image_type_from_filename_pattern(image->filename));
	image->checksum.type = G_CHECKSUM_SHA256;
	image->checksum.digest = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (guchar *)payload, 64 << 10);
	image->checksum.size = 64 << 10;
	image->hooks.pre_install = g_str_equal(hooks, "pre") || g_str_equal(hooks, "both") || g_str_equal(hooks, "guard");
	image->hooks.post_install = g_str_equal(hooks, "post") || g_str_equal(hooks, "both") || g_str_equal(hooks, "guard");

	slot->name = g_intern_string("bootloader.0");
	slot->sclass = g_intern_string("bootloader");
	slot->type = g_strdup("boot-emmc");
	slot->device = g_strdup(base);
	slot->state = ST_INACTIVE;

	r_context_conf()->configpath = g_strdup("test/test.conf");
	r_context_conf()->mountprefix = g_strdup(f->tmpdir);
	r_context();

	handler = get_update_handler(image, slot, error);
	g_assert_nonnull(handler);
	return handler(image, slot, *hooks ? hook : NULL, error);
}

/* sha256 of a file's full contents. */
static gchar *file_sha(const gchar *path)
{
	g_autofree gchar *d = NULL;
	gsize len = 0;

	g_assert_true(g_file_get_contents(path, &d, &len, NULL));
	return g_compute_checksum_for_data(G_CHECKSUM_SHA256, (guchar *)d, len);
}

/* sha256 of n bytes of value v: what an untouched seeded partition hashes to. */
static gchar *seed_sha(guchar v, gsize n)
{
	g_autofree gchar *d = g_malloc(n);

	memset(d, v, n);
	return g_compute_checksum_for_data(G_CHECKSUM_SHA256, (guchar *)d, n);
}

/* Both boot partitions still hold exactly their seed: nothing cleared or written. */
static void assert_untouched(Fixture *f, gboolean b0_too)
{
	g_autofree gchar *b0 = dev_path(f, "mmcblk0boot0");
	g_autofree gchar *b1 = dev_path(f, "mmcblk0boot1");
	g_autofree gchar *h0 = file_sha(b0), *h1 = file_sha(b1);
	g_autofree gchar *s0 = seed_sha(0xa5, 1 << 20), *s1 = seed_sha(0xc3, 1 << 20);

	if (b0_too)
		g_assert_cmpstr(h0, ==, s0);
	g_assert_cmpstr(h1, ==, s1);
}

static gchar *slurp(const gchar *path)
{
	gchar *s = NULL;

	g_assert_true(g_file_get_contents(path, &s, NULL, NULL));
	return s;
}

/* Index of the first line in log containing needle, or -1. */
static gint line_of(const gchar *log, const gchar *needle)
{
	g_auto(GStrv) lines = g_strsplit(log, "\n", -1);

	for (gint i = 0; lines[i]; i++)
		if (strstr(lines[i], needle))
			return i;
	return -1;
}

static void test_no_hooks(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *pc = NULL;

	g_assert_true(run(f, "", "", &err));
	g_assert_no_error(err);
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x10\n"); /* boot1 enabled */
}

static void test_pre_post_order(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *log = NULL, *pc = NULL;
	g_autofree gchar *base = dev_path(f, "mmcblk0");
	gint pre, post, flip;

	g_assert_true(run(f, "both", "", &err));
	g_assert_no_error(err);
	log = slurp(f->log);
	pre = line_of(log, "hook slot-pre-install");
	post = line_of(log, "hook slot-post-install");
	flip = line_of(log, "extcsd-write index=179 value=0x10");
	g_assert_cmpint(pre, >=, 0);
	g_assert_cmpint(post, >, pre);
	g_assert_cmpint(flip, >, post);
	/* pre-install sees the inactive partition unwritten, post-install written */
	g_assert_nonnull(strstr(log, "hook slot-pre-install name=bootloader.0 class=bootloader type=boot-emmc"));
	g_assert_cmpint(line_of(log, "slot-pre-install"), ==, line_of(log, "b1=c3"));
	g_assert_cmpint(line_of(log, "slot-post-install"), ==, line_of(log, "b1=5a"));
	g_assert_cmpint(line_of(log, "activating=1"), ==, pre);
	g_assert_nonnull(strstr(log, g_strdup_printf("dev=%s ", base)));
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x10\n");
}

static void test_post_fail_no_flip(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *log = NULL, *pc = NULL;

	g_assert_false(run(f, "both", "post", &err));
	g_assert_nonnull(err);
	g_clear_error(&err);
	log = slurp(f->log);
	g_assert_cmpint(line_of(log, "hook slot-post-install"), >=, 0);
	g_assert_cmpint(line_of(log, "extcsd-write"), ==, -1);
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x08\n"); /* boot0 stays enabled */
	{
		g_autofree gchar *b0 = dev_path(f, "mmcblk0boot0");
		g_autofree gchar *h0 = file_sha(b0), *s0 = seed_sha(0xa5, 1 << 20);

		g_assert_cmpstr(h0, ==, s0); /* the active partition is never touched */
	}
}

static void test_pre_fail_no_write(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *pc = NULL;

	g_assert_false(run(f, "both", "pre", &err));
	g_assert_nonnull(err);
	g_clear_error(&err);
	assert_untouched(f, TRUE);
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x08\n");
}

/* Approval the RZ/V2L pre-install handler leaves for the guard slot hook. */
static void write_approval(const gchar *digest)
{
	g_autofree gchar *boot_id = NULL;
	g_autofree gchar *body = NULL;
	g_autofree gchar *path = g_build_filename(g_getenv("RZB_RUN_DIR"), "approved", NULL);

	g_assert_true(g_file_get_contents(g_getenv("RZB_BOOT_ID_FILE"), &boot_id, NULL, NULL));
	g_strstrip(boot_id);
	body = g_strdup_printf("format=rzv2l-emmc-bootpart-v1\nimage_digest=%s\ntarget=1\nboot_id=%s\ntransaction=c-test\n",
			digest, boot_id);
	g_assert_cmpint(g_mkdir_with_parents(g_getenv("RZB_RUN_DIR"), 0700), ==, 0);
	g_assert_true(g_file_set_contents(path, body, -1, NULL));
}

static gchar *payload_digest(void)
{
	g_autofree gchar *payload = g_malloc(64 << 10);

	memset(payload, 0x5a, 64 << 10);
	return g_compute_checksum_for_data(G_CHECKSUM_SHA256, (guchar *)payload, 64 << 10);
}

/* Real RAUC handler + the RZ/V2L guard slot hook: approval consumed by
 * pre-install, read-back by post-install, then the flip. */
static void test_guard_hooks(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *digest = payload_digest();
	g_autofree gchar *ap = g_build_filename(g_getenv("RZB_RUN_DIR"), "approved", NULL);
	g_autofree gchar *pc = NULL, *log = NULL;

	if (!g_getenv("RZB_SLOT_HOOK")) {
		g_test_skip("RZB_SLOT_HOOK not set");
		return;
	}
	write_approval(digest);
	g_assert_true(run(f, "guard", "", &err));
	g_assert_no_error(err);
	g_assert_false(g_file_test(ap, G_FILE_TEST_EXISTS)); /* consumed */
	log = slurp(f->log);
	g_assert_cmpint(line_of(log, "extcsd-write index=179 value=0x10"), >, line_of(log, "hook slot-post-install (guard)"));
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x10\n");
}

/* Without the handler's approval the guard pre-install refuses: nothing
 * written, no flip. */
static void test_guard_no_approval(Fixture *f, gconstpointer data)
{
	GError *err = NULL;
	g_autofree gchar *ap = NULL, *pc = NULL;

	if (!g_getenv("RZB_SLOT_HOOK")) {
		g_test_skip("RZB_SLOT_HOOK not set");
		return;
	}
	ap = g_build_filename(g_getenv("RZB_RUN_DIR"), "approved", NULL);
	g_remove(ap);
	g_assert_false(run(f, "guard", "", &err));
	g_assert_nonnull(err);
	g_clear_error(&err);
	assert_untouched(f, TRUE);
	pc = slurp(f->extcsd);
	g_assert_cmpstr(pc, ==, "0x08\n");
}

int main(int argc, char *argv[])
{
	setlocale(LC_ALL, "C");
	g_test_init(&argc, &argv, NULL);
	/* A refused hook dispatch logs CRITICAL; keep it non-fatal so the test
	 * reports the handler's result instead of aborting. */
	g_log_set_always_fatal(G_LOG_LEVEL_ERROR);

	g_test_add("/boot_emmc_hooks/no_hooks", Fixture, NULL, set_up, test_no_hooks, tear_down);
	g_test_add("/boot_emmc_hooks/pre_post_order", Fixture, NULL, set_up, test_pre_post_order, tear_down);
	g_test_add("/boot_emmc_hooks/post_fail_no_flip", Fixture, NULL, set_up, test_post_fail_no_flip, tear_down);
	g_test_add("/boot_emmc_hooks/pre_fail_no_write", Fixture, NULL, set_up, test_pre_fail_no_write, tear_down);
	g_test_add("/boot_emmc_hooks/guard_hooks", Fixture, NULL, set_up, test_guard_hooks, tear_down);
	g_test_add("/boot_emmc_hooks/guard_no_approval", Fixture, NULL, set_up, test_guard_no_approval, tear_down);
	return g_test_run();
}
