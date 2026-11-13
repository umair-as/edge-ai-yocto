# dm-verity rootfs settings shared by every boot-chain family (ADR-0008).
# Each family's class builds the boot payload that carries the verity table;
# the table's inputs are defined once, here.

IMAGE_FSTYPES:append = " verity"
IMAGE_FEATURES:append = " read-only-rootfs"

# Stable per-image salt preserves reproducibility while avoiding the shared
# class default. The root hash still changes whenever rootfs content changes.
VERITY_SALT = "${@__import__('hashlib').sha256(('%s:%s:%s' % (d.getVar('PN'), d.getVar('MACHINE'), d.getVar('DISTRO'))).encode()).hexdigest()}"

# Kernel arguments after the verity table in the slot command line. Boards
# append their console and bus arguments in the board include.
EDGE_VERITY_KERNEL_ARGS ?= "earlycon security=selinux hash_pointers=always hardened_usercopy=1 kfence.sample_interval=100 proc_mem.force_override=never init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none"
