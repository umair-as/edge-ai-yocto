#!/usr/bin/env python3
"""Build, flash and verify EDL install sets for the Arduino VENTUNO Q (ADR-0016 §4).

An install set is derived from one image build and the unit's own GPT and ESP.
It lives in <build-dir>/install/<IMAGE_NAME>/, is never reused across builds,
and carries a MANIFEST.json with every file's sha256 and the verity root hash
the board must boot. The set writes only:

  - the GPT (protective MBR + primary header/array, and the backup at the end);
  - p69, the unit's ESP with the files the build lists in its install layout
    (esp_files): the boot loader at the removable-media path and at the factory
    Boot0000 path, plus systemd-boot's configuration and slot UKIs for the custom
    RAUC backend (firmware-maintained files kept);
  - p71-p75: efiA, efiB, rootfsA, rootfsB, data.

GPT entries 1-70 are copied byte for byte from the unit's GPT, and any write
overlapping p1-p68 or p70, or outside physical partition 0, is refused.

Subcommands:
  import-unit  copy the unit's GPT and ESP dumps into the unit directory, once
  prep         build the install set for the current deploy
  flash        prep (or reuse the verified set of the current build) and run qdl;
               --only esp writes p69 alone, which resets the firmware variable store
               to the set's VolatileVars.bin and leaves p71-p75 untouched; valid only
               while both rootfs slots still hold the set's rootfs
               --only recover writes p69, rootfsA and rootfsB: each slot's UKI and
               rootfs match again after an OTA, /data and efiA/efiB untouched;
               custom-backend sets only (an efi set keeps its UKIs on efiA/efiB)
  verify-boot  check that a console log shows the set's verity root booting
  status       print the configuration, the unit inputs and the current set

Host settings come from flags or ${XDG_CONFIG_HOME:-~/.config}/edge-ai/ventunoq.conf
(KEY=value lines): QDL, FIREHOSE, SERIAL, UNIT_DIR, BUILD_DIR.

  ventunoq-flash.py import-unit --gpt <gpt-primary.bin> --esp <p69 dump> --esp-source pristine
  ventunoq-flash.py flash --image edge-image-dev
  ventunoq-flash.py verify-boot --log <console log>
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import uuid
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MACHINE = "ventuno-q"
SECTOR = 512
ENTRY_SIZE = 128
NEW_ENTRIES = 128
ARRAY_SECTORS = NEW_ENTRIES * ENTRY_SIZE // SECTOR      # 32
ALIGN = 256                                               # 128 KiB, factory alignment
KEEP = 70                                                 # entries copied verbatim
ESP_INDEX = 69
# Partial writes: labels each --only mode takes from the set's program list.
ONLY_LABELS = {"esp": {"efi"}, "recover": {"efi", "rootfsA", "rootfsB"}}
# ESP directories the install set owns: emptied before the build's esp_files go in.
ESP_REPLACED_DIRS = ("EFI/BOOT", "EFI/ubuntu", "EFI/Linux", "EFI/systemd")
SYSTEM_INDEX = 71
EDL_VID, EDL_PID = "05c6", "9008"
ALLOWED_LABELS = {"PrimaryGPT", "BackupGPT", "efi", "efiA", "efiB", "rootfsA", "rootfsB", "data"}
# qdl and the EDL device need a moment after enumeration before the Sahara
# handshake; a run straight after a reset failed with "failed to read sahara request".
EDL_SETTLE_S = 3


def die(msg):
    sys.exit("ventunoq-flash: " + msg)


def log(msg):
    print("ventunoq-flash: " + msg, flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- configuration ----------------------------------------------------------

def load_conf():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    path = os.path.join(base, "edge-ai", "ventunoq.conf")
    conf = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = os.path.expanduser(v.strip())
    return conf, path


def settings(args):
    conf, conf_path = load_conf()

    def pick(flag, key, default=None):
        v = getattr(args, flag, None) or conf.get(key) or default
        return os.path.abspath(v) if v and key not in ("SERIAL",) else v

    s = {"conf_path": conf_path,
         "build_dir": pick("build_dir", "BUILD_DIR", os.path.join(ROOT, "build", MACHINE)),
         "qdl": pick("qdl", "QDL", shutil.which("qdl")),
         "firehose": pick("firehose", "FIREHOSE"),
         "serial": pick("serial", "SERIAL")}
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    s["unit_dir"] = pick("unit_dir", "UNIT_DIR",
                         os.path.join(data, "edge-ai", "ventunoq", s["serial"] or "unit"))
    s["deploy"] = os.path.join(s["build_dir"], "tmp", "deploy", "images", MACHINE)
    s["install"] = os.path.join(s["build_dir"], "install")
    return s


# --- ESP variable store -----------------------------------------------------

BOOT_VARIABLE_RX = re.compile(r"BootOrder|BootNext|Boot[0-9A-Fa-f]{4}")


def esp_boot_variables(esp):
    """Boot variable names (UTF-16LE) found in an ESP image's VolatileVars.bin, sorted.

    Fails closed: an ESP that cannot be read, or that holds no VolatileVars.bin,
    is refused rather than reported as a store without boot variables.
    """
    ls = subprocess.run(["mdir", "-b", "-i", esp, "::/"], capture_output=True, text=True)
    if ls.returncode != 0:
        die("cannot read the imported ESP %s: %s" % (esp, ls.stderr.strip() or "mdir failed"))
    if "::/VolatileVars.bin" not in ls.stdout.split():
        die("the imported ESP %s has no VolatileVars.bin; the custom chain is validated with that "
            "store present and free of boot variables" % esp)
    r = subprocess.run(["mcopy", "-n", "-i", esp, "::/VolatileVars.bin", "-"], capture_output=True)
    if r.returncode != 0:
        die("cannot read VolatileVars.bin from %s: %s" % (esp, r.stderr.decode(errors="replace").strip()))
    found = set()
    for offset in (0, 1):
        data = r.stdout[offset:]
        text = data[:len(data) // 2 * 2].decode("utf-16-le", "replace")
        found.update(BOOT_VARIABLE_RX.findall(text))
    return sorted(found)


# --- GPT --------------------------------------------------------------------

def read_gpt(path):
    raw = open(path, "rb").read()
    if len(raw) < 2 * SECTOR:
        die("%s is too short to hold a GPT" % path)
    hdr = raw[SECTOR:2 * SECTOR]
    if hdr[:8] != b"EFI PART":
        die("%s: no GPT header at LBA 1" % path)
    (hdr_size, my_lba, alt_lba, first_usable, last_usable) = (
        struct.unpack_from("<I", hdr, 12)[0], *struct.unpack_from("<QQQQ", hdr, 24))
    disk_guid = hdr[56:72]
    entry_lba, n_entries, entry_size = struct.unpack_from("<QII", hdr, 72)
    if entry_size != ENTRY_SIZE or entry_lba != 2:
        die("unexpected GPT entry geometry in %s" % path)
    # The assembled GPT gets fresh CRCs, so a damaged dump must be refused here.
    if not 92 <= hdr_size <= SECTOR:
        die("%s: GPT header size %d is invalid" % (path, hdr_size))
    hdr_crc = struct.unpack_from("<I", hdr, 16)[0]
    if zlib.crc32(hdr[:16] + b"\0\0\0\0" + hdr[20:hdr_size]) & 0xffffffff != hdr_crc:
        die("%s: GPT header CRC mismatch; the dump is damaged" % path)
    start = entry_lba * SECTOR
    if len(raw) < start + n_entries * ENTRY_SIZE:
        die("%s ends before its %d-entry GPT array" % (path, n_entries))
    array = raw[start:start + n_entries * ENTRY_SIZE]
    if zlib.crc32(array) & 0xffffffff != struct.unpack_from("<I", hdr, 88)[0]:
        die("%s: GPT entry array CRC mismatch; the dump is damaged" % path)
    entries = [array[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE] for i in range(n_entries)]
    return {"mbr": raw[:SECTOR], "hdr_size": hdr_size, "alt_lba": alt_lba,
            "first_usable": first_usable, "last_usable": last_usable,
            "disk_guid": disk_guid, "entries": entries}


def entry_fields(e):
    first, last = struct.unpack_from("<QQ", e, 32)
    name = e[56:128].decode("utf-16-le").rstrip("\0")
    return name, first, last


def make_entry(type_guid, part_guid, first, last, name):
    e = bytearray(ENTRY_SIZE)
    e[0:16] = uuid.UUID(type_guid).bytes_le
    e[16:32] = part_guid.bytes_le
    struct.pack_into("<QQQ", e, 32, first, last, 0)
    enc = name.encode("utf-16-le")
    e[56:56 + len(enc)] = enc
    return bytes(e)


def header(my_lba, alt_lba, first_usable, last_usable, disk_guid, entry_lba, array_crc):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    struct.pack_into("<IIII", h, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", h, 24, my_lba, alt_lba, first_usable, last_usable)
    h[56:72] = disk_guid
    struct.pack_into("<QIII", h, 72, entry_lba, NEW_ENTRIES, ENTRY_SIZE, array_crc)
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
    return bytes(h) + bytes(SECTOR - 92)


# --- build inputs -----------------------------------------------------------

def uki_cmdline(path):
    """The UKI's .cmdline text: the NUL-terminated string holding dm-mod.create."""
    data = open(path, "rb").read()
    i = data.find(b'dm-mod.create="')
    if i < 0:
        die("%s carries no dm-mod.create command line" % path)
    start = data.rfind(b"\0", 0, i) + 1
    end = data.find(b"\0", i)
    return data[start:end].decode("ascii", "replace").strip()


def cmdline_facts(cmdline):
    m = re.search(r'dm-mod\.create="([^"]*)"', cmdline)
    table = m.group(1) if m else ""
    hashes = re.findall(r"\b[0-9a-f]{64}\b", table)
    w = re.search(r"(?:^| )dm-mod\.waitfor=(\S+)", cmdline)
    s = re.search(r"(?:^| )rauc\.slot=(\S+)", cmdline)
    return {"root_hash": hashes[0] if hashes else None,
            "waitfor": w.group(1) if w else None,
            "slot": s.group(1) if s else None}


def deploy_build(s, image):
    link = "%s-%s.rootfs" % (image, MACHINE)
    verity = os.path.join(s["deploy"], link + ".ext4.verity")
    if not os.path.islink(verity):
        die("%s is not a build link; build %s first (make dev BOARD=%s)" % (verity, image, MACHINE))
    target = os.readlink(verity)
    m = re.fullmatch(re.escape(link) + r"-(\d{14})\.ext4\.verity", os.path.basename(target))
    if not m:
        die("cannot read the build timestamp from %s" % target)
    params = {}
    for line in open(os.path.join(s["deploy"], link + ".ext4.verity-params")):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            params[k] = v
    return {"link": link, "image_name": "%s-%s" % (link, m.group(1)),
            "root_hash": params.get("VERITY_ROOT_HASH")}


def git_state():
    def run(*a):
        r = subprocess.run(["git", "-C", ROOT] + list(a), capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None
    dirty = run("status", "--porcelain", "--untracked-files=no")
    return {"commit": run("rev-parse", "HEAD"),
            "branch": run("rev-parse", "--abbrev-ref", "HEAD"),
            "dirty": dirty.splitlines() if dirty else []}


def unit_inputs(s):
    path = os.path.join(s["unit_dir"], "unit.json")
    if not os.path.exists(path):
        die("no unit inputs in %s; run import-unit first" % s["unit_dir"])
    unit = json.load(open(path))
    for key in ("gpt", "esp"):
        f = os.path.join(s["unit_dir"], unit[key]["file"])
        if sha256(f) != unit[key]["sha256"]:
            die("%s changed since import (sha256 mismatch)" % f)
        unit[key]["path"] = f
    return unit


# --- subcommands ------------------------------------------------------------

def cmd_import_unit(args, s):
    os.makedirs(s["unit_dir"], exist_ok=True)
    unit = {"imported": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "esp_source": args.esp_source, "note": args.note or ""}
    for key, src, name in (("gpt", args.gpt, "gpt-primary.bin"), ("esp", args.esp, "p69-efi.img")):
        src = os.path.abspath(src)
        dst = os.path.join(s["unit_dir"], name)
        shutil.copyfile(src, dst)
        unit[key] = {"file": name, "source": src, "sha256": sha256(dst)}
    gpt = read_gpt(os.path.join(s["unit_dir"], "gpt-primary.bin"))
    old = [entry_fields(e) for e in gpt["entries"]]
    if old[ESP_INDEX - 1][0] != "efi" or old[KEEP - 1][0] != "persist":
        die("unit GPT is not the factory layout (p69 efi, p70 persist)")
    _, f, l = old[ESP_INDEX - 1]
    if os.path.getsize(os.path.join(s["unit_dir"], "p69-efi.img")) != (l - f + 1) * SECTOR:
        die("ESP dump size does not match the unit's p69")
    json.dump(unit, open(os.path.join(s["unit_dir"], "unit.json"), "w"), indent=2)
    log("unit inputs in %s (esp_source=%s)" % (s["unit_dir"], args.esp_source))
    for key in ("gpt", "esp"):
        log("  %s %s  from %s" % (unit[key]["sha256"][:16], unit[key]["file"], unit[key]["source"]))


def prep(s, image, force=False):
    build = deploy_build(s, image)
    unit = unit_inputs(s)
    final = os.path.join(s["install"], build["image_name"])
    if os.path.exists(final):
        if not force:
            die("%s exists; flash reuses it after verification, prep --force rebuilds it" % final)
        shutil.rmtree(final)
    tmp = final + ".tmp-%d" % os.getpid()
    os.makedirs(tmp)
    try:
        programs, ukis, esp_manifest, backend = assemble(s, build, unit, tmp)
        manifest = {
            "image_name": build["image_name"], "image": image, "machine": MACHINE,
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "git": git_state(), "verity_root_hash": build["root_hash"], "ukis": ukis,
            "esp_files": esp_manifest, "rauc_backend": backend,
            "unit": {k: {"sha256": unit[k]["sha256"], "source": unit[k]["source"]} for k in ("gpt", "esp")},
            "esp_source": unit.get("esp_source"),
            "programs": [{"label": l, "start": st, "sectors": n, "file": f} for l, st, n, f in programs],
            "files": {f: sha256(os.path.join(tmp, f)) for f in sorted(os.listdir(tmp))},
        }
        json.dump(manifest, open(os.path.join(tmp, "MANIFEST.json"), "w"), indent=2)
        os.rename(tmp, final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    latest = os.path.join(s["install"], "latest-" + image)
    if os.path.islink(latest) or os.path.exists(latest):
        os.remove(latest)
    os.symlink(build["image_name"], latest)
    log("install set %s" % final)
    for p in manifest["programs"]:
        log("  %-10s start %10d  sectors %10d  %s" % (p["label"], p["start"], p["sectors"], p["file"]))
    return final, manifest


def assemble(s, build, unit, out):
    link = build["link"]
    layout = json.load(open(os.path.join(s["deploy"], link + ".install-layout.json")))
    if layout.get("first_partition") != SYSTEM_INDEX:
        die("layout first_partition %s does not match the factory system partition p%d"
            % (layout.get("first_partition"), SYSTEM_INDEX))

    # The UKIs must boot the root this set writes.
    ukis = {}
    for slot in ("A", "B"):
        path = os.path.join(s["deploy"], "%s.uki-%s.efi" % (link, slot))
        facts = cmdline_facts(uki_cmdline(path))
        if facts["root_hash"] != build["root_hash"]:
            die("uki-%s root hash %s does not match the build's %s"
                % (slot, facts["root_hash"], build["root_hash"]))
        ukis[slot] = dict(facts, sha256=sha256(path))

    gpt = read_gpt(unit["gpt"]["path"])
    disk_sectors = gpt["alt_lba"] + 1
    old = [entry_fields(e) for e in gpt["entries"]]
    if old[ESP_INDEX - 1][0] != "efi" or old[KEEP - 1][0] != "persist" \
            or old[SYSTEM_INDEX - 1][0] != "system":
        die("unit GPT is not the factory layout (p69 efi, p70 persist, p71 system)")
    region_start = old[SYSTEM_INDEX - 1][1]
    region_end = gpt["last_usable"]

    # Backup array keeps the factory geometry: 32 sectors before the backup header.
    last_usable = disk_sectors - 1 - ARRAY_SECTORS - 1
    if last_usable < region_end:
        die("a 128-entry backup array would overlap the last partition")
    if ARRAY_SECTORS + 2 > gpt["first_usable"]:
        die("a 128-entry primary array would overlap p1")

    entries = list(gpt["entries"][:KEEP])
    writes = []
    lba = region_start
    for part in layout["partitions"]:
        size = (last_usable + 1 - lba) if part["size_mib"] is None \
            else part["size_mib"] * 1024 * 1024 // SECTOR
        # The remainder partition is aligned too: systemd-repart 259 refuses a
        # GPT whose partition ends unaligned at the last usable LBA ("Can't fit
        # requested partitions"), and edge-grow-data grows it into the tail.
        size -= size % ALIGN
        first, last = lba, lba + size - 1
        if last > last_usable:
            die("layout does not fit the device at %s" % part["name"])
        part_guid = uuid.uuid5(uuid.UUID(bytes_le=gpt["disk_guid"]), part["name"])
        entries.append(make_entry(part["type"], part_guid, first, last, part["name"]))
        writes.append((part["name"], first, size, os.path.join(s["deploy"], part["image"])))
        lba = last + 1
    entries += [bytes(ENTRY_SIZE)] * (NEW_ENTRIES - len(entries))
    array = b"".join(entries)
    array_crc = zlib.crc32(array) & 0xffffffff

    primary = gpt["mbr"] + header(1, disk_sectors - 1, gpt["first_usable"], last_usable,
                                   gpt["disk_guid"], 2, array_crc) + array
    backup = array + header(disk_sectors - 1, 1, gpt["first_usable"], last_usable,
                            gpt["disk_guid"], disk_sectors - 1 - ARRAY_SECTORS, array_crc)
    open(os.path.join(out, "gpt_main0.bin"), "wb").write(primary)
    open(os.path.join(out, "gpt_backup0.bin"), "wb").write(backup)
    programs = [("PrimaryGPT", 0, len(primary) // SECTOR, "gpt_main0.bin"),
                ("BackupGPT", disk_sectors - 1 - ARRAY_SECTORS, len(backup) // SECTOR,
                 "gpt_backup0.bin")]

    # The unit's ESP keeps its firmware-maintained files. The build names every file
    # it places there (layout "esp_files"): the removable-media path, the factory
    # Boot0000 path and, for the custom RAUC backend, systemd-boot's files.
    esp_files = layout.get("esp_files")
    if not esp_files:
        die("layout has no esp_files; rebuild the image with this tree")
    esp = os.path.join(out, "efi.vfat")
    shutil.copyfile(unit["esp"]["path"], esp)
    # The custom chain boots through the removable-media path, which the firmware
    # takes only with no BootOrder; it is validated on a store without boot variables.
    if layout.get("rauc_backend") == "custom":
        names = esp_boot_variables(esp)
        if names:
            die("the imported ESP's VolatileVars.bin holds %s; a custom set needs a variable store "
                "without boot variables. Re-import the unit's pristine p69 dump "
                "(import-unit --esp <dump> --esp-source pristine)" % ", ".join(names))
    for d in ESP_REPLACED_DIRS:
        subprocess.run(["mdeltree", "-i", esp, "::/" + d], check=False, stderr=subprocess.DEVNULL)
    for item in esp_files:
        dest = item["path"]
        if not re.fullmatch(r"(EFI|loader)(/[A-Za-z0-9._+-]+)+", dest) or ".." in dest.split("/"):
            die("esp_files path %r is not a plain ESP path" % dest)
        parent = ""
        for part in dest.split("/")[:-1]:
            parent += "/" + part
            subprocess.run(["mmd", "-i", esp, "::" + parent], check=False, stderr=subprocess.DEVNULL)
        subprocess.run(["mcopy", "-o", "-i", esp, os.path.join(s["deploy"], item["image"]),
                        "::/" + dest], check=True)
    esp_manifest = {item["path"]: sha256(os.path.join(s["deploy"], item["image"]))
                    for item in esp_files}
    _, esp_first, esp_last = old[ESP_INDEX - 1]
    if os.path.getsize(esp) != (esp_last - esp_first + 1) * SECTOR:
        die("ESP dump size does not match p69")
    programs.append(("efi", esp_first, esp_last - esp_first + 1, "efi.vfat"))

    # Timestamped build outputs are hardlinked; fixed-name ones are copied, since
    # the next build rewrites them under the same name.
    for name, first, size, src in writes:
        real = os.path.realpath(src)
        fsize = os.path.getsize(real)
        if fsize > size * SECTOR:
            die("%s (%d bytes) exceeds partition %s" % (src, fsize, name))
        dst = os.path.join(out, os.path.basename(real))
        if not os.path.exists(dst):
            if os.path.basename(real) != os.path.basename(src):
                try:
                    os.link(real, dst)
                except OSError:
                    shutil.copyfile(real, dst)
            else:
                shutil.copyfile(real, dst)
        programs.append((name, first, (fsize + SECTOR - 1) // SECTOR, os.path.basename(real)))

    protected = [(i + 1, f, l) for i, (_, f, l) in enumerate(old[:KEEP]) if i + 1 != ESP_INDEX]
    for label, start, count, _ in programs:
        if label in ("PrimaryGPT", "BackupGPT"):
            continue
        for idx, f, l in protected:
            if start <= l and start + count - 1 >= f:
                die("write %s overlaps p%d" % (label, idx))

    with open(os.path.join(out, "rawprogram0.xml"), "w") as x:
        x.write('<?xml version="1.0" ?>\n<data>\n')
        for label, start, count, fname in programs:
            x.write('  <program SECTOR_SIZE_IN_BYTES="512" file_sector_offset="0" '
                    'filename="%s" label="%s" num_partition_sectors="%d" '
                    'partofsingleimage="false" physical_partition_number="0" '
                    'readbackverify="false" size_in_KB="%.1f" sparse="false" '
                    'start_byte_hex="0x%x" start_sector="%d"/>\n'
                    % (fname, label, count, count / 2.0, start * SECTOR, start))
        x.write("</data>\n")
    with open(os.path.join(out, "patch0.xml"), "w") as x:
        x.write('<?xml version="1.0" ?>\n<patches>\n</patches>\n')
    return programs, ukis, esp_manifest, layout.get("rauc_backend")


def set_backend(manifest):
    """RAUC backend a set was built for. Sets prepared before MANIFEST recorded it count as custom
    only when their ESP files include slot entries under EFI/Linux."""
    if "rauc_backend" in manifest:
        return manifest["rauc_backend"]
    if any(p.startswith("EFI/Linux/") for p in manifest.get("esp_files") or {}):
        return "custom"
    return None


def verify_set(set_dir):
    path = os.path.join(set_dir, "MANIFEST.json")
    if not os.path.exists(path):
        die("%s has no MANIFEST.json; not an install set" % set_dir)
    manifest = json.load(open(path))
    present = sorted(f for f in os.listdir(set_dir) if f != "MANIFEST.json" and not f.startswith("flash-"))
    if present != sorted(manifest["files"]):
        die("%s: files differ from the manifest" % set_dir)
    for f, digest in manifest["files"].items():
        if sha256(os.path.join(set_dir, f)) != digest:
            die("%s: %s changed since prep (sha256 mismatch)" % (set_dir, f))
    xml = open(os.path.join(set_dir, "rawprogram0.xml")).read()
    phys = set(re.findall(r'physical_partition_number="(\d+)"', xml))
    labels = set(re.findall(r'label="([^"]+)"', xml))
    if phys != {"0"}:
        die("rawprogram0.xml addresses physical partitions %s; only 0 is allowed" % sorted(phys))
    if not labels <= ALLOWED_LABELS:
        die("rawprogram0.xml writes unexpected labels %s" % sorted(labels - ALLOWED_LABELS))
    if "<patch " in open(os.path.join(set_dir, "patch0.xml")).read():
        die("patch0.xml is not empty")
    return manifest


def edl_present(serial):
    root = os.environ.get("VENTUNOQ_SYSFS_USB", "/sys/bus/usb/devices")
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        def attr(n):
            try:
                return open(os.path.join(root, d, n)).read().strip()
            except OSError:
                return ""
        if attr("idVendor") == EDL_VID and attr("idProduct") == EDL_PID:
            if serial and serial not in attr("serial") and serial not in attr("product"):
                continue
            return d
    return None


def cmd_prep(args, s):
    prep(s, args.image, force=args.force)


def cmd_flash(args, s):
    for key in ("qdl", "firehose", "serial"):
        if not s[key]:
            die("%s is not set (flag --%s or %s in %s)" % (key, key, key.upper(), s["conf_path"]))
    for key in ("qdl", "firehose"):
        if not os.path.isfile(s[key]):
            die("%s %s does not exist" % (key, s[key]))
    # A retained set named with --allow-other-build is checked against its own
    # manifest only, so it still flashes after the build outputs are gone.
    current = None if args.set and args.allow_other_build else deploy_build(s, args.image)
    if args.set:
        set_dir = os.path.abspath(args.set)
    else:
        set_dir = os.path.join(s["install"], current["image_name"])
        if not os.path.exists(set_dir):
            set_dir, _ = prep(s, args.image)
    manifest = verify_set(set_dir)
    if current and manifest["image_name"] != current["image_name"]:
        die("set %s is for %s, but the current %s build is %s (--allow-other-build to flash it)"
            % (set_dir, manifest["image_name"], args.image, current["image_name"]))
    log("set verified: %s" % set_dir)
    # recover pairs each rootfs with the slot UKI on the ESP, where only the custom
    # backend keeps it; an efi set boots the UKIs on efiA/efiB, which recover leaves alone.
    if args.only == "recover" and set_backend(manifest) != "custom":
        die("--only recover needs a custom-backend set; %s has rauc_backend %r (efi sets keep the slot "
            "UKIs on efiA/efiB): use a full flash" % (set_dir, set_backend(manifest)))

    dev = edl_present(s["serial"])
    if not dev:
        log("waiting up to %ds for EDL device %s:%s serial %s" % (args.wait, EDL_VID, EDL_PID, s["serial"]))
        deadline = time.monotonic() + args.wait
        while not dev and time.monotonic() < deadline:
            time.sleep(1)
            dev = edl_present(s["serial"])
    if not dev:
        die("no EDL device %s:%s with serial %s (JCTL 1-2 jumper fitted, board powered?)"
            % (EDL_VID, EDL_PID, s["serial"]))
    time.sleep(EDL_SETTLE_S)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = os.path.join(set_dir, "flash-%s.log" % stamp)
    rawprogram = os.path.join(set_dir, "rawprogram0.xml")
    wanted = {p["label"] for p in manifest["programs"]}
    if args.only:
        # Sectors come from the verified set, not recomputed. The filtered program
        # list is kept in the set beside the log; verify_set ignores flash-*.
        wanted = ONLY_LABELS[args.only]
        lines = open(rawprogram).read().splitlines(keepends=True)
        keep = [l for l in lines if "<program " in l
                and re.search(r'label="([^"]+)"', l).group(1) in wanted]
        if len(keep) != len(wanted):
            die("%s holds %d of the %d programs for --only %s" % (rawprogram, len(keep), len(wanted), args.only))
        rawprogram = os.path.join(set_dir, "flash-%s-%s-rawprogram0.xml" % (stamp, args.only))
        with open(rawprogram, "w") as x:
            x.write('<?xml version="1.0" ?>\n<data>\n' + "".join(keep) + "</data>\n")
    argv = [s["qdl"], "-s", "emmc", "-S", s["serial"], "-i", set_dir, s["firehose"],
            rawprogram, os.path.join(set_dir, "patch0.xml")]
    with open(log_path, "w") as lf:
        lf.write("# set %s\n# image %s\n# root hash %s\n# argv %s\n"
                 % (set_dir, manifest["image_name"], manifest["verity_root_hash"], " ".join(argv)))
        lf.flush()
        p = subprocess.Popen(argv, cwd=set_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out = []
        for line in p.stdout:
            sys.stdout.write(line)
            lf.write(line)
            out.append(line)
        rc = p.wait()
    flashed = set(re.findall(r'flashed "([^"]+)" successfully', "".join(out)))
    if rc != 0 or flashed != wanted:
        die("qdl exit %d; flashed %s of %s; log %s" % (rc, sorted(flashed), sorted(wanted), log_path))
    log("flashed %d writes from %s" % (len(wanted), set_dir))
    log("log %s" % log_path)
    if args.only == "esp":
        log("p69 rewritten from the set; p71-p75 (UKI slots, rootfs, data) untouched. The firmware")
        log("variable store is now the set's VolatileVars.bin, and the ESP's slot UKIs are the set's:")
        log("a rootfs slot updated since the set was built no longer matches its UKI and fails verity.")
        log("Use --only recover when either slot may have been updated.")
        log("next: power off, pull the JCTL jumper, seat the console adapter, power on")
        return
    if args.only == "recover":
        log("p69, rootfsA and rootfsB rewritten from the set; efiA/efiB and /data untouched. Both")
        log("slots now match their UKIs; slot A boots, with the set's root hash %s."
            % manifest["verity_root_hash"][:16])
        log("next: power off, pull the JCTL jumper, seat the console adapter, power on, then")
        log("  %s verify-boot --log <console log>" % os.path.relpath(__file__, ROOT))
        return
    log("expect on the console: verity root hash %s, dm-mod.waitfor=%s"
        % (manifest["verity_root_hash"][:16], manifest["ukis"]["A"]["waitfor"]))
    log("next: power off, pull the JCTL jumper, seat the console adapter, power on, then")
    log("  %s verify-boot --log <console log>" % os.path.relpath(__file__, ROOT))


def cmd_verify_boot(args, s):
    if args.set:
        set_dir = os.path.abspath(args.set)
    else:
        set_dir = os.path.join(s["install"], "latest-" + args.image)
    manifest = json.load(open(os.path.join(set_dir, "MANIFEST.json")))
    data = open(args.log, "rb").read()[args.offset:]
    text = data.decode("latin-1")
    boots = [m.start() for m in re.finditer(r"Exit EBS", text)]
    seg = text[boots[-1]:] if boots else text
    m = None
    for m in re.finditer(r"Kernel command line: ([^\r\n]*)", seg):
        break
    if not m:
        print("verify-boot: no kernel command line in %s after the last firmware exit" % args.log)
        sys.exit(2)
    facts = cmdline_facts(m.group(1))
    want = manifest["verity_root_hash"]
    ok = facts["root_hash"] == want
    print("verify-boot: set      %s" % manifest["image_name"])
    print("verify-boot: expected root hash %s" % want)
    print("verify-boot: booted   root hash %s (slot %s, waitfor %s)"
          % (facts["root_hash"], facts["slot"], facts["waitfor"]))
    if not ok:
        print("verify-boot: FAIL - the board booted a different build than this set")
        sys.exit(1)
    if re.search(r"verity: Data device lookup failed|Waiting for root device", seg[m.end():]):
        print("verify-boot: FAIL - right build, but the verity root did not come up")
        sys.exit(1)
    print("verify-boot: PASS - booted the set's build")


def cmd_status(args, s):
    for k in ("conf_path", "build_dir", "qdl", "firehose", "serial", "unit_dir"):
        print("%-10s %s" % (k, s[k]))
    try:
        unit = json.load(open(os.path.join(s["unit_dir"], "unit.json")))
        print("unit       esp_source=%s imported %s" % (unit.get("esp_source"), unit.get("imported")))
        for k in ("gpt", "esp"):
            print("           %s %s  from %s" % (unit[k]["sha256"][:16], unit[k]["file"], unit[k]["source"]))
    except OSError:
        print("unit       (not imported)")
    try:
        build = deploy_build(s, args.image)
        d = os.path.join(s["install"], build["image_name"])
        print("build      %s root hash %s" % (build["image_name"], (build["root_hash"] or "?")[:16]))
        print("set        %s%s" % (d, "" if os.path.exists(d) else " (not prepared)"))
    except SystemExit as e:
        print("build      %s" % e)
    print("edl        %s" % (edl_present(s["serial"]) or "not present"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="\n".join(__doc__.splitlines()[1:]))
    ap.add_argument("--build-dir")
    ap.add_argument("--unit-dir")
    ap.add_argument("--qdl")
    ap.add_argument("--firehose")
    ap.add_argument("--serial")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("import-unit")
    p.add_argument("--gpt", required=True)
    p.add_argument("--esp", required=True)
    p.add_argument("--esp-source", required=True, choices=("pristine", "derived"),
                   help="pristine: cut from the unit's eMMC backup; derived: an earlier set's efi.vfat")
    p.add_argument("--note")

    for name in ("prep", "flash", "verify-boot", "status"):
        p = sub.add_parser(name)
        p.add_argument("--image", default="edge-image-dev")
        if name == "prep":
            p.add_argument("--force", action="store_true")
        if name == "flash":
            p.add_argument("--set")
            p.add_argument("--allow-other-build", action="store_true")
            p.add_argument("--wait", type=int, default=60, help="seconds to wait for the EDL device")
            p.add_argument("--only", choices=sorted(ONLY_LABELS),
                           help="esp: p69 alone (ESP and variable store; only while both rootfs slots "
                                "still match the set); recover: p69 + rootfsA + rootfsB (a matching "
                                "UKI/rootfs pair per slot, /data kept; custom-backend sets only)")
        if name == "verify-boot":
            p.add_argument("--log", required=True)
            p.add_argument("--set")
            p.add_argument("--offset", type=int, default=0)

    args = ap.parse_args()
    s = settings(args)
    {"import-unit": cmd_import_unit, "prep": cmd_prep, "flash": cmd_flash,
     "verify-boot": cmd_verify_boot, "status": cmd_status}[args.cmd](args, s)


if __name__ == "__main__":
    main()
