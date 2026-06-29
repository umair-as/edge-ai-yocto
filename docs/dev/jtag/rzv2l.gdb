# RZ/V2L kernel debug over JTAG — gdb-multiarch init (debug-profile kernel).
#
# Usage (vmlinux passed on the command line; OpenOCD GDB server on :3333):
#   VM=$(find build/tmp/work -path '*linux-renesas*standard-build/vmlinux' | head -1)
#   gdb-multiarch "$VM" -x docs/dev/jtag/rzv2l.gdb
#
# KASLR-OFF variant: the debug-profile kernel (make dev JTAG=1) builds with
# RANDOMIZE_BASE disabled, so vmlinux symbols equal runtime addresses and there
# is NO offset to apply — `bt` is symbolized immediately. (A stock KASLR kernel
# would instead need `add-symbol-file vmlinux -o <slide>`.)

set pagination off
set architecture aarch64

# DWARF records source as /usr/src/kernel; remap to the in-tree kernel source.
set substitute-path /usr/src/kernel build/tmp/work-shared/smarc-rzv2l/kernel-source

target extended-remote localhost:3333

# Optional in-tree gdb helpers (lx-ps, lx-dmesg, lx-symbols). constants.py is
# generated into the kernel build dir by the JTAG build (oe_runmake scripts_gdb);
# source the vmlinux-gdb.py that sits next to it:
#   (gdb) source <...>/linux-smarc_rzv2l-standard-build/vmlinux-gdb.py
# Locate it with:
#   find build/tmp/work -path '*standard-build/vmlinux-gdb.py'
