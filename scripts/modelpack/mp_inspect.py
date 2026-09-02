"""Independent inspection, safe unpacking and round-trip comparison.

Nothing here trusts producer-reported values. Every descriptor digest and size
is recomputed from the blob on disk, and every blob file name is checked against
the hash of its own content.

Checks fail closed. A required check that cannot run is reported as a problem
rather than skipped, and a required member is checked for its type as well as
its presence: a directory named deploy.json is not a model.
"""

import json
import os
import posixpath
import stat

import mp_oci
import mp_schema
from mp_oci import sha256_file

# A layer member the semantic checks need is read into memory. Above this size
# the check is reported as unperformed instead of silently dropped.
MAX_INSPECT_BYTES = 64 * 1024 * 1024


class InspectionError(Exception):
    pass


def _require(condition, message, problems):
    if not condition:
        problems.append(message)
    return condition


def _read_json(path):
    with open(path, "rb") as handle:
        return json.loads(handle.read())


def _walk_blobs(layout_dir):
    root = os.path.join(layout_dir, "blobs", "sha256")
    if not os.path.isdir(root):
        return {}
    return {name: os.path.join(root, name) for name in sorted(os.listdir(root))}


def _check_descriptor(layout_dir, desc, expected_media_type, label, problems):
    """Recompute the digest and size of the blob this descriptor points at."""
    digest = desc.get("digest", "")
    algorithm, _, hex_digest = digest.partition(":")
    if algorithm != "sha256" or len(hex_digest) != 64:
        problems.append("%s: unsupported or malformed digest %r" % (label, digest))
        return None
    blob = os.path.join(layout_dir, "blobs", "sha256", hex_digest)
    if not os.path.isfile(blob):
        problems.append("%s: blob is missing: blobs/sha256/%s" % (label, hex_digest))
        return None

    actual_digest = sha256_file(blob)
    if actual_digest != hex_digest:
        problems.append("%s: blob content does not match its own name "
                        "(name %s, content sha256:%s)"
                        % (label, hex_digest, actual_digest))
    actual_size = os.path.getsize(blob)
    if desc.get("size") != actual_size:
        problems.append("%s: size mismatch (descriptor %r, actual %d)"
                        % (label, desc.get("size"), actual_size))
    if desc.get("mediaType") != expected_media_type:
        problems.append("%s: mediaType must be %s, got %r"
                        % (label, expected_media_type, desc.get("mediaType")))
    return hex_digest


def _output_element_count(deploy):
    """Element count of the compiled graph's first output entry.

    TVM graph JSON: heads name (node_id, index) pairs, node_row_ptr maps a node
    to its first entry id, and attrs.shape holds one shape per entry.
    """
    try:
        shapes = deploy["attrs"]["shape"][1]
        node_id, index = deploy["heads"][0][0], deploy["heads"][0][1]
        entry_id = deploy["node_row_ptr"][node_id] + index
        shape = shapes[entry_id]
    except (KeyError, IndexError, TypeError) as exc:
        raise InspectionError(
            "cannot read the output shape from deploy.json (%s); the "
            "classification label-count check cannot be performed" % exc)
    count = 1
    for dim in shape:
        count *= int(dim)
    return count, shape


def _layer_members(layout_dir, digest, wanted=()):
    """Read the layer once.

    Returns (members, contents, duplicates). `wanted` names the members whose
    bytes the semantic checks need. One larger than MAX_INSPECT_BYTES is not
    read; its member entry is flagged `oversized` so the caller reports the
    check as unperformed instead of passing the artifact silently.
    """
    members = {}
    contents = {}
    duplicates = []
    wanted = set(wanted)
    tar = mp_oci.open_layer_tar(layout_dir, digest)
    try:
        for info in tar:
            kind = ("dir" if info.isdir() else
                    "file" if info.isreg() else "other")
            if info.name in members:
                duplicates.append(info.name)
            members[info.name] = {
                "kind": kind, "size": info.size, "mode": info.mode,
                "uid": info.uid, "gid": info.gid, "mtime": info.mtime,
                "uname": info.uname, "gname": info.gname,
                "type": info.type, "oversized": False,
            }
            if kind == "file" and info.name in wanted:
                if info.size > MAX_INSPECT_BYTES:
                    members[info.name]["oversized"] = True
                    continue
                handle = tar.extractfile(info)
                if handle is not None:
                    contents[info.name] = handle.read()
    finally:
        tar.close()
    return members, contents, duplicates


def _validate_envelope(index, manifest, config, problems):
    """The OCI envelope's own fields, not just the blobs they point at."""
    _require(index.get("schemaVersion") == 2,
             "index.json: schemaVersion must be 2, got %r"
             % index.get("schemaVersion"), problems)
    _require(index.get("mediaType") == mp_schema.INDEX_MEDIA_TYPE,
             "index.json: mediaType must be %s, got %r"
             % (mp_schema.INDEX_MEDIA_TYPE, index.get("mediaType")), problems)

    descriptor = (index.get("manifests") or [{}])[0]
    _require(descriptor.get("artifactType") == mp_schema.ARTIFACT_TYPE,
             "index.json manifest descriptor: artifactType must be %s, got %r"
             % (mp_schema.ARTIFACT_TYPE, descriptor.get("artifactType")),
             problems)

    expected_ref = "%s:%s" % (config.get("name"), config.get("version"))
    actual_ref = (descriptor.get("annotations") or {}).get(
        mp_schema.REF_NAME_ANNOTATION)
    _require(actual_ref == expected_ref,
             "index.json manifest descriptor: %s must be %r, got %r"
             % (mp_schema.REF_NAME_ANNOTATION, expected_ref, actual_ref),
             problems)

    _require(manifest.get("mediaType") == mp_schema.MANIFEST_MEDIA_TYPE,
             "manifest: mediaType must be %s, got %r"
             % (mp_schema.MANIFEST_MEDIA_TYPE, manifest.get("mediaType")),
             problems)
    _require(manifest.get("artifactType") == mp_schema.ARTIFACT_TYPE,
             "manifest: artifactType must be %s, got %r"
             % (mp_schema.ARTIFACT_TYPE, manifest.get("artifactType")), problems)
    _require(manifest.get("schemaVersion") == 2,
             "manifest: schemaVersion must be 2, got %r"
             % manifest.get("schemaVersion"), problems)


def _check_member(members, path, expected_kind, why, problems):
    meta = members.get(path)
    if meta is None:
        problems.append("layer: %s but %r is absent" % (why, path))
        return None
    if meta["kind"] != expected_kind:
        problems.append("layer: %r must be a %s, found a %s"
                        % (path, expected_kind, meta["kind"]))
        return None
    return meta


def inspect_layout(layout_dir):
    """Verify a layout end to end. Returns (summary, problems)."""
    problems = []
    summary = {"layout": os.path.abspath(layout_dir)}

    layout_marker = os.path.join(layout_dir, "oci-layout")
    if not os.path.isfile(layout_marker):
        raise InspectionError("not an OCI image layout: oci-layout is missing")
    marker = _read_json(layout_marker)
    _require(marker.get("imageLayoutVersion") == mp_oci.IMAGE_LAYOUT_VERSION,
             "oci-layout: imageLayoutVersion must be %r, got %r"
             % (mp_oci.IMAGE_LAYOUT_VERSION, marker.get("imageLayoutVersion")),
             problems)

    index_path = os.path.join(layout_dir, "index.json")
    if not os.path.isfile(index_path):
        raise InspectionError("index.json is missing")
    index = _read_json(index_path)
    manifests = index.get("manifests") or []
    if len(manifests) != 1:
        raise InspectionError("index.json must reference exactly one manifest, "
                              "found %d" % len(manifests))

    manifest_desc = manifests[0]
    manifest_hex = _check_descriptor(layout_dir, manifest_desc,
                                     mp_schema.MANIFEST_MEDIA_TYPE,
                                     "index.json manifest descriptor", problems)
    if manifest_hex is None:
        return summary, problems
    summary["manifestDigest"] = "sha256:" + manifest_hex

    manifest = json.loads(mp_oci.read_blob(layout_dir, "sha256:" + manifest_hex))

    annotations = manifest.get("annotations") or {}
    _require(mp_schema.CREATED_ANNOTATION in annotations,
             "manifest: %s annotation is required and must be pinned"
             % mp_schema.CREATED_ANNOTATION, problems)

    config_desc = manifest.get("config") or {}
    config_hex = _check_descriptor(layout_dir, config_desc,
                                   mp_schema.CONFIG_MEDIA_TYPE,
                                   "manifest config descriptor", problems)

    layers = manifest.get("layers") or []
    if len(layers) != 1:
        problems.append("manifest: exactly one weight layer is expected, found %d"
                        % len(layers))
        return summary, problems
    layer_hex = _check_descriptor(layout_dir, layers[0],
                                  mp_schema.WEIGHT_LAYER_MEDIA_TYPE,
                                  "manifest layer descriptor", problems)
    summary["layerDigest"] = layers[0].get("digest")
    summary["configDigest"] = config_desc.get("digest")

    referenced = {h for h in (manifest_hex, config_hex, layer_hex) if h}
    for name in _walk_blobs(layout_dir):
        if name not in referenced:
            problems.append("blobs/sha256/%s is not referenced by the manifest "
                            "graph" % name)

    if config_hex is None or layer_hex is None:
        return summary, problems

    config = json.loads(mp_oci.read_blob(layout_dir, "sha256:" + config_hex))
    for error in mp_schema.validate_config(config):
        problems.append("config: %s" % error)
    summary["name"] = config.get("name")
    summary["version"] = config.get("version")
    summary["decoder"] = (config.get("decoder") or {}).get("class")

    _validate_envelope(index, manifest, config, problems)

    accelerator = config.get("accelerator")
    if annotations.get(mp_schema.ACCELERATOR_ANNOTATION) != accelerator:
        problems.append("manifest: %s annotation (%r) must match config "
                        "accelerator (%r)"
                        % (mp_schema.ACCELERATOR_ANNOTATION,
                           annotations.get(mp_schema.ACCELERATOR_ANNOTATION),
                           accelerator))

    model = config.get("model") if isinstance(config.get("model"), dict) else {}
    model_dir = model.get("directory")
    labels = config.get("labels") if isinstance(config.get("labels"), dict) else {}
    labels_path = labels.get("path")
    labels_count = labels.get("count")

    wanted = []
    if isinstance(labels_path, str) and labels_path:
        wanted.append(labels_path)
    if isinstance(model_dir, str) and model_dir:
        wanted.append(posixpath.join(model_dir, "deploy.json"))

    members, contents, duplicates = _layer_members(
        layout_dir, layers[0]["digest"], wanted)
    summary["layerEntries"] = len(members)

    for name in sorted(set(duplicates)):
        problems.append("layer: %r appears more than once; which entry wins is "
                        "consumer-dependent" % name)

    for name, meta in sorted(members.items()):
        if meta["kind"] == "other":
            problems.append("layer: %r is not a regular file or directory "
                            "(tar type %r)" % (name, meta["type"]))
        if name.startswith("/") or any(
                part in ("", ".", "..") for part in name.split("/")):
            problems.append("layer: unsafe member path %r" % name)

    if isinstance(model_dir, str) and model_dir:
        _check_member(members, model_dir, "dir",
                      "config references model.directory %r" % model_dir,
                      problems)
        for entry, kind in mp_schema.REQUIRED_MODEL_ENTRIES:
            _check_member(members, posixpath.join(model_dir, entry), kind,
                          "config references model.directory %r" % model_dir,
                          problems)

    if isinstance(labels_path, str) and labels_path:
        meta = _check_member(members, labels_path, "file",
                             "config references labels.path %r" % labels_path,
                             problems)
        if meta is not None and meta["oversized"]:
            problems.append("labels: %r is %d bytes, above the %d-byte "
                            "inspection limit; its label-count check did not run"
                            % (labels_path, meta["size"], MAX_INSPECT_BYTES))
        elif meta is not None:
            raw = contents.get(labels_path, b"")
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                problems.append("labels: %r is not valid UTF-8 (%s)"
                                % (labels_path, exc))
            else:
                actual = sum(1 for line in text.splitlines() if line.strip())
                if actual != labels_count:
                    problems.append("labels: %r holds %d non-empty lines but "
                                    "labels.count is %r"
                                    % (labels_path, actual, labels_count))
                summary["labelLines"] = actual

    if summary.get("decoder") == "classification" and isinstance(model_dir, str):
        deploy_path = posixpath.join(model_dir, "deploy.json")
        meta = members.get(deploy_path)
        if meta is not None and meta["kind"] == "file":
            if meta["oversized"]:
                problems.append("classification: %r is %d bytes, above the "
                                "%d-byte inspection limit; the output/label "
                                "count check did not run"
                                % (deploy_path, meta["size"], MAX_INSPECT_BYTES))
            else:
                count, shape = _output_element_count(
                    json.loads(contents[deploy_path]))
                summary["outputShape"] = shape
                if count != labels_count:
                    problems.append(
                        "classification: compiled output has %d elements "
                        "(shape %s) but labels.count is %r; the decoder would "
                        "map indices onto the wrong names"
                        % (count, shape, labels_count))

    return summary, problems


def safe_extract(layout_dir, digest, destination):
    """Extract the layer, refusing anything a model store must not create."""
    os.makedirs(destination, exist_ok=True)
    real_root = os.path.realpath(destination)
    tar = mp_oci.open_layer_tar(layout_dir, digest)
    dir_modes = []
    seen = set()
    try:
        for info in tar:
            name = info.name
            if name in seen:
                raise InspectionError("refusing duplicate member %r: which "
                                      "entry wins is consumer-dependent" % name)
            seen.add(name)
            if name.startswith("/") or any(
                    part in ("", ".", "..") for part in name.split("/")):
                raise InspectionError("refusing unsafe member path %r" % name)
            if not (info.isdir() or info.isreg()):
                raise InspectionError("refusing member %r of tar type %r"
                                      % (name, info.type))
            target = os.path.realpath(os.path.join(real_root, name))
            if target != real_root and not target.startswith(real_root + os.sep):
                raise InspectionError("refusing member %r that escapes the "
                                      "destination" % name)
            if info.isdir():
                os.makedirs(target, exist_ok=True)
                dir_modes.append((target, mp_oci.DIR_MODE))
            else:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                handle = tar.extractfile(info)
                if handle is None:
                    raise InspectionError("member %r has no content" % name)
                with open(target, "wb") as out:
                    while True:
                        chunk = handle.read(mp_oci.READ_CHUNK)
                        if not chunk:
                            break
                        out.write(chunk)
                os.chmod(target, mp_oci.FILE_MODE)
    finally:
        tar.close()
    for path, mode in dir_modes:
        os.chmod(path, mode)
    return destination


def inventory_directory(root):
    """Path -> (kind, size, sha256, mode) for every entry under root."""
    inventory = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        for name in dirnames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            inventory[rel] = ("dir", 0, None,
                              stat.S_IMODE(os.lstat(full).st_mode))
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            st = os.lstat(full)
            if not stat.S_ISREG(st.st_mode):
                inventory[rel] = ("other", 0, None, stat.S_IMODE(st.st_mode))
                continue
            inventory[rel] = ("file", st.st_size, sha256_file(full),
                              stat.S_IMODE(st.st_mode))
    return inventory


def inventory_plan(entries):
    """The same shape as inventory_directory, computed from the pack plan."""
    inventory = {}
    for arcname, kind, source_path in entries:
        if kind == "dir":
            inventory[arcname] = ("dir", 0, None, mp_oci.DIR_MODE)
        else:
            inventory[arcname] = ("file", os.path.getsize(source_path),
                                  sha256_file(source_path), mp_oci.FILE_MODE)
    return inventory


def compare_inventories(source, unpacked):
    """Both directions. Returns a list of human-readable differences."""
    differences = []
    for path in sorted(set(source) - set(unpacked)):
        differences.append("missing from unpacked tree: %s" % path)
    for path in sorted(set(unpacked) - set(source)):
        differences.append("unexpected in unpacked tree: %s" % path)
    for path in sorted(set(source) & set(unpacked)):
        s_kind, s_size, s_hash, s_mode = source[path]
        u_kind, u_size, u_hash, u_mode = unpacked[path]
        if s_kind != u_kind:
            differences.append("%s: type %s != %s" % (path, s_kind, u_kind))
            continue
        if s_kind == "file":
            if s_size != u_size:
                differences.append("%s: size %d != %d" % (path, s_size, u_size))
            if s_hash != u_hash:
                differences.append("%s: sha256 %s != %s"
                                   % (path, s_hash, u_hash))
        if s_mode != u_mode:
            differences.append("%s: mode %04o != %04o" % (path, s_mode, u_mode))
    return differences
