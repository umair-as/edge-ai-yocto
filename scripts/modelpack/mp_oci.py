"""Deterministic ModelPack packaging: archive, descriptors, OCI image layout.

Identical inputs produce byte-identical blobs and an identical descriptor
graph. The model's identity is its digest, so a wall-clock time, host ownership,
absolute path or source mtime reaching the output would change the identity of
an otherwise unchanged model.
"""

import gzip
import hashlib
import io
import json
import os
import stat
import tarfile

from mp_schema import (ARTIFACT_TYPE, CONFIG_MEDIA_TYPE, CREATED_ANNOTATION,
                       INDEX_MEDIA_TYPE, MANIFEST_MEDIA_TYPE,
                       REF_NAME_ANNOTATION, TITLE_ANNOTATION,
                       WEIGHT_LAYER_MEDIA_TYPE, ACCELERATOR_ANNOTATION)

# Constant archive metadata. Not the current values on disk, per the ModelPack
# reproducibility guidance.
FIXED_MTIME = 0
FIXED_UID = 0
FIXED_GID = 0
FILE_MODE = 0o644
DIR_MODE = 0o755
GZIP_LEVEL = 9

EPOCH_RFC3339 = "1970-01-01T00:00:00Z"
IMAGE_LAYOUT_VERSION = "1.0.0"
READ_CHUNK = 1024 * 1024


class PackError(Exception):
    pass


def canonical_json(obj):
    """Sorted keys, no whitespace, no trailing newline. Digested as-is.

    allow_nan is off: Python's default emits the JavaScript literals NaN,
    Infinity and -Infinity, which are not JSON and which a conforming consumer
    refuses after the digest has already been taken over them.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def descriptor(media_type, digest_hex, size, annotations=None):
    desc = {"mediaType": media_type, "digest": "sha256:" + digest_hex,
            "size": size}
    if annotations:
        desc["annotations"] = annotations
    return desc


def collect_entries(sources):
    """Build the archive plan from (arc_prefix, source_path) pairs.

    Returns a sorted list of (arcname, kind, source_path) where kind is
    "dir" or "file"; a synthesized ancestor directory carries source_path None.
    Anything that is not a regular file or directory is an
    error: symlinks are rejected rather than followed, so a source tree cannot
    pull in content from outside itself, and device nodes, FIFOs and sockets
    have no representation a model store should be asked to recreate.
    """
    entries = {}

    def add(arcname, kind, source_path):
        if arcname in entries:
            raise PackError("duplicate archive path %r" % arcname)
        entries[arcname] = (arcname, kind, source_path)

    for arc_prefix, source_path in sources:
        st = os.lstat(source_path)
        if stat.S_ISLNK(st.st_mode):
            raise PackError("symlink is not packable: %s" % source_path)
        if stat.S_ISREG(st.st_mode):
            add(arc_prefix, "file", source_path)
            continue
        if not stat.S_ISDIR(st.st_mode):
            raise PackError("unsupported file type (not a regular file or "
                            "directory): %s" % source_path)
        add(arc_prefix, "dir", source_path)
        for root, dirnames, filenames in os.walk(source_path):
            dirnames.sort()
            filenames.sort()
            rel_root = os.path.relpath(root, source_path)
            base = arc_prefix if rel_root == "." else "/".join(
                [arc_prefix] + rel_root.split(os.sep))
            for name in dirnames + filenames:
                full = os.path.join(root, name)
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    raise PackError("symlink is not packable: %s" % full)
                if stat.S_ISDIR(st.st_mode):
                    add(base + "/" + name, "dir", full)
                elif stat.S_ISREG(st.st_mode):
                    add(base + "/" + name, "file", full)
                else:
                    raise PackError("unsupported file type (not a regular file "
                                    "or directory): %s" % full)

    for arcname in entries:
        for part in arcname.split("/"):
            if part in ("", ".", ".."):
                raise PackError("unsafe archive path %r" % arcname)

    # Emit every ancestor directory explicitly. A tar that names
    # labels/tiny.txt without a labels/ entry leaves the directory's existence
    # and mode to whatever the extractor does, which the round-trip comparison
    # would then see as an entry the source tree does not have.
    for arcname in list(entries):
        parts = arcname.split("/")
        for depth in range(1, len(parts)):
            ancestor = "/".join(parts[:depth])
            if ancestor not in entries:
                entries[ancestor] = (ancestor, "dir", None)

    return [entries[key] for key in sorted(entries)]


def write_layer(entries, out_path):
    """Write the deterministic tar+gzip layer. Returns (digest_hex, size)."""
    with open(out_path, "wb") as raw:
        # mtime=0 and an empty filename keep the gzip header constant.
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                           compresslevel=GZIP_LEVEL, mtime=FIXED_MTIME) as gz:
            with tarfile.open(fileobj=gz, mode="w",
                              format=tarfile.GNU_FORMAT) as tar:
                for arcname, kind, source_path in entries:
                    info = tarfile.TarInfo(arcname)
                    info.uid = FIXED_UID
                    info.gid = FIXED_GID
                    info.uname = ""
                    info.gname = ""
                    info.mtime = FIXED_MTIME
                    if kind == "dir":
                        info.type = tarfile.DIRTYPE
                        info.mode = DIR_MODE
                        info.size = 0
                        tar.addfile(info)
                    else:
                        info.type = tarfile.REGTYPE
                        info.mode = FILE_MODE
                        info.size = os.path.getsize(source_path)
                        with open(source_path, "rb") as handle:
                            tar.addfile(info, handle)
    return sha256_file(out_path), os.path.getsize(out_path)


def build_manifest(config_desc, layer_descs, annotations):
    return {
        "schemaVersion": 2,
        "mediaType": MANIFEST_MEDIA_TYPE,
        "artifactType": ARTIFACT_TYPE,
        "config": config_desc,
        "layers": layer_descs,
        "annotations": annotations,
    }


def build_index(manifest_desc):
    return {
        "schemaVersion": 2,
        "mediaType": INDEX_MEDIA_TYPE,
        "manifests": [manifest_desc],
    }


def _blob_path(layout_dir, digest_hex):
    return os.path.join(layout_dir, "blobs", "sha256", digest_hex)


def write_layout(layout_dir, config, layer_source_path, layer_digest,
                 layer_size, layer_title, created=EPOCH_RFC3339):
    """Write oci-layout, blobs and index.json. Returns the manifest descriptor."""
    os.makedirs(os.path.join(layout_dir, "blobs", "sha256"), exist_ok=True)

    config_bytes = canonical_json(config)
    config_digest = sha256_bytes(config_bytes)
    with open(_blob_path(layout_dir, config_digest), "wb") as handle:
        handle.write(config_bytes)

    layer_blob = _blob_path(layout_dir, layer_digest)
    if os.path.abspath(layer_source_path) != os.path.abspath(layer_blob):
        os.replace(layer_source_path, layer_blob)

    config_desc = descriptor(CONFIG_MEDIA_TYPE, config_digest, len(config_bytes))
    layer_desc = descriptor(WEIGHT_LAYER_MEDIA_TYPE, layer_digest, layer_size,
                            {TITLE_ANNOTATION: layer_title})
    manifest = build_manifest(
        config_desc, [layer_desc],
        {CREATED_ANNOTATION: created,
         ACCELERATOR_ANNOTATION: config["accelerator"]})

    manifest_bytes = canonical_json(manifest)
    manifest_digest = sha256_bytes(manifest_bytes)
    with open(_blob_path(layout_dir, manifest_digest), "wb") as handle:
        handle.write(manifest_bytes)

    ref_name = "%s:%s" % (config["name"], config["version"])
    manifest_desc = descriptor(
        MANIFEST_MEDIA_TYPE, manifest_digest, len(manifest_bytes),
        {REF_NAME_ANNOTATION: ref_name})
    manifest_desc["artifactType"] = ARTIFACT_TYPE

    with open(os.path.join(layout_dir, "index.json"), "wb") as handle:
        handle.write(canonical_json(build_index(manifest_desc)))
    with open(os.path.join(layout_dir, "oci-layout"), "wb") as handle:
        handle.write(canonical_json(
            {"imageLayoutVersion": IMAGE_LAYOUT_VERSION}))

    return manifest_desc


def read_blob(layout_dir, digest):
    """Read a blob by its 'sha256:<hex>' descriptor digest."""
    algorithm, _, hex_digest = digest.partition(":")
    if algorithm != "sha256" or not hex_digest:
        raise PackError("unsupported digest %r" % digest)
    with open(_blob_path(layout_dir, hex_digest), "rb") as handle:
        return handle.read()


def open_layer_tar(layout_dir, digest):
    algorithm, _, hex_digest = digest.partition(":")
    if algorithm != "sha256":
        raise PackError("unsupported digest %r" % digest)
    with open(_blob_path(layout_dir, hex_digest), "rb") as handle:
        fileobj = io.BytesIO(handle.read())
    return tarfile.open(fileobj=gzip.GzipFile(fileobj=fileobj, mode="rb"),
                        mode="r|")
