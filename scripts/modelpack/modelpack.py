#!/usr/bin/env python3
"""ModelPack producer, validator and inspector for compiled DRP-AI models.

Standard library only. No registry, no network, no signing key and no BitBake:
this stage builds and proves a deterministic artifact, and signing consumes the
resulting manifest digest later.

  modelpack.py validate  --config C
  modelpack.py pack      --config C --model-dir D --labels F --output LAYOUT
  modelpack.py inspect   --layout LAYOUT
  modelpack.py roundtrip --layout LAYOUT --model-dir D --labels F

Exit status is 0 on success, 1 when a check fails, and 2 on a usage or I/O
error.
"""

import argparse
import json
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mp_inspect  # noqa: E402
import mp_oci  # noqa: E402
import mp_schema  # noqa: E402

RFC3339_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2


def _load_json(path):
    with open(path, "rb") as handle:
        return json.loads(handle.read())


def _report(problems, what):
    if problems:
        print("%s: %d problem(s)" % (what, len(problems)), file=sys.stderr)
        for problem in problems:
            print("  - %s" % problem, file=sys.stderr)
        return EXIT_FAILED
    print("%s: OK" % what)
    return EXIT_OK


def _plan_from_config(config, model_dir, labels_file):
    # The archive layout the config promises: model.directory is a directory
    # and labels.path is a regular file. Packing a directory as the label file
    # would produce an artifact the inspector then has to reject.
    if not os.path.isdir(model_dir):
        raise mp_oci.PackError("--model-dir is not a directory: %s" % model_dir)
    if os.path.isdir(labels_file) or not os.path.isfile(labels_file):
        raise mp_oci.PackError("--labels is not a regular file: %s" % labels_file)
    return mp_oci.collect_entries([
        (config["model"]["directory"], model_dir),
        (config["labels"]["path"], labels_file),
    ])


def cmd_validate(args):
    config = _load_json(args.config)
    return _report(mp_schema.validate_config(config), "config %s" % args.config)


def cmd_pack(args):
    config = _load_json(args.config)
    problems = mp_schema.validate_config(config)
    if problems:
        return _report(problems, "config %s" % args.config)

    if not RFC3339_RE.match(args.created):
        print("--created must be RFC 3339 UTC (YYYY-MM-DDTHH:MM:SSZ), got %r"
              % args.created, file=sys.stderr)
        return EXIT_USAGE

    if os.path.exists(args.output) and os.listdir(args.output):
        print("--output %s exists and is not empty" % args.output,
              file=sys.stderr)
        return EXIT_USAGE

    entries = _plan_from_config(config, args.model_dir, args.labels)
    os.makedirs(os.path.join(args.output, "blobs", "sha256"), exist_ok=True)

    handle, staged = tempfile.mkstemp(prefix=".layer-", dir=args.output)
    os.close(handle)
    try:
        layer_digest, layer_size = mp_oci.write_layer(entries, staged)
        manifest_desc = mp_oci.write_layout(
            args.output, config, staged, layer_digest, layer_size,
            "%s-%s.tar.gz" % (config["name"], config["version"]),
            created=args.created)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)

    print(json.dumps({
        "layout": os.path.abspath(args.output),
        "name": config["name"],
        "version": config["version"],
        "decoder": config["decoder"]["class"],
        "entries": len(entries),
        "layerDigest": "sha256:" + layer_digest,
        "layerSize": layer_size,
        "configDigest": "sha256:" + mp_oci.sha256_bytes(
            mp_oci.canonical_json(config)),
        "manifestDigest": manifest_desc["digest"],
        "manifestSize": manifest_desc["size"],
    }, indent=2, sort_keys=True))
    return EXIT_OK


def cmd_inspect(args):
    summary, problems = mp_inspect.inspect_layout(args.layout)
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        for key in sorted(summary):
            print("%-16s %s" % (key, summary[key]))
    return _report(problems, "layout %s" % args.layout)


def cmd_roundtrip(args):
    summary, problems = mp_inspect.inspect_layout(args.layout)
    if problems:
        return _report(problems, "layout %s" % args.layout)

    index = _load_json(os.path.join(args.layout, "index.json"))
    manifest = json.loads(mp_oci.read_blob(
        args.layout, index["manifests"][0]["digest"]))
    config = json.loads(mp_oci.read_blob(args.layout, manifest["config"]["digest"]))

    entries = _plan_from_config(config, args.model_dir, args.labels)
    source = mp_inspect.inventory_plan(entries)

    destination = args.extract_to
    temporary = destination is None
    if temporary:
        destination = tempfile.mkdtemp(prefix="modelpack-unpack-")
    try:
        mp_inspect.safe_extract(args.layout, manifest["layers"][0]["digest"],
                                destination)
        unpacked = mp_inspect.inventory_directory(destination)
        differences = mp_inspect.compare_inventories(source, unpacked)
        print("source entries   %d" % len(source))
        print("unpacked entries %d" % len(unpacked))
        print("differences      %d" % len(differences))
        return _report(differences, "round trip %s" % args.layout)
    finally:
        if temporary:
            _rmtree(destination)


def _rmtree(path):
    shutil.rmtree(path, ignore_errors=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_validate = sub.add_parser("validate", help="validate a config against the "
                                                 "frozen schema")
    p_validate.add_argument("--config", required=True)
    p_validate.set_defaults(func=cmd_validate)

    p_pack = sub.add_parser("pack", help="build a deterministic OCI image layout")
    p_pack.add_argument("--config", required=True)
    p_pack.add_argument("--model-dir", required=True,
                        help="compiled DRP-AI model directory")
    p_pack.add_argument("--labels", required=True, help="label file")
    p_pack.add_argument("--output", required=True, help="layout directory")
    p_pack.add_argument("--created", default=mp_oci.EPOCH_RFC3339,
                        help="pinned org.opencontainers.image.created value")
    p_pack.set_defaults(func=cmd_pack)

    p_inspect = sub.add_parser("inspect", help="verify a layout without "
                                               "trusting its own metadata")
    p_inspect.add_argument("--layout", required=True)
    p_inspect.add_argument("--json", action="store_true")
    p_inspect.set_defaults(func=cmd_inspect)

    p_round = sub.add_parser("roundtrip", help="compare source and unpacked "
                                               "trees in both directions")
    p_round.add_argument("--layout", required=True)
    p_round.add_argument("--model-dir", required=True)
    p_round.add_argument("--labels", required=True)
    p_round.add_argument("--extract-to", default=None)
    p_round.set_defaults(func=cmd_roundtrip)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (mp_oci.PackError, mp_inspect.InspectionError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return EXIT_FAILED
    except (OSError, ValueError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
