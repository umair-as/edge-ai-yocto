# uefi-uki boot-chain family (ADR-0016): vendor firmware and UEFI, which
# this build neither produces nor writes, load one UKI per A/B slot. The UKI
# carries the kernel, the command line with the slot's dm-verity table, and
# the board DTB. Inherited by edge-ab-image when EDGE_BOOT_CHAIN is
# "uefi-uki".
#
# No stage verifies the UKI while UEFI Secure Boot is off, so dm-verity
# here detects rootfs corruption and does not authenticate the rootfs
# (EDGE_BOOT_ANCHOR = "none").
#
# oe-core's uki.bbclass is not used: it always adds an initramfs, and this
# family boots without one (dm-init builds the mapping, as on uboot-fit).

inherit image_types_verity
require conf/image-uefi.conf

inherit edge-verity-settings

# The image is installed partition by partition (ADR-0016 §4), not as a
# whole-disk wic. qcomflash is never built: it rewrites every firmware
# partition.
IMAGE_FSTYPES:remove = "wic.zst wic.bmap qcomflash"

# RAUC custom backend (ADR-0016 §6): systemd-boot on the ESP, slot state in
# the UKI file names; rauc-conf-edge pulls in the backend.
IMAGE_INSTALL:append = " systemd-boot"

# Board DTB embedded in each UKI, by its deploy name.
EDGE_UKI_DTB ?= ""
EDGE_UKI_A = "${IMAGE_LINK_NAME}.uki-A.efi"
EDGE_UKI_B = "${IMAGE_LINK_NAME}.uki-B.efi"

DEPENDS:append = " systemd-boot-native"
do_image_verity_uki[depends] += " \
    virtual/kernel:do_deploy \
    systemd-boot:do_deploy \
"
do_image_verity_uki[dirs] = "${WORKDIR}/verity-uki"
do_image_verity_uki[cleandirs] = "${WORKDIR}/verity-uki"

python do_image_verity_uki() {
    import os
    import re
    import shutil
    import subprocess

    image_deploy = d.getVar("IMGDEPLOYDIR")
    deploy = d.getVar("DEPLOY_DIR_IMAGE")
    work = os.path.join(d.getVar("WORKDIR"), "verity-uki")
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

    efi_arch = d.getVar("EFI_ARCH")
    stub = os.path.join(deploy, "linux%s.efi.stub" % efi_arch)
    kernel = os.path.join(deploy, d.getVar("KERNEL_IMAGETYPE"))
    dtb_name = (d.getVar("EDGE_UKI_DTB") or "").strip()
    if not dtb_name:
        bb.fatal("EDGE_UKI_DTB is unset for MACHINE = '%s'. Set it in "
                 "conf/machine/include/edge-board-%s.inc to the board DTB's "
                 "deploy name." % (d.getVar("MACHINE"), d.getVar("MACHINE")))
    dtb = os.path.join(deploy, dtb_name)
    osrel = os.path.join(d.getVar("IMAGE_ROOTFS"), "usr/lib/os-release")
    for path in (stub, kernel, dtb, osrel):
        if not os.path.isfile(path):
            bb.fatal("UKI input not found: %s" % path)

    # systemd-boot orders entries by sort key (ID), version, then file name.
    # A constant IMAGE_VERSION, the version field systemd-boot reads first,
    # leaves the generation in the file name as the only order, so activating
    # an older release works. IMAGE_ID would become the sort key.
    with open(osrel, encoding="utf-8") as stream:
        text = stream.read()
    for key in ("IMAGE_ID", "IMAGE_VERSION"):
        if re.search(r"^%s=" % key, text, re.MULTILINE):
            bb.fatal("%s sets %s; the custom backend's slot order needs it unset" % (osrel, key))
    osrel = os.path.join(work, "os-release")
    with open(osrel, "w", encoding="utf-8") as stream:
        stream.write(text.rstrip("\n") + "\nIMAGE_VERSION=0\n")

    for slot, device, output_name in (
            ("A", d.getVar("EDGE_SLOT_A_DEVICE"), d.getVar("EDGE_UKI_A")),
            ("B", d.getVar("EDGE_SLOT_B_DEVICE"), d.getVar("EDGE_UKI_B"))):
        if not device:
            bb.fatal(
                "EDGE_SLOT_%s_DEVICE is unset for MACHINE = '%s'.\n"
                "  The slot block device is written into the UKI's dm-verity\n"
                "  table, so an empty or wrong value yields an image that\n"
                "  cannot mount its own root. Set it in\n"
                "  conf/machine/include/edge-board-%s.inc."
                % (slot, d.getVar("MACHINE"), d.getVar("MACHINE")))
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
        # dm-init otherwise races the eMMC partition scan and fails with
        # ENODEV; rootwait then waits for a dm-0 that is never created.
        cmdline = (
            'root=/dev/dm-0 rootfstype=ext4 ro rootwait rauc.slot=%s '
            'dm-mod.waitfor=%s dm-mod.create="%s" %s' %
            (slot, device, table, d.getVar("EDGE_VERITY_KERNEL_ARGS")))
        uki = os.path.join(work, "uki-%s.efi" % slot)
        subprocess.run([
            "ukify", "build",
            "--efi-arch", efi_arch,
            "--stub", stub,
            "--linux", kernel,
            "--devicetree", dtb,
            "--cmdline", cmdline,
            "--os-release", "@" + osrel,
            "--output", uki], check=True)
        shutil.copyfile(uki, os.path.join(image_deploy, output_name))
}

addtask image_verity_uki after do_image_verity before do_image_complete

# Install payload (ADR-0016 §4): one VFAT image per slot, a small ext4 /data
# that edge-grow-data grows on first boot, and a layout manifest numbering
# efiA, efiB, rootfsA, rootfsB and data from EDGE_INSTALL_FIRST_PARTITION.
# The GPT and the ESP are assembled on the host from the unit's own GPT and
# ESP plus the files the manifest lists under esp_files: systemd-boot is the
# ESP's loader and both slot UKIs live on the ESP, so the slot VFATs stay
# empty and no firmware boot entry can reach a UKI there. The board include sets
# EDGE_INSTALL_FIRST_PARTITION, EDGE_UKI_SLOT_SIZE_MB and
# EDGE_DATA_IMAGE_SIZE_MB.
EDGE_INSTALL_LAYOUT = "${IMAGE_LINK_NAME}.install-layout.json"

# systemd-boot: the first sorted edge-* entry, no menu,
# no auto-detected entries (the ESP's other EFI binaries).
EDGE_SDBOOT_LOADER_CONF = "default edge-*\ntimeout 0\neditor no\nauto-entries no\n"

python () {
    machine = d.getVar("MACHINE")
    for var in ("EDGE_INSTALL_FIRST_PARTITION", "EDGE_UKI_SLOT_SIZE_MB",
                "EDGE_DATA_IMAGE_SIZE_MB"):
        if not (d.getVar(var) or "").strip().isdigit():
            bb.fatal("%s is unset or not a number for MACHINE = '%s'. Set it in "
                     "conf/machine/include/edge-board-%s.inc." % (var, machine, machine))
    first = int(d.getVar("EDGE_INSTALL_FIRST_PARTITION"))
    for var, offset in (("EDGE_SLOT_A_DEVICE", 2), ("EDGE_SLOT_B_DEVICE", 3),
                        ("EDGE_DATA_DEVICE", 4)):
        device = d.getVar(var) or ""
        number = device[len(device.rstrip("0123456789")):]
        if number != str(first + offset):
            bb.fatal("%s = '%s' does not match the install layout: partition %d "
                     "(EDGE_INSTALL_FIRST_PARTITION %d + %d)."
                     % (var, device, first + offset, first, offset))
}

do_image_install_payload[depends] += " \
    dosfstools-native:do_populate_sysroot \
    mtools-native:do_populate_sysroot \
    e2fsprogs-native:do_populate_sysroot \
"
do_image_install_payload[dirs] = "${WORKDIR}/install-payload"
do_image_install_payload[cleandirs] = "${WORKDIR}/install-payload"

python do_image_install_payload() {
    import json
    import os
    import shutil
    import subprocess

    image_deploy = d.getVar("IMGDEPLOYDIR")
    work = os.path.join(d.getVar("WORKDIR"), "install-payload")
    link_name = d.getVar("IMAGE_LINK_NAME")
    vfat_mb = int(d.getVar("EDGE_UKI_SLOT_SIZE_MB"))
    data_mb = int(d.getVar("EDGE_DATA_IMAGE_SIZE_MB"))
    slot_mb = int(d.getVar("EDGE_SLOT_SIZE_MB"))

    def run(*cmd):
        subprocess.run(list(cmd), check=True)

    entries = []
    for slot, uki_name in (("A", d.getVar("EDGE_UKI_A")), ("B", d.getVar("EDGE_UKI_B"))):
        uki = os.path.join(image_deploy, uki_name)
        if os.path.getsize(uki) > (vfat_mb - 4) * 1024 * 1024:
            bb.fatal("%s does not fit EDGE_UKI_SLOT_SIZE_MB = %d" % (uki, vfat_mb))
        img = os.path.join(work, "efi%s.vfat" % slot)
        run("dd", "if=/dev/zero", "of=%s" % img, "bs=1M", "count=0", "seek=%d" % vfat_mb)
        run("mkfs.vfat", "-F", "32", "-n", "EFI%s" % slot, img)
        out = "%s.efi%s.vfat" % (link_name, slot)
        shutil.copyfile(img, os.path.join(image_deploy, out))
        entries.append({"name": "efi%s" % slot, "size_mib": vfat_mb,
                        "type": "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "image": out})

    for slot in ("A", "B"):
        entries.append({"name": "rootfs%s" % slot, "size_mib": slot_mb,
                        "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4",
                        "image": "%s.ext4.verity" % link_name})

    data = os.path.join(work, "data.ext4")
    run("dd", "if=/dev/zero", "of=%s" % data, "bs=1M", "count=0", "seek=%d" % data_mb)
    run("mkfs.ext4", "-F", "-q", "-L", "data", data)
    data_out = "%s.data.ext4" % link_name
    shutil.copyfile(data, os.path.join(image_deploy, data_out))
    entries.append({"name": "data", "size_mib": None,
                    "type": "00FB7005-AB51-4206-9D4A-11B68E508D3A", "image": data_out})

    uki_a, uki_b = d.getVar("EDGE_UKI_A"), d.getVar("EDGE_UKI_B")
    # The loader comes from the image's own systemd-boot package, so the
    # ESP's loader and the rootfs copy are one build.
    loader = os.path.join(d.getVar("IMAGE_ROOTFS"), "usr/lib/systemd/boot/efi",
                          "systemd-boot%s.efi" % d.getVar("EFI_ARCH"))
    if not os.path.isfile(loader):
        bb.fatal("systemd-boot not in the image rootfs: %s" % loader)
    loader_out = "%s.systemd-boot%s.efi" % (link_name, d.getVar("EFI_ARCH"))
    shutil.copyfile(loader, os.path.join(image_deploy, loader_out))
    conf_out = "%s.loader.conf" % link_name
    with open(os.path.join(image_deploy, conf_out), "w") as stream:
        stream.write(d.getVar("EDGE_SDBOOT_LOADER_CONF").replace("\\n", "\n"))
    # Initial slot state: A primary (higher generation), both confirmed.
    esp_files = [{"path": "EFI/BOOT/BOOTAA64.EFI", "image": loader_out},
                 {"path": "EFI/ubuntu/shimaa64.efi", "image": loader_out},
                 {"path": "loader/loader.conf", "image": conf_out},
                 {"path": "EFI/Linux/edge-2-a.efi", "image": uki_a},
                 {"path": "EFI/Linux/edge-1-b.efi", "image": uki_b}]

    layout = {"machine": d.getVar("MACHINE"),
              "first_partition": int(d.getVar("EDGE_INSTALL_FIRST_PARTITION")),
              "rauc_backend": "custom", "esp_files": esp_files, "partitions": entries}
    with open(os.path.join(image_deploy, d.getVar("EDGE_INSTALL_LAYOUT")), "w") as stream:
        json.dump(layout, stream, indent=2)
        stream.write("\n")
}

addtask image_install_payload after do_image_verity_uki before do_image_complete
