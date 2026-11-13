#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Host self-test for scripts/dev/ventunoq-flash.py against a fake deploy, a
generated factory-layout GPT, a small vfat ESP, a fake qdl and a fake USB sysfs:
a set is named after its build and holds that build's files; a newer build gets
a new set and the old one is not reused or flashed by default; a set whose UKI
boots another root, a changed set file, a missing EDL device or a wrong serial
are refused; a GPT dump failing its CRCs and, for a custom set, an ESP whose
variable store holds boot variables are refused; a retained set flashes with
--allow-other-build without build outputs; qdl gets absolute paths and the log lands in the set; verify-boot
tells the set's build from another one and from a hung verity root.
No device is touched. Exit 0 when every case passes.

  scripts/ci/ventunoq-flash-selftest.py
"""
import atexit, json, os, shutil, struct, subprocess, sys, tempfile, uuid, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.environ.get("VENTUNOQ_FLASH_TOOL", os.path.join(ROOT, "scripts", "dev", "ventunoq-flash.py"))
T = tempfile.mkdtemp(prefix="vq-flash-")
atexit.register(shutil.rmtree, T, True)
BUILD = f"{T}/build"
DEPLOY = f"{BUILD}/tmp/deploy/images/ventuno-q"
UNIT = f"{T}/unit"
SYSFS = f"{T}/sysfs"
SERIAL = "B1D16B87"
LINK = "edge-image-dev-ventuno-q.rootfs"
fails = 0


def check(name, cond):
    global fails
    print(("  ok   " if cond else "  FAIL ") + name)
    fails += 0 if cond else 1


def run(*args, env_extra=None):
    env = dict(os.environ, XDG_CONFIG_HOME=f"{T}/cfg", VENTUNOQ_SYSFS_USB=SYSFS)
    env.update(env_extra or {})
    r = subprocess.run([sys.executable, "-I", TOOL, "--build-dir", BUILD, "--unit-dir", UNIT,
                        "--qdl", f"{T}/qdl", "--firehose", f"{T}/prog.elf", "--serial", SERIAL]
                       + list(args), capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


# --- fixtures ---------------------------------------------------------------
# Disk of 300000 sectors: p1-p68 1 MiB each from 2048, p69 efi 2048 sectors,
# p70 persist, p71 system to the end. Layout: efiA/efiB/rootfsA/rootfsB 1 MiB, data rest.
def make_gpt(path):
    disk = 300000
    ents, lba = [], 2048
    def ent(name, first, last, t="0FC63DAF-8483-4772-8E79-3D69D8477DE4"):
        e = bytearray(128)
        e[0:16] = uuid.UUID(t).bytes_le
        e[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQ", e, 32, first, last)
        n = name.encode("utf-16-le"); e[56:56 + len(n)] = n
        return bytes(e)
    for i in range(1, 69):
        ents.append(ent("p%d" % i, lba, lba + 2047)); lba += 2048
    ents.append(ent("efi", lba, lba + 2047, "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")); esp = (lba, 2048); lba += 2048
    ents.append(ent("persist", lba, lba + 2047)); lba += 2048
    last_usable = disk - 34
    ents.append(ent("system", lba, last_usable))
    ents += [bytes(128)] * (128 - len(ents))
    arr = b"".join(ents)
    h = bytearray(92); h[0:8] = b"EFI PART"
    struct.pack_into("<IIII", h, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", h, 24, 1, disk - 1, 34, last_usable)
    h[56:72] = uuid.uuid4().bytes_le
    struct.pack_into("<QIII", h, 72, 2, 128, 128, zlib.crc32(arr) & 0xffffffff)
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
    open(path, "wb").write(bytes(512) + bytes(h) + bytes(420) + arr)
    return esp


def make_build(stamp, root_hash, waitfor=True, backend="efi"):
    os.makedirs(DEPLOY, exist_ok=True)
    tgt = f"{LINK}-{stamp}.ext4.verity"
    open(f"{DEPLOY}/{tgt}", "wb").write(("rootfs " + stamp).encode() * 100)
    for suffix, target in ((".ext4.verity", tgt), (".ext4.verity-params", f"{LINK}-{stamp}.ext4.verity-params")):
        if suffix == ".ext4.verity-params":
            open(f"{DEPLOY}/{target}", "w").write("VERITY_ROOT_HASH=%s\n" % root_hash)
        link = f"{DEPLOY}/{LINK}{suffix}"
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(target, link)
    for slot, dev in (("A", "/dev/mmcblk0p73"), ("B", "/dev/mmcblk0p74")):
        cl = ('root=/dev/dm-0 ro rauc.slot=%s %sdm-mod.create="vroot,,,ro,0 8 verity 1 %s %s 4096 4096 1 1 '
              'sha256 %s %s 1 restart_on_corruption" console=ttyMSM0'
              % (slot, ("dm-mod.waitfor=%s " % dev) if waitfor else "", dev, dev, root_hash, "ab" * 32))
        open(f"{DEPLOY}/{LINK}.uki-{slot}.efi", "wb").write(b"MZ\0stub\0" + cl.encode() + b"\0tail " + stamp.encode())
    for n in ("efiA.vfat", "efiB.vfat", "data.ext4"):
        open(f"{DEPLOY}/{LINK}.{n}", "wb").write((n + stamp).encode())
    if backend == "efi":
        esp_files = [{"path": "EFI/BOOT/BOOTAA64.EFI", "image": f"{LINK}.uki-A.efi"},
                     {"path": "EFI/ubuntu/shimaa64.efi", "image": f"{LINK}.uki-A.efi"}]
    else:
        open(f"{DEPLOY}/{LINK}.systemd-bootaa64.efi", "wb").write(b"MZ\0sd-boot " + stamp.encode())
        open(f"{DEPLOY}/{LINK}.loader.conf", "w").write("default edge-*\n")
        esp_files = [{"path": "EFI/BOOT/BOOTAA64.EFI", "image": f"{LINK}.systemd-bootaa64.efi"},
                     {"path": "EFI/ubuntu/shimaa64.efi", "image": f"{LINK}.systemd-bootaa64.efi"},
                     {"path": "loader/loader.conf", "image": f"{LINK}.loader.conf"},
                     {"path": "EFI/Linux/edge-2-a.efi", "image": f"{LINK}.uki-A.efi"},
                     {"path": "EFI/Linux/edge-1-b.efi", "image": f"{LINK}.uki-B.efi"}]
    json.dump({"machine": "ventuno-q", "first_partition": 71, "esp_files": esp_files, "rauc_backend": backend,
               "partitions": [
                   {"name": "efiA", "size_mib": 1, "type": "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "image": f"{LINK}.efiA.vfat"},
                   {"name": "efiB", "size_mib": 1, "type": "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "image": f"{LINK}.efiB.vfat"},
                   {"name": "rootfsA", "size_mib": 1, "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "image": f"{LINK}.ext4.verity"},
                   {"name": "rootfsB", "size_mib": 1, "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "image": f"{LINK}.ext4.verity"},
                   {"name": "data", "size_mib": None, "type": "00FB7005-AB51-4206-9D4A-11B68E508D3A", "image": f"{LINK}.data.ext4"}]},
              open(f"{DEPLOY}/{LINK}.install-layout.json", "w"))
    return f"{LINK}-{stamp}"


def edl(on, serial=SERIAL):
    shutil.rmtree(SYSFS, ignore_errors=True)
    os.makedirs(f"{SYSFS}/3-1.4.4")
    if on:
        for k, v in (("idVendor", "05c6"), ("idProduct", "9008"), ("serial", ""),
                     ("product", "QUSB_BULK_CID:0455_SN:%s" % serial)):
            open(f"{SYSFS}/3-1.4.4/{k}", "w").write(v + "\n")


os.makedirs(f"{T}/src")
esp_first, esp_n = make_gpt(f"{T}/src/gpt.bin")
subprocess.run(["mkfs.vfat", "-C", f"{T}/src/esp.img", str(esp_n // 2)], check=True, capture_output=True)
for d in ("::/EFI", "::/EFI/BOOT", "::/EFI/ubuntu"):
    subprocess.run(["mmd", "-i", f"{T}/src/esp.img", d], check=True)
open(f"{T}/VolatileVars.bin", "wb").write(b"vars")
subprocess.run(["mcopy", "-i", f"{T}/src/esp.img", f"{T}/VolatileVars.bin", "::/VolatileVars.bin"], check=True)
open(f"{T}/prog.elf", "wb").write(b"firehose")
# Fake qdl: records argv and cwd, reports each <program> label as flashed.
open(f"{T}/qdl", "w").write("""#!/usr/bin/env python3
import os, re, sys
open(os.environ.get("QDL_ARGV", "/dev/null"), "w").write(repr((os.getcwd(), sys.argv[1:])))
xml = [a for a in sys.argv if a.endswith("rawprogram0.xml")][0]
skip = os.environ.get("QDL_SKIP", "")
for l in re.findall(r'label="([^"]+)"', open(xml).read()):
    if l != skip:
        print('flashed "%s" successfully at 32768kB/s' % l)
""")
os.chmod(f"{T}/qdl", 0o755)

# --- cases ------------------------------------------------------------------
H1, H2 = "11" * 32, "22" * 32

print("1. import-unit")
rc, out = run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("exit 0, unit.json written", rc == 0 and os.path.exists(f"{UNIT}/unit.json"))
raw = bytearray(open(f"{T}/src/gpt.bin", "rb").read())
bad_entry = bytearray(raw); bad_entry[1024 + 16] ^= 0x01
open(f"{T}/gpt-bad-entry.bin", "wb").write(bytes(bad_entry))
rc, out = run("import-unit", "--gpt", f"{T}/gpt-bad-entry.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("GPT with a changed entry byte (array CRC) refused", rc != 0 and "CRC" in out)
bad_hdr = bytearray(raw); bad_hdr[512 + 40] ^= 0x01
open(f"{T}/gpt-bad-hdr.bin", "wb").write(bytes(bad_hdr))
rc, out = run("import-unit", "--gpt", f"{T}/gpt-bad-hdr.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("GPT with a changed header byte (header CRC) refused", rc != 0 and "CRC" in out)
open(f"{T}/gpt-short.bin", "wb").write(bytes(raw[:1024 + 128 * 64]))
rc, out = run("import-unit", "--gpt", f"{T}/gpt-short.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("GPT dump shorter than its declared entry array refused", rc != 0)
rc, out = run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("valid GPT re-imported", rc == 0)

print("2. prep names the set after the build")
n1 = make_build("20261020151445", H1)
rc, out = run("prep")
s1 = f"{BUILD}/install/{n1}"
m1 = json.load(open(f"{s1}/MANIFEST.json")) if rc == 0 else {}
check("exit 0, set dir is the IMAGE_NAME", rc == 0 and os.path.isdir(s1))
check("manifest root hash and waitfor", m1.get("verity_root_hash") == H1 and m1.get("ukis", {}).get("A", {}).get("waitfor") == "/dev/mmcblk0p73")
check("efi backend: ESP holds the build's UKI A, firmware files kept",
      subprocess.run(["mcopy", "-i", f"{s1}/efi.vfat", "::/EFI/BOOT/BOOTAA64.EFI", "-"], capture_output=True).stdout
      == open(f"{DEPLOY}/{LINK}.uki-A.efi", "rb").read()
      and b"VOLATI" in subprocess.run(["mdir", "-i", f"{s1}/efi.vfat", "::"], capture_output=True).stdout.upper())
def gpt_parts(path):
    raw = open(path, "rb").read()
    parts = {}
    for i in range(128):
        e = raw[1024 + 128 * i:1024 + 128 * (i + 1)]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        parts[e[56:128].decode("utf-16-le").rstrip("\0")] = (first, last - first + 1)
    return parts
p1 = gpt_parts(f"{s1}/gpt_main0.bin")
check("every slot partition starts and spans on the 128 KiB grain, data included",
      all(st % 256 == 0 and n % 256 == 0 for name, (st, n) in p1.items()
          if name in ("efiA", "efiB", "rootfsA", "rootfsB", "data")))
check("data ends within one grain of the last usable LBA",
      0 <= (300000 - 34) - (p1["data"][0] + p1["data"][1] - 1) < 256)
check("prep again refused without --force", run("prep")[0] != 0)

print("3. flash the current build")
edl(True)
rc, out = run("flash", env_extra={"QDL_ARGV": f"{T}/argv"})
cwd, argv = eval(open(f"{T}/argv").read()) if os.path.exists(f"{T}/argv") else (None, [])
check("exit 0", rc == 0)
check("qdl gets -i <set> and absolute xml paths", "-i" in argv and argv[argv.index("-i") + 1] == s1
      and f"{s1}/rawprogram0.xml" in argv and cwd == s1)
check("flash log in the set", any(f.startswith("flash-") for f in os.listdir(s1)))
check("expected root hash printed", H1[:16] in out)

print("4. a newer build gets a new set; the old one is not flashed by default")
n2 = make_build("20261020180740", H2)
os.remove(f"{T}/argv")
rc, out = run("flash", env_extra={"QDL_ARGV": f"{T}/argv"})
s2 = f"{BUILD}/install/{n2}"
cwd, argv = eval(open(f"{T}/argv").read()) if os.path.exists(f"{T}/argv") else (None, [])
check("exit 0, new set flashed", rc == 0 and cwd == s2)
check("new set carries the new build's files", json.load(open(f"{s2}/MANIFEST.json"))["verity_root_hash"] == H2
      and f"{LINK}-20261020180740.ext4.verity" in os.listdir(s2))
check("old set unchanged", json.load(open(f"{s1}/MANIFEST.json"))["verity_root_hash"] == H1)
rc, out = run("flash", "--set", s1)
check("flash --set <old set> refused", rc != 0 and "current" in out)
check("... allowed with --allow-other-build", run("flash", "--set", s1, "--allow-other-build")[0] == 0)
os.rename(DEPLOY, DEPLOY + ".away")
rc, out = run("flash", "--set", s1, "--allow-other-build")
check("retained set flashes with --allow-other-build and no deploy outputs", rc == 0)
check("... still refused without --allow-other-build", run("flash", "--set", s1)[0] != 0)
open(f"{s1}/efi.vfat", "ab").write(b"x")
check("... a changed retained set is still refused", run("flash", "--set", s1, "--allow-other-build")[0] != 0)
os.rename(DEPLOY + ".away", DEPLOY)

print("5. refusals")
open(f"{s2}/efi.vfat", "ab").write(b"x")
check("changed set file", run("flash")[0] != 0)
shutil.rmtree(s2); run("prep")
edl(False)
check("no EDL device", run("flash", "--wait", "0")[0] != 0)
edl(True, serial="0AA94EFD")
check("EDL device with another serial", run("flash", "--wait", "0")[0] != 0)
edl(True)
rc, out = run("flash", env_extra={"QDL_SKIP": "rootfsB"})
check("qdl that skips a write", rc != 0 and "rootfsB" in out)
make_build("20261020190000", H2)
open(f"{DEPLOY}/{LINK}.uki-B.efi", "wb").write(b'MZ\0dm-mod.create="vroot verity 1 ' + ("33" * 32).encode() + b'"\0')
check("UKI booting another root", run("prep")[0] != 0)
make_build("20261020190001", H2)
run("prep")

print("6. flash --only esp writes p69 alone")
s3 = f"{BUILD}/install/{LINK}-20261020190001"
full = [l for l in open(f"{s3}/rawprogram0.xml").read().splitlines() if 'label="efi"' in l]
if os.path.exists(f"{T}/argv"):
    os.remove(f"{T}/argv")
rc, out = run("flash", "--only", "esp", env_extra={"QDL_ARGV": f"{T}/argv"})
cwd, argv = eval(open(f"{T}/argv").read()) if os.path.exists(f"{T}/argv") else (None, [])
xmls = [a for a in argv if a.endswith("rawprogram0.xml")]
sub_xml = open(xmls[0]).read() if xmls and os.path.exists(xmls[0]) else ""
check("exit 0", rc == 0)
check("qdl gets a flash-*-esp program list inside the set",
      len(xmls) == 1 and os.path.dirname(xmls[0]) == s3 and os.path.basename(xmls[0]).startswith("flash-")
      and xmls[0].endswith("-esp-rawprogram0.xml") and cwd == s3)
check("only the efi label is written", set(__import__("re").findall(r'label="([^"]+)"', sub_xml)) == {"efi"})
check("efi program is the set's own line (same sectors)",
      len(full) == 1 and full[0].strip() in sub_xml and f'start_sector="{esp_first}"' in sub_xml)
check("set still verifies after an esp-only flash", run("flash", "--only", "esp")[0] == 0)
rc, out = run("flash", "--only", "esp", env_extra={"QDL_SKIP": "efi"})
check("qdl that skips efi: fail", rc != 0 and "efi" in out)
check("--only refuses a bare partition label", run("flash", "--only", "rootfsA")[0] != 0)

print("6b. flash --only recover: efi sets refused before qdl; custom sets write p69 and both rootfs slots")
# s3 is an efi-backend set: its slot UKIs live on efiA/efiB, which recover does not write.
if os.path.exists(f"{T}/argv"):
    os.remove(f"{T}/argv")
rc, out = run("flash", "--only", "recover", env_extra={"QDL_ARGV": f"{T}/argv"})
check("efi set: refused, qdl not run", rc != 0 and "custom-backend set" in out and not os.path.exists(f"{T}/argv"))
m3 = json.load(open(f"{s3}/MANIFEST.json"))
check("efi set records rauc_backend efi", m3.get("rauc_backend") == "efi")
legacy = dict(m3); legacy.pop("rauc_backend")
json.dump(legacy, open(f"{s3}/MANIFEST.json", "w"), indent=2)
rc, out = run("flash", "--only", "recover", "--wait", "0", env_extra={"QDL_ARGV": f"{T}/argv"})
check("set without rauc_backend (older tool): refused, qdl not run",
      rc != 0 and "custom-backend set" in out and not os.path.exists(f"{T}/argv"))
json.dump(m3, open(f"{s3}/MANIFEST.json", "w"), indent=2)
check("efi set: --only esp still allowed", run("flash", "--only", "esp")[0] == 0)
nr = make_build("20261020190002", H2, backend="custom")
run("prep")
s3 = f"{BUILD}/install/{nr}"
check("custom set records rauc_backend custom", json.load(open(f"{s3}/MANIFEST.json")).get("rauc_backend") == "custom")
m3 = json.load(open(f"{s3}/MANIFEST.json"))
legacy = dict(m3); legacy.pop("rauc_backend")
json.dump(legacy, open(f"{s3}/MANIFEST.json", "w"), indent=2)
check("custom set without rauc_backend (slot entries in EFI/Linux): allowed",
      run("flash", "--only", "recover")[0] == 0)
json.dump(m3, open(f"{s3}/MANIFEST.json", "w"), indent=2)
full_lines = {l: [x for x in open(f"{s3}/rawprogram0.xml").read().splitlines() if f'label="{l}"' in x][0]
              for l in ("efi", "rootfsA", "rootfsB")}
if os.path.exists(f"{T}/argv"):
    os.remove(f"{T}/argv")
rc, out = run("flash", "--only", "recover", env_extra={"QDL_ARGV": f"{T}/argv"})
cwd, argv = eval(open(f"{T}/argv").read()) if os.path.exists(f"{T}/argv") else (None, [])
xmls = [a for a in argv if a.endswith("rawprogram0.xml")]
sub_xml = open(xmls[0]).read() if xmls and os.path.exists(xmls[0]) else ""
check("exit 0", rc == 0)
check("program list is a flash-*-recover list in the set",
      len(xmls) == 1 and os.path.dirname(xmls[0]) == s3 and xmls[0].endswith("-recover-rawprogram0.xml"))
check("labels are efi, rootfsA, rootfsB only",
      set(__import__("re").findall(r'label="([^"]+)"', sub_xml)) == {"efi", "rootfsA", "rootfsB"})
check("each line is the set's own line", all(v.strip() in sub_xml for v in full_lines.values()))
rc, out = run("flash", "--only", "recover", env_extra={"QDL_SKIP": "rootfsB"})
check("qdl that skips rootfsB: fail", rc != 0 and "rootfsB" in out)

print("7. custom backend: the ESP holds exactly the build's esp_files")
def esp_read(set_dir, path):
    return subprocess.run(["mcopy", "-i", f"{set_dir}/efi.vfat", "::/" + path, "-"], capture_output=True).stdout
def esp_ls(set_dir, d):
    r = subprocess.run(["mdir", "-b", "-i", f"{set_dir}/efi.vfat", "::/" + d], capture_output=True, text=True)
    return sorted(os.path.basename(l.rstrip("/")) for l in r.stdout.split()) if r.returncode == 0 else None
# A stale slot UKI from an earlier install must not survive in \EFI\Linux.
for d in ("::/EFI/Linux",):
    subprocess.run(["mmd", "-i", f"{T}/src/esp.img", d], check=True)
open(f"{T}/stale.efi", "wb").write(b"MZ stale")
subprocess.run(["mcopy", "-i", f"{T}/src/esp.img", f"{T}/stale.efi", "::/EFI/Linux/edge-7-a+1-2.efi"], check=True)
# An existing loader.conf (factory or earlier install) is replaced, not kept.
subprocess.run(["mmd", "-i", f"{T}/src/esp.img", "::/loader"], check=True)
open(f"{T}/old-loader.conf", "w").write("default @saved\ntimeout 5\n")
subprocess.run(["mcopy", "-i", f"{T}/src/esp.img", f"{T}/old-loader.conf", "::/loader/loader.conf"], check=True)
run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
n4 = make_build("20261111120000", H2, backend="custom")
rc, out = run("prep")
s4 = f"{BUILD}/install/{n4}"
m4 = json.load(open(f"{s4}/MANIFEST.json")) if rc == 0 else {}
check("prep exit 0", rc == 0)
check("systemd-boot at the removable path and Boot0000 path",
      esp_read(s4, "EFI/BOOT/BOOTAA64.EFI") == open(f"{DEPLOY}/{LINK}.systemd-bootaa64.efi", "rb").read()
      and esp_read(s4, "EFI/ubuntu/shimaa64.efi") == open(f"{DEPLOY}/{LINK}.systemd-bootaa64.efi", "rb").read())
check("slot UKIs at their entry names", esp_read(s4, "EFI/Linux/edge-2-a.efi") == open(f"{DEPLOY}/{LINK}.uki-A.efi", "rb").read()
      and esp_read(s4, "EFI/Linux/edge-1-b.efi") == open(f"{DEPLOY}/{LINK}.uki-B.efi", "rb").read())
check("stale entries removed from EFI/Linux", esp_ls(s4, "EFI/Linux") == ["edge-1-b.efi", "edge-2-a.efi"])
check("loader.conf placed", esp_read(s4, "loader/loader.conf") == b"default edge-*\n")
check("firmware variable store kept", esp_read(s4, "VolatileVars.bin") == b"vars")
check("manifest lists the ESP files", sorted(m4.get("esp_files", {})) == sorted(
      ["EFI/BOOT/BOOTAA64.EFI", "EFI/ubuntu/shimaa64.efi", "loader/loader.conf",
       "EFI/Linux/edge-2-a.efi", "EFI/Linux/edge-1-b.efi"]))
lay = json.load(open(f"{DEPLOY}/{LINK}.install-layout.json"))
for bad in ("../VolatileVars.bin", "EFI/../VolatileVars.bin", "VolatileVars.bin", "/EFI/BOOT/x.efi"):
    lay["esp_files"] = [{"path": bad, "image": f"{LINK}.uki-A.efi"}]
    json.dump(lay, open(f"{DEPLOY}/{LINK}.install-layout.json", "w"))
    check("esp_files path %r refused" % bad, run("prep", "--force")[0] != 0)
lay.pop("esp_files")
json.dump(lay, open(f"{DEPLOY}/{LINK}.install-layout.json", "w"))
check("layout without esp_files refused", run("prep", "--force")[0] != 0)
make_build("20261111120001", H2, backend="custom")
run("prep")
subprocess.run(["cp", f"{T}/src/esp.img", f"{T}/esp-used.img"], check=True)
open(f"{T}/vars-used.bin", "wb").write(b"\0\0\0\0" + "BootOrder".encode("utf-16-le") + b"\0\0\x07\0"
                                         + "Boot0007".encode("utf-16-le"))
subprocess.run(["mcopy", "-o", "-i", f"{T}/esp-used.img", f"{T}/vars-used.bin", "::/VolatileVars.bin"], check=True)
run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/esp-used.img", "--esp-source", "pristine")
rc, out = run("prep", "--force")
check("custom set from an ESP whose store holds boot variables refused", rc != 0 and "BootOrder" in out)
open(f"{T}/esp-unreadable.img", "wb").write(bytes(os.path.getsize(f"{T}/src/esp.img")))
run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/esp-unreadable.img", "--esp-source", "pristine")
rc, out = run("prep", "--force")
check("custom set from an unreadable ESP refused (inspection failure is not an empty store)",
      rc != 0 and "cannot read" in out)
subprocess.run(["cp", f"{T}/src/esp.img", f"{T}/esp-nostore.img"], check=True)
subprocess.run(["mdel", "-i", f"{T}/esp-nostore.img", "::/VolatileVars.bin"], check=True)
run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/esp-nostore.img", "--esp-source", "pristine")
rc, out = run("prep", "--force")
check("custom set from an ESP without VolatileVars.bin refused", rc != 0 and "VolatileVars.bin" in out)
run("import-unit", "--gpt", f"{T}/src/gpt.bin", "--esp", f"{T}/src/esp.img", "--esp-source", "pristine")
check("custom set from an ESP with an empty-of-boot-variables store accepted", run("prep", "--force")[0] == 0)

print("8. verify-boot")
def console(h, extra=""):
    p = f"{T}/console.log"
    open(p, "w").write("old boot\nExit EBS [1] UEFI End\n[0.0] Kernel command line: root=/dev/dm-0 "
                       'dm-mod.create="vroot,,,ro,0 8 verity 1 /dev/x /dev/x 4096 4096 1 1 sha256 %s %s 1"\n'
                       "Exit EBS [2] UEFI End\n[0.0] Kernel command line: rauc.slot=A dm-mod.waitfor=/dev/mmcblk0p73 "
                       'dm-mod.create="vroot,,,ro,0 8 verity 1 /dev/mmcblk0p73 /dev/mmcblk0p73 4096 4096 1 1 sha256 %s %s 1"\n%s'
                       % (H1, "ab" * 32, h, "ab" * 32, extra))
    return p
check("set's build: pass", run("verify-boot", "--log", console(H2))[0] == 0)
check("another build: fail", run("verify-boot", "--log", console(H1))[0] == 1)
check("set's build, hung verity root: fail",
      run("verify-boot", "--log", console(H2, "[4.4] device-mapper: table: 252:0: verity: Data device lookup failed (-ENODEV)\n"))[0] == 1)
open(f"{T}/console.log", "w").write("Exit EBS\nno kernel yet\n")
check("no kernel line yet: exit 2", run("verify-boot", "--log", f"{T}/console.log")[0] == 2)

print("RESULT: " + ("all passed" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
