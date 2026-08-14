# Runtime rootfs integrity for A/B images.

inherit image_types_verity kernel-arch uboot-config
require conf/image-fitimage.conf

IMAGE_FSTYPES:append = " verity"
IMAGE_FEATURES:append = " read-only-rootfs"

# Stable per-image salt preserves reproducibility while avoiding the shared
# class default. The root hash still changes whenever rootfs content changes.
VERITY_SALT = "${@__import__('hashlib').sha256(('%s:%s:%s' % (d.getVar('PN'), d.getVar('MACHINE'), d.getVar('DISTRO'))).encode()).hexdigest()}"

EDGE_VERITY_FIT_A = "${IMAGE_LINK_NAME}.fitImage-A"
EDGE_VERITY_FIT_B = "${IMAGE_LINK_NAME}.fitImage-B"
EDGE_VERITY_DTB   = "${EDGE_BOOT_DTB}"

# These arguments become part of the signed DTB. Mutable environment
# arguments are deliberately absent from the authenticated-root boot path.
EDGE_VERITY_KERNEL_ARGS ?= "earlycon security=selinux hash_pointers=always hardened_usercopy=1 kfence.sample_interval=100 proc_mem.force_override=never init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none"

do_image_verity_fit[depends] += " \
    virtual/kernel:do_deploy \
    u-boot-tools-native:do_populate_sysroot \
    dtc-native:do_populate_sysroot \
    ${@'kernel-signing-keys-native:do_compile' if d.getVar('FIT_GENERATE_KEYS') == '1' else ''} \
"
do_image_verity_fit[dirs] = "${WORKDIR}/verity-fit"

python do_image_verity_fit() {
    import os
    import re
    import shutil
    import subprocess

    image_deploy = d.getVar("IMGDEPLOYDIR")
    deploy = d.getVar("DEPLOY_DIR_IMAGE")
    work = os.path.join(d.getVar("WORKDIR"), "verity-fit")
    link_name = d.getVar("IMAGE_LINK_NAME")
    params_path = os.path.join(image_deploy, link_name + ".ext4.verity-params")
    verity_path = os.path.join(image_deploy, link_name + ".ext4.verity")

    required = {
        "VERITY_DATA_BLOCKS", "VERITY_DATA_BLOCK_SIZE",
        "VERITY_HASH_BLOCK_SIZE", "VERITY_HASH_ALGORITHM",
        "VERITY_ROOT_HASH", "VERITY_SALT", "VERITY_DATA_SECTORS",
    }
    params = {}
    with open(params_path, encoding="ascii") as stream:
        for raw in stream:
            raw = raw.strip()
            if not raw:
                continue
            if not re.fullmatch(r"[A-Z0-9_]+=[A-Za-z0-9_-]*", raw):
                bb.fatal("Unsafe dm-verity parameter in %s: %s" % (params_path, raw))
            key, value = raw.split("=", 1)
            params[key] = value
    missing = sorted(key for key in required if not params.get(key))
    if missing:
        bb.fatal("Missing dm-verity parameters in %s: %s" %
                 (params_path, ", ".join(missing)))

    slot_limit = int(d.getVar("EDGE_SLOT_SIZE_MB")) * 1024 * 1024
    verity_size = os.path.getsize(os.path.realpath(verity_path))
    if verity_size > slot_limit:
        bb.fatal("%s is %d bytes; EDGE_SLOT_SIZE_MB permits %d bytes" %
                 (verity_path, verity_size, slot_limit))

    kernel = os.path.join(deploy, "linux.bin")
    dtb = os.path.join(deploy, d.getVar("EDGE_VERITY_DTB"))
    with open(os.path.join(deploy, "linux_comp"), encoding="ascii") as stream:
        compression = stream.read().strip()
    for path in (kernel, dtb):
        if not os.path.isfile(path):
            bb.fatal("Signed verity FIT input not found: %s" % path)

    keydir = d.getVar("UBOOT_SIGN_KEYDIR")
    keyname = d.getVar("UBOOT_SIGN_KEYNAME")
    for suffix in (".key", ".crt"):
        key = os.path.join(keydir, keyname + suffix)
        if not os.path.isfile(key):
            bb.fatal("FIT signing key not found: %s" % key)

    def dts_quote(value):
        return value.replace("\\", "\\\\").replace('"', '\\"')

    for slot, part, output_name in (
            ("A", "2", d.getVar("EDGE_VERITY_FIT_A")),
            ("B", "3", d.getVar("EDGE_VERITY_FIT_B"))):
        slot_dtb = os.path.join(work, "verity-%s.dtb" % slot)
        shutil.copyfile(dtb, slot_dtb)
        device = "/dev/mmcblk0p%s" % part
        table = (
            "vroot,,,ro,0 {sectors} verity 1 {dev} {dev} "
            "{data_bs} {hash_bs} {data_blocks} {data_blocks} "
            "{algorithm} {root_hash} {salt} 1 restart_on_corruption"
        ).format(
            sectors=params["VERITY_DATA_SECTORS"], dev=device,
            data_bs=params["VERITY_DATA_BLOCK_SIZE"],
            hash_bs=params["VERITY_HASH_BLOCK_SIZE"],
            data_blocks=params["VERITY_DATA_BLOCKS"],
            algorithm=params["VERITY_HASH_ALGORITHM"],
            root_hash=params["VERITY_ROOT_HASH"], salt=params["VERITY_SALT"])
        bootargs = (
            'root=/dev/dm-0 rootfstype=ext4 ro rootwait rauc.slot=%s '
            'dm-mod.create="%s" %s' %
            (slot, table, d.getVar("EDGE_VERITY_KERNEL_ARGS")))
        subprocess.run(["fdtput", "-p", "-t", "s", slot_dtb,
                        "/chosen", "bootargs", bootargs], check=True)

        its = os.path.join(work, "verity-%s.its" % slot)
        fit = os.path.join(work, "fitImage-%s" % slot)
        its_text = '''/dts-v1/;

/ {
    description = "EDGE AI OS dm-verity slot %(slot)s";
    #address-cells = <1>;
    images {
        kernel-1 {
            description = "Linux kernel";
            data = /incbin/("%(kernel)s");
            type = "kernel";
            arch = "%(arch)s";
            os = "linux";
            compression = "%(compression)s";
            load = <%(load)s>;
            entry = <%(entry)s>;
            hash-1 { algo = "%(hash)s"; };
        };
        fdt-1 {
            description = "Signed slot %(slot)s DTB and dm-verity policy";
            data = /incbin/("%(dtb)s");
            type = "flat_dt";
            arch = "%(arch)s";
            compression = "none";
            hash-1 { algo = "%(hash)s"; };
        };
    };
    configurations {
        default = "conf-%(slot)s";
        conf-%(slot)s {
            /* U-Boot's fit_find_config_node() returns -EINVAL for any
               config without a description, breaking default-config
               selection (bootm without an explicit #conf suffix). */
            description = "EDGE AI OS verity slot %(slot)s";
            kernel = "kernel-1";
            fdt = "fdt-1";
            signature-1 {
                algo = "%(hash)s,%(sign)s";
                key-name-hint = "%(keyname)s";
                sign-images = "kernel", "fdt";
            };
        };
    };
};
''' % {
            "slot": slot, "kernel": dts_quote(kernel),
            "dtb": dts_quote(slot_dtb), "arch": d.getVar("UBOOT_ARCH"),
            "compression": compression, "load": d.getVar("EDGE_FIT_LOADADDRESS"),
            "entry": d.getVar("EDGE_FIT_ENTRYPOINT"),
            "hash": d.getVar("FIT_HASH_ALG"), "sign": d.getVar("FIT_SIGN_ALG"),
            "keyname": keyname,
        }
        with open(its, "w", encoding="ascii") as stream:
            stream.write(its_text)
        subprocess.run([d.getVar("UBOOT_MKIMAGE"), "-f", its, "-k", keydir,
                        "-r", fit], check=True)
        shutil.copyfile(fit, os.path.join(image_deploy, output_name))
}

addtask image_verity_fit after do_image_verity before do_image_wic do_image_complete

do_image_verity_fit[cleandirs] = "${WORKDIR}/verity-fit"
do_image_verity_fit[file-checksums] += "${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.key:True ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt:True"
