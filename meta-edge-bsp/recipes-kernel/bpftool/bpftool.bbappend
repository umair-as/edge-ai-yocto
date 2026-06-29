# linux-renesas 6.12 (CIP-base) carries libbpf.c const-qualifier patterns that
# GCC 15.x rejects under -Werror=discarded-qualifiers. bpftool builds the same
# in-tree libbpf via tools/build/Makefile.build as perf, passing ${CFLAGS} into
# its CC, so it hits the identical error. Mirror perf.bbappend: append -Wno-error=
# to both optimization settings (SELECTED_OPTIMIZATION resolves to one of them).
# Drop when linux-renesas advances past upstream's const-qualifier fixes.
SELECTED_OPTIMIZATION:append = " -Wno-error=discarded-qualifiers"
DEBUG_OPTIMIZATION:append    = " -Wno-error=discarded-qualifiers"
