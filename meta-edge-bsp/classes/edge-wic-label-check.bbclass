## edge-wic-label-check.bbclass
##
## Build-time gate: validates that every --source rootfs partition in the
## edge RAUC WKS files carries an explicit --label.  Fails the build
## instead of silently producing a WIC image whose first rootfs slot has no
## ext4 label (a known WIC limitation when two --source rootfs entries share
## the same rootfs image).
##
## Also warns when the WIC duplicate-rootfs labelling quirk is detected, so
## developers know that bundle-hooks.sh / e2label is the runtime safety net.
##
## Inherit in any bundle recipe or image recipe that references these WKS:
##   inherit edge-wic-label-check

python do_edge_wic_label_check() {
    import glob
    import os
    import re

    # Labels that every RAUC image WKS must define on --source rootfs lines.
    REQUIRED_ROOTFS_LABELS = ("rootfsA", "rootfsB")

    def collect_rootfs_labels(wks_path):
        """Return list of (label, lineno) for every --source rootfs line."""
        found = []
        with open(wks_path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                stripped = line.strip()
                if stripped.startswith("#") or "--source rootfs" not in stripped:
                    continue
                m = re.search(r"--label\s+(\S+)", stripped)
                label = m.group(1) if m else None
                found.append((label, lineno))
        return found

    # Discover WKS files. Primary source: WKS_SEARCH_PATH (canonical Yocto
    # variable image-common.inc sets to where our .wks files live).
    # Fallback: BBPATH-anchored layouts so a recipe that doesn't require
    # image-common.inc still finds them.
    wks_paths = []

    wks_search_path = (d.getVar("WKS_SEARCH_PATH") or "").strip()
    for base in wks_search_path.split(":"):
        base = base.strip()
        if not base:
            continue
        for candidate in sorted(glob.glob(os.path.join(base, "edge-image-*.wks"))):
            if candidate not in wks_paths:
                wks_paths.append(candidate)

    if not wks_paths:
        # BBPATH fallback: <layer>/recipes-core/images/files/wic/ or
        # <layer>/wic/ — covers current layout and older trees.
        for base in (d.getVar("BBPATH") or "").split(":"):
            base = base.strip()
            if not base:
                continue
            for sub in ("recipes-core/images/files/wic", "wic"):
                for candidate in sorted(glob.glob(os.path.join(base, sub, "edge-image-*.wks"))):
                    if candidate not in wks_paths:
                        wks_paths.append(candidate)

    if not wks_paths:
        bb.fatal(
            "edge-wic-label-check: could not find any edge-image-*.wks files. "
            "Checked WKS_SEARCH_PATH (%s) and BBPATH fallbacks." % wks_search_path
        )

    for wks_path in wks_paths:
        name = os.path.basename(wks_path)
        entries = collect_rootfs_labels(wks_path)

        # 1. Every --source rootfs line must have a --label.
        unlabelled = [lineno for label, lineno in entries if label is None]
        if unlabelled:
            bb.fatal(
                "edge-wic-label-check [%s]: --source rootfs partition(s) at line(s) %s "
                "have no --label. Add explicit --label rootfsA / --label rootfsB."
                % (name, ", ".join(str(l) for l in unlabelled))
            )

        labels_found = [label for label, _ in entries]

        # 2. Required labels must all be present.
        for required in REQUIRED_ROOTFS_LABELS:
            if required not in labels_found:
                bb.fatal(
                    "edge-wic-label-check [%s]: required rootfs slot label '%s' not found. "
                    "Expected --label rootfsA and --label rootfsB on --source rootfs lines."
                    % (name, required)
                )

        # 3. Warn about the WIC duplicate-source-rootfs labelling quirk so
        #    developers know why bundle-hooks.sh runs e2label after each install.
        if len(labels_found) >= 2:
            bb.warn(
                "edge-wic-label-check [%s]: two --source rootfs partitions detected. "
                "WIC may not write the ext4 label for the first slot ('%s') into the image "
                "superblock (known WIC limitation). "
                "bundle-hooks.sh e2label post-install is the runtime safety net."
                % (name, labels_found[0])
            )

        bb.note(
            "edge-wic-label-check [%s]: OK — rootfs labels: %s"
            % (name, ", ".join(labels_found))
        )
}

addtask edge_wic_label_check before do_configure after do_patch
