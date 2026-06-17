# linux-renesas 6.12 (CIP-base) carries libbpf.c const-qualifier patterns
# that GCC 15.x rejects under -Werror=discarded-qualifiers. perf's own
# WERROR=0 export in the base recipe doesn't suppress per-flag -Werror=
# in the bundled libbpf's Makefile. Append -Wno-error= to both optimization
# settings (perf.bb line 424 sets the same precedent for -maybe-uninitialized).
# Drop when linux-renesas advances past upstream's const-qualifier fixes.
SELECTED_OPTIMIZATION:append = " -Wno-error=discarded-qualifiers"
DEBUG_OPTIMIZATION:append    = " -Wno-error=discarded-qualifiers"
