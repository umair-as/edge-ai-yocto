// SPDX-License-Identifier: MIT
/*
 * LD_PRELOAD stand-in for an eMMC under RAUC's boot-emmc handler: the EXT_CSD
 * ioctls, BLKGETSIZE64 on the regular files that stand in for boot0/boot1, and
 * the /sys/block/<dev>/force_ro files. Everything else goes to libc.
 *
 *   SHIM_EXTCSD  file holding PARTITION_CONFIG as text ("0x08"); MMC_SWITCH
 *                writes rewrite it
 *   SHIM_SYSFS   directory the /sys/block/ prefix is redirected to
 *   SHIM_LOG     append-only event log (ext_csd reads/writes, force_ro writes),
 *                shared with the test's hook script to check the ordering
 *   SHIM_DEVSIZE size of the boot0/boot1 stand-ins; writes past it fail with
 *                ENOSPC like a block device's end (RAUC's clear_slot() zeroes
 *                until ENOSPC; a regular file would grow without bound)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <linux/fs.h>
#include <linux/mmc/ioctl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MMC_SWITCH 6
#define MMC_SEND_EXT_CSD 8
#define EXT_CSD_BOOT_BUS_CONDITIONS 177
#define EXT_CSD_PART_CONFIG 179

static void shim_log(const char *fmt, ...)
{
	const char *p = getenv("SHIM_LOG");
	FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
	FILE *f;
	va_list ap;

	if (!p || !(f = real_fopen(p, "a")))
		return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static unsigned read_partcfg(void)
{
	FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
	const char *p = getenv("SHIM_EXTCSD");
	unsigned v = 0;
	FILE *f = p ? real_fopen(p, "r") : NULL;

	if (f) {
		if (fscanf(f, "%x", &v) != 1)
			v = 0;
		fclose(f);
	}
	return v;
}

static void write_partcfg(unsigned v)
{
	FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
	const char *p = getenv("SHIM_EXTCSD");
	FILE *f = p ? real_fopen(p, "w") : NULL;

	if (f) {
		fprintf(f, "0x%02x\n", v);
		fclose(f);
	}
}

int ioctl(int fd, unsigned long req, ...)
{
	int (*real_ioctl)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
	va_list ap;
	void *arg;
	struct stat st;

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (req == MMC_IOC_CMD) {
		struct mmc_ioc_cmd *cmd = arg;

		if (cmd->opcode == MMC_SEND_EXT_CSD && !cmd->write_flag) {
			uint8_t *buf = (uint8_t *)(uintptr_t)cmd->data_ptr;

			memset(buf, 0, 512);
			buf[EXT_CSD_PART_CONFIG] = (uint8_t)read_partcfg();
			buf[EXT_CSD_BOOT_BUS_CONDITIONS] = 0x02;
			shim_log("extcsd-read 0x%02x", buf[EXT_CSD_PART_CONFIG]);
			return 0;
		}
		if (cmd->opcode == MMC_SWITCH && cmd->write_flag) {
			unsigned index = (cmd->arg >> 16) & 0xff, value = (cmd->arg >> 8) & 0xff;

			if (index == EXT_CSD_PART_CONFIG)
				write_partcfg(value);
			shim_log("extcsd-write index=%u value=0x%02x", index, value);
			return 0;
		}
		errno = EINVAL;
		return -1;
	}
	if (req == BLKGETSIZE64 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
		*(uint64_t *)arg = (uint64_t)st.st_size;
		return 0;
	}
	return real_ioctl(fd, req, arg);
}

static const char *redirect(const char *path, char *buf, size_t len)
{
	const char *root = getenv("SHIM_SYSFS");

	if (root && strncmp(path, "/sys/block/", 11) == 0) {
		snprintf(buf, len, "%s/%s", root, path + 11);
		return buf;
	}
	return path;
}

FILE *fopen(const char *path, const char *mode)
{
	FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
	char buf[4096];
	const char *p = redirect(path, buf, sizeof(buf));

	if (p != path && strchr(mode, 'w'))
		shim_log("force_ro-open %s", path);
	return real_fopen(p, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
	return fopen(path, mode);
}

/* Writes to a file whose name ends in boot0/boot1 stop at SHIM_DEVSIZE. */
ssize_t write(int fd, const void *buf, size_t count)
{
	ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
	const char *lim = getenv("SHIM_DEVSIZE");
	char link[64], path[4096];
	ssize_t n;
	off_t pos, max;

	if (lim) {
		snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
		n = readlink(link, path, sizeof(path) - 1);
		if (n > 5) {
			path[n] = '\0';
			if (strcmp(path + n - 5, "boot0") == 0 || strcmp(path + n - 5, "boot1") == 0) {
				max = (off_t)strtoll(lim, NULL, 0);
				pos = lseek(fd, 0, SEEK_CUR);
				if (pos >= max) {
					errno = ENOSPC;
					return -1;
				}
				if (pos + (off_t)count > max)
					count = (size_t)(max - pos);
			}
		}
	}
	return real_write(fd, buf, count);
}
