#!/usr/bin/env python3
"""Host tests for the ModelPack producer, validator and inspector.

Standard library only; no compiled model, no network, no registry. Fixtures are
deliberately tiny synthetic trees so the whole suite runs in seconds, and every
assertion compares an output rather than an exit status alone.

    python3 scripts/modelpack/tests/test_modelpack.py
"""

import contextlib
import copy
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import mp_inspect  # noqa: E402
import mp_oci  # noqa: E402
import mp_schema  # noqa: E402
import modelpack  # noqa: E402

CLASSIFICATION_CONFIG = {
    "schemaVersion": "1.0",
    "name": "tiny-classifier",
    "version": "1",
    "accelerator": "drpai-v2l",
    "model": {"directory": "model"},
    "labels": {"path": "labels/tiny.txt", "count": 4},
    "decoder": {"class": "classification", "topK": 2},
}

DETECTION_CONFIG = {
    "schemaVersion": "1.0",
    "name": "tiny-detector",
    "version": "1",
    "accelerator": "drpai-v2l",
    "model": {"directory": "model"},
    "labels": {"path": "labels/tiny.txt", "count": 4},
    "decoder": {"class": "detection", "scoreThreshold": 0.25,
                "iouThreshold": 0.45, "maxDetections": 300},
}

SEGMENTATION_CONFIG = {
    "schemaVersion": "1.0",
    "name": "tiny-segmenter",
    "version": "1",
    "accelerator": "drpai-v2l",
    "model": {"directory": "model"},
    "labels": {"path": "labels/tiny.txt", "count": 4},
    "decoder": {"class": "segmentation"},
}

# TVM graph shape: entry 1 is the output, four elements, matching four labels.
DEPLOY_JSON = {
    "nodes": [{"op": "null", "name": "data", "inputs": []},
              {"op": "tvm_op", "name": "out", "inputs": [[0, 0, 0]]}],
    "arg_nodes": [0],
    "heads": [[1, 0, 0]],
    "attrs": {
        "dltype": ["list_str", ["float32", "float32"]],
        "device_index": ["list_int", [1, 1]],
        "storage_id": ["list_int", [0, 1]],
        "shape": ["list_shape", [[1, 3, 8, 8], [1, 4]]],
    },
    "node_row_ptr": [0, 1, 2],
}

LABELS_TEXT = "alpha\nbravo\ncharlie\ndelta\n"


def make_model_dir(root, deploy=None):
    """A synthetic stand-in with the same entry names as a compiled tree."""
    model = os.path.join(root, "compiled")
    os.makedirs(os.path.join(model, "preprocess"))
    with open(os.path.join(model, "deploy.json"), "w") as handle:
        json.dump(deploy if deploy is not None else DEPLOY_JSON, handle)
    with open(os.path.join(model, "deploy.params"), "wb") as handle:
        handle.write(b"\x00params\x00" * 8)
    with open(os.path.join(model, "deploy.so"), "wb") as handle:
        handle.write(b"\x7fELF-not-really" * 4)
    with open(os.path.join(model, "preprocess", "pp_drpcfg.mem"), "wb") as handle:
        handle.write(b"\x01\x02\x03\x04" * 16)
    with open(os.path.join(model, "preprocess", "drp_param_info.txt"), "w") as f:
        f.write("synthetic\n")
    return model


def make_labels(root, text=LABELS_TEXT):
    path = os.path.join(root, "labels.txt")
    with open(path, "w") as handle:
        handle.write(text)
    return path


def read_json(path):
    with open(path, "rb") as handle:
        return json.loads(handle.read())


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def write_config(root, config, name="config.json"):
    path = os.path.join(root, name)
    with open(path, "w") as handle:
        json.dump(config, handle)
    return path


class TempCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="modelpack-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def work(self, name):
        path = os.path.join(self.tmp, name)
        os.makedirs(path, exist_ok=True)
        return path

    def pack(self, config, model_dir, labels, out_name="layout", created=None):
        out = os.path.join(self.tmp, out_name)
        argv = ["pack", "--config", write_config(self.work("cfg-" + out_name),
                                                 config),
                "--model-dir", model_dir, "--labels", labels, "--output", out]
        if created:
            argv += ["--created", created]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(modelpack.main(argv), 0)
        return out

    def manifest_of(self, layout):
        index = read_json(os.path.join(layout, "index.json"))
        digest = index["manifests"][0]["digest"]
        return digest, json.loads(mp_oci.read_blob(layout, digest))


class SchemaPositive(TempCase):
    def test_all_three_classes_validate(self):
        for config in (CLASSIFICATION_CONFIG, DETECTION_CONFIG,
                       SEGMENTATION_CONFIG):
            self.assertEqual(mp_schema.validate_config(config), [],
                             "%s should validate" % config["name"])

    def test_shipped_example_configs_validate(self):
        configs = os.path.join(os.path.dirname(HERE), "configs")
        found = sorted(f for f in os.listdir(configs) if f.endswith(".json"))
        self.assertEqual(len(found), 3, "expected one example per decoder class")
        for name in found:
            with open(os.path.join(configs, name), "rb") as handle:
                self.assertEqual(
                    mp_schema.validate_config(json.loads(handle.read())), [],
                    "%s should validate" % name)

    def test_compatibility_rule(self):
        self.assertTrue(mp_schema.schema_version_accepted("1.0", "1.0"))
        self.assertTrue(mp_schema.schema_version_accepted("1.0", "1.3"))
        self.assertFalse(mp_schema.schema_version_accepted("1.4", "1.0"))
        self.assertFalse(mp_schema.schema_version_accepted("2.0", "1.0"))
        self.assertFalse(mp_schema.schema_version_accepted("banana", "1.0"))


class SchemaNegative(TempCase):
    def assert_rejected(self, config, needle):
        errors = mp_schema.validate_config(config)
        self.assertTrue(errors, "expected rejection, got none")
        joined = " | ".join(errors)
        self.assertIn(needle, joined,
                      "expected %r in errors, got: %s" % (needle, joined))
        return errors

    def test_unsupported_schema_version(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["schemaVersion"] = "2.0"
        self.assert_rejected(config, "unsupported version")

    def test_unsupported_accelerator(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["accelerator"] = "drpai-v2m"
        self.assert_rejected(config, "accelerator")

    def test_unknown_top_level_key(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["batchSize"] = 4
        self.assert_rejected(config, "unknown field")

    def test_unknown_decoder_key(self):
        config = copy.deepcopy(DETECTION_CONFIG)
        config["decoder"]["softNms"] = True
        self.assert_rejected(config, "decoder.softNms: unknown field")

    def test_unsupported_decoder_class(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["decoder"] = {"class": "pose"}
        self.assert_rejected(config, "decoder.class")

    def test_forbidden_preprocessing_fields(self):
        for key in ("inputShape", "resize", "mean", "std", "normalize",
                    "colorOrder", "preprocess", "layout"):
            config = copy.deepcopy(CLASSIFICATION_CONFIG)
            config[key] = "anything"
            errors = self.assert_rejected(config, "forbidden")
            self.assertIn("preprocess/", " ".join(errors),
                          "diagnostic should name the authoritative artifact")

    def test_forbidden_field_nested_in_decoder(self):
        config = copy.deepcopy(DETECTION_CONFIG)
        config["decoder"]["inputShape"] = [1, 3, 640, 640]
        self.assert_rejected(config, "forbidden")

    def test_missing_labels(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        del config["labels"]
        self.assert_rejected(config, "labels: is required")

    def test_malformed_labels_path(self):
        for bad in ("/etc/passwd", "../escape.txt", "labels//tiny.txt",
                    "labels/../../tiny.txt", "labels\\tiny.txt", ""):
            config = copy.deepcopy(CLASSIFICATION_CONFIG)
            config["labels"] = {"path": bad, "count": 4}
            self.assert_rejected(config, "labels.path")

    def test_labels_count_bounds(self):
        for bad in (0, -1, True, "4", 1000001):
            config = copy.deepcopy(CLASSIFICATION_CONFIG)
            config["labels"] = {"path": "labels/tiny.txt", "count": bad}
            self.assert_rejected(config, "labels.count")

    def test_detection_missing_parameters(self):
        for key in ("scoreThreshold", "iouThreshold", "maxDetections"):
            config = copy.deepcopy(DETECTION_CONFIG)
            del config["decoder"][key]
            self.assert_rejected(config, "decoder.%s: is required" % key)

    def test_detection_parameter_ranges(self):
        cases = [("scoreThreshold", -0.01), ("scoreThreshold", 1.01),
                 ("iouThreshold", 0.0), ("iouThreshold", 1.5),
                 ("maxDetections", 0), ("maxDetections", 10001)]
        for key, value in cases:
            config = copy.deepcopy(DETECTION_CONFIG)
            config["decoder"][key] = value
            self.assert_rejected(config, "decoder.%s" % key)

    def test_topk_cannot_exceed_labels(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["decoder"]["topK"] = 5
        self.assert_rejected(config, "must not exceed labels.count")

    def test_segmentation_takes_no_parameters(self):
        config = copy.deepcopy(SEGMENTATION_CONFIG)
        config["decoder"]["scoreThreshold"] = 0.5
        self.assert_rejected(config, "decoder.scoreThreshold: unknown field")

    def test_model_directory_required(self):
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["model"] = {}
        self.assert_rejected(config, "model.directory: is required")

    def test_name_charset(self):
        for bad in ("Tiny", "tiny_model", "-tiny", "tiny-", "a" * 64):
            config = copy.deepcopy(CLASSIFICATION_CONFIG)
            config["name"] = bad
            self.assert_rejected(config, "name")


class ProducerDeterminism(TempCase):
    def test_two_independent_source_copies_agree(self):
        """Different inode order, mtimes and modes must not reach the output."""
        first = self.work("src-a")
        model_a = make_model_dir(first)
        labels_a = make_labels(first)

        second = self.work("src-b")
        model_b = os.path.join(second, "compiled")
        shutil.copytree(model_a, model_b)
        labels_b = make_labels(second)

        # Perturb everything the archive must not carry.
        for root, dirnames, filenames in os.walk(model_b):
            for name in dirnames + filenames:
                path = os.path.join(root, name)
                os.utime(path, (1234567890, 1234567890))
                os.chmod(path, 0o700 if os.path.isdir(path) else 0o600)
        os.utime(labels_b, (987654321, 987654321))
        os.chmod(labels_b, 0o600)

        layout_a = self.pack(CLASSIFICATION_CONFIG, model_a, labels_a, "a")
        layout_b = self.pack(CLASSIFICATION_CONFIG, model_b, labels_b, "b")

        digest_a, manifest_a = self.manifest_of(layout_a)
        digest_b, manifest_b = self.manifest_of(layout_b)
        self.assertEqual(digest_a, digest_b, "manifest digests must agree")
        self.assertEqual(manifest_a, manifest_b)
        self.assertEqual(manifest_a["layers"][0]["digest"],
                         manifest_b["layers"][0]["digest"])
        self.assertEqual(manifest_a["config"]["digest"],
                         manifest_b["config"]["digest"])

        for name in ("index.json", "oci-layout"):
            self.assertEqual(read_bytes(os.path.join(layout_a, name)),
                             read_bytes(os.path.join(layout_b, name)),
                             "%s must be byte-identical" % name)

    def test_created_annotation_is_pinned_not_wall_clock(self):
        root = self.work("src")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "pinned")
        _, manifest = self.manifest_of(layout)
        self.assertEqual(manifest["annotations"][mp_schema.CREATED_ANNOTATION],
                         mp_oci.EPOCH_RFC3339)

    def test_created_must_be_rfc3339(self):
        root = self.work("src")
        argv = ["pack", "--config", write_config(root, CLASSIFICATION_CONFIG),
                "--model-dir", make_model_dir(root), "--labels",
                make_labels(root), "--output", os.path.join(self.tmp, "bad"),
                "--created", "yesterday"]
        self.assertEqual(modelpack.main(argv), modelpack.EXIT_USAGE)

    def test_archive_metadata_is_constant(self):
        root = self.work("src")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "meta")
        _, manifest = self.manifest_of(layout)
        members, _, duplicates = mp_inspect._layer_members(
            layout, manifest["layers"][0]["digest"])
        self.assertEqual(duplicates, [])
        self.assertTrue(members)
        for name, meta in members.items():
            self.assertEqual(meta["mtime"], 0, name)
            self.assertEqual(meta["uid"], 0, name)
            self.assertEqual(meta["gid"], 0, name)
            self.assertEqual(meta["uname"], "", name)
            self.assertEqual(meta["gname"], "", name)
            expected = mp_oci.DIR_MODE if meta["kind"] == "dir" else mp_oci.FILE_MODE
            self.assertEqual(meta["mode"], expected, name)

    def test_paths_are_sorted(self):
        root = self.work("src")
        entries = mp_oci.collect_entries([("model", make_model_dir(root)),
                                          ("labels/tiny.txt", make_labels(root))])
        names = [entry[0] for entry in entries]
        self.assertEqual(names, sorted(names))


class ProducerRejections(TempCase):
    def test_symlink_is_rejected(self):
        root = self.work("src")
        model = make_model_dir(root)
        os.symlink("deploy.params", os.path.join(model, "alias.params"))
        with self.assertRaises(mp_oci.PackError) as caught:
            mp_oci.collect_entries([("model", model)])
        self.assertIn("symlink", str(caught.exception))

    def test_symlink_to_outside_is_rejected_not_followed(self):
        root = self.work("src")
        model = make_model_dir(root)
        secret = os.path.join(root, "outside.txt")
        with open(secret, "w") as handle:
            handle.write("must not be packed")
        os.symlink(secret, os.path.join(model, "leak.txt"))
        with self.assertRaises(mp_oci.PackError):
            mp_oci.collect_entries([("model", model)])

    def test_fifo_is_rejected(self):
        root = self.work("src")
        model = make_model_dir(root)
        os.mkfifo(os.path.join(model, "pipe"))
        with self.assertRaises(mp_oci.PackError) as caught:
            mp_oci.collect_entries([("model", model)])
        self.assertIn("unsupported file type", str(caught.exception))

    def test_unsafe_arcname_is_rejected(self):
        root = self.work("src")
        with self.assertRaises(mp_oci.PackError):
            mp_oci.collect_entries([("../escape", make_model_dir(root))])

    def test_pack_refuses_nonempty_output(self):
        root = self.work("src")
        out = self.work("occupied")
        with open(os.path.join(out, "stray"), "w") as handle:
            handle.write("x")
        argv = ["pack", "--config", write_config(root, CLASSIFICATION_CONFIG),
                "--model-dir", make_model_dir(root), "--labels",
                make_labels(root), "--output", out]
        self.assertEqual(modelpack.main(argv), modelpack.EXIT_USAGE)


class InspectorPositive(TempCase):
    def test_clean_layout_has_no_problems(self):
        root = self.work("src")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "clean")
        summary, problems = mp_inspect.inspect_layout(layout)
        self.assertEqual(problems, [])
        self.assertEqual(summary["decoder"], "classification")
        self.assertEqual(summary["labelLines"], 4)
        self.assertEqual(summary["outputShape"], [1, 4])

    def test_layout_structure_matches_the_spec(self):
        root = self.work("src")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "structure")
        marker = read_json(os.path.join(layout, "oci-layout"))
        self.assertEqual(marker, {"imageLayoutVersion": "1.0.0"})
        index = read_json(os.path.join(layout, "index.json"))
        self.assertEqual(len(index["manifests"]), 1)
        self.assertEqual(index["manifests"][0]["annotations"][
            mp_schema.REF_NAME_ANNOTATION], "tiny-classifier:1")
        _, manifest = self.manifest_of(layout)
        self.assertEqual(manifest["artifactType"], mp_schema.ARTIFACT_TYPE)
        self.assertEqual(manifest["mediaType"], mp_schema.MANIFEST_MEDIA_TYPE)
        self.assertEqual(manifest["config"]["mediaType"],
                         mp_schema.CONFIG_MEDIA_TYPE)
        self.assertEqual(manifest["layers"][0]["mediaType"],
                         mp_schema.WEIGHT_LAYER_MEDIA_TYPE)
        blobs = os.listdir(os.path.join(layout, "blobs", "sha256"))
        self.assertEqual(len(blobs), 3, "config, layer and manifest")
        for name in blobs:
            path = os.path.join(layout, "blobs", "sha256", name)
            self.assertEqual(mp_oci.sha256_file(path), name,
                             "blob name must equal its content digest")


class InspectorTampering(TempCase):
    def setUp(self):
        super(InspectorTampering, self).setUp()
        root = self.work("src")
        self.layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                                make_labels(root), "target")
        self.index_path = os.path.join(self.layout, "index.json")

    def blob(self, digest):
        return os.path.join(self.layout, "blobs", "sha256",
                            digest.split(":", 1)[1])

    def rewrite_manifest(self, mutate):
        """Rewrite the manifest blob in place and repoint index.json at it."""
        digest, manifest = self.manifest_of(self.layout)
        mutate(manifest)
        self.rewrite_manifest_blob(digest, manifest)

    def rewrite_layer(self, raw_bytes):
        """Replace the layer blob and cascade the digest change through the
        manifest's layer descriptor, the manifest blob itself, and
        index.json -- everything a real re-pack would also have to update.
        """
        digest, manifest = self.manifest_of(self.layout)
        new_layer_digest = mp_oci.sha256_bytes(raw_bytes)
        with open(self.blob("sha256:" + new_layer_digest), "wb") as handle:
            handle.write(raw_bytes)
        os.unlink(self.blob(manifest["layers"][0]["digest"]))
        manifest["layers"][0]["digest"] = "sha256:" + new_layer_digest
        manifest["layers"][0]["size"] = len(raw_bytes)
        self.rewrite_manifest_blob(digest, manifest)

    def rewrite_manifest_blob(self, old_digest, manifest):
        """Write `manifest` as the new manifest blob and repoint index.json."""
        raw = mp_oci.canonical_json(manifest)
        new_digest = mp_oci.sha256_bytes(raw)
        with open(self.blob("sha256:" + new_digest), "wb") as handle:
            handle.write(raw)
        os.unlink(self.blob(old_digest))
        index = read_json(self.index_path)
        index["manifests"][0]["digest"] = "sha256:" + new_digest
        index["manifests"][0]["size"] = len(raw)
        with open(self.index_path, "wb") as handle:
            handle.write(mp_oci.canonical_json(index))

    def assert_problem(self, needle):
        _, problems = mp_inspect.inspect_layout(self.layout)
        joined = " | ".join(problems)
        self.assertIn(needle, joined, "expected %r, got: %s" % (needle, joined))

    def test_layer_content_tampering(self):
        _, manifest = self.manifest_of(self.layout)
        path = self.blob(manifest["layers"][0]["digest"])
        with open(path, "ab") as handle:
            handle.write(b"\x00")
        self.assert_problem("does not match its own name")

    def test_config_content_tampering(self):
        _, manifest = self.manifest_of(self.layout)
        path = self.blob(manifest["config"]["digest"])
        data = read_json(path)
        data["decoder"]["topK"] = 1
        with open(path, "wb") as handle:
            handle.write(mp_oci.canonical_json(data))
        self.assert_problem("does not match its own name")

    def test_unparseable_config_content_reports_not_crashes(self):
        """A tampered blob that is not even valid JSON must not be parsed.

        test_config_content_tampering above replaces the config blob's bytes
        with something still valid JSON, so it cannot distinguish "the
        mismatch was reported and the blob was never parsed" from "the
        mismatch was reported but the blob was parsed anyway" -- both leave
        the same problem message and no crash, because there is nothing
        there to crash on. Garbage bytes are not valid JSON; only the fixed
        behaviour survives them.
        """
        _, manifest = self.manifest_of(self.layout)
        path = self.blob(manifest["config"]["digest"])
        with open(path, "wb") as handle:
            handle.write(b"\x00not json at all\xff")
        summary, problems = mp_inspect.inspect_layout(self.layout)
        joined = " | ".join(problems)
        self.assertIn("does not match its own name", joined)
        self.assertNotIn("name", summary)
        self.assertEqual(
            modelpack.main(["inspect", "--layout", self.layout]),
            modelpack.EXIT_FAILED,
            "a tampered artifact must exit EXIT_FAILED (a check failed), "
            "not EXIT_USAGE (a usage/I/O error) -- the latter reads as an "
            "operator mistake instead of a security finding")

    def test_manifest_descriptor_size_tampering(self):
        index = read_json(self.index_path)
        index["manifests"][0]["size"] += 1
        with open(self.index_path, "wb") as handle:
            handle.write(mp_oci.canonical_json(index))
        self.assert_problem("size mismatch")

    def test_layer_descriptor_size_tampering(self):
        self.rewrite_manifest(
            lambda m: m["layers"][0].__setitem__("size", m["layers"][0]["size"] + 1))
        self.assert_problem("size mismatch")

    def test_config_descriptor_size_tampering(self):
        self.rewrite_manifest(
            lambda m: m["config"].__setitem__("size", m["config"]["size"] - 1))
        self.assert_problem("size mismatch")

    def test_layer_media_type_tampering(self):
        self.rewrite_manifest(lambda m: m["layers"][0].__setitem__(
            "mediaType", "application/vnd.oci.image.layer.v1.tar+gzip"))
        self.assert_problem("mediaType must be")

    def test_artifact_type_tampering(self):
        self.rewrite_manifest(
            lambda m: m.__setitem__("artifactType", "application/octet-stream"))
        self.assert_problem("artifactType must be")

    def test_accelerator_annotation_must_match_config(self):
        self.rewrite_manifest(lambda m: m["annotations"].__setitem__(
            mp_schema.ACCELERATOR_ANNOTATION, "drpai-v2m"))
        self.assert_problem("annotation")

    def test_missing_blob(self):
        _, manifest = self.manifest_of(self.layout)
        os.unlink(self.blob(manifest["layers"][0]["digest"]))
        self.assert_problem("blob is missing")

    def test_unreferenced_blob(self):
        stray = os.path.join(self.layout, "blobs", "sha256", "0" * 64)
        with open(stray, "wb") as handle:
            handle.write(b"stray")
        self.assert_problem("is not referenced")

    def test_hostile_layer_member_is_reported_by_inspect_layout(self):
        """inspect_layout itself must report an unsafe member path -- not
        just _layer_members returning it in a raw listing, which a prior
        version of this test asserted instead (see SafeExtraction's
        test_layer_members_lists_hostile_member_without_extracting) and
        which would stay green even if the problem-reporting loop in
        inspect_layout that walks `members` were deleted entirely."""
        import gzip
        import io
        import tarfile

        buffer = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=buffer,
                           mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w",
                              format=tarfile.GNU_FORMAT) as tar:
                info = tarfile.TarInfo("../../escape")
                payload = b"pwned"
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
        self.rewrite_layer(buffer.getvalue())
        self.assert_problem("unsafe member path")

    def test_path_traversal_shaped_digest_is_refused(self):
        """A 64-character digest naming a traversal path, not a hex value,
        must be refused rather than reach os.path.join -- a bare
        len(hex_digest) == 64 check (a prior version of _check_descriptor
        used exactly that) does not catch this: the traversal string here
        is deliberately padded to exactly 64 characters."""
        hostile = "../" * 21 + "x"  # 3*21 + 1 == 64 characters exactly
        self.assertEqual(len(hostile), 64)

        def mutate(manifest):
            manifest["layers"][0]["digest"] = "sha256:" + hostile

        self.rewrite_manifest(mutate)
        self.assert_problem("unsupported or malformed digest")

    def test_label_count_disagreeing_with_packed_file(self):
        """A config claiming more labels than the packed file carries."""
        root = self.work("src2")
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["labels"]["count"] = 3
        config["decoder"]["topK"] = 2
        layout = self.pack(config, make_model_dir(root),
                           make_labels(root), "mismatch")
        _, problems = mp_inspect.inspect_layout(layout)
        joined = " | ".join(problems)
        self.assertIn("holds 4 lines but labels.count is 3", joined)

    def test_label_count_disagreeing_with_compiled_output(self):
        """Labels file and config agree with each other but not with the model."""
        root = self.work("src3")
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["labels"]["count"] = 3
        layout = self.pack(config, make_model_dir(root),
                           make_labels(root, "a\nb\nc\n"), "outputmismatch")
        _, problems = mp_inspect.inspect_layout(layout)
        joined = " | ".join(problems)
        self.assertIn("compiled output has 4 elements", joined)

    def test_model_directory_reference_must_resolve(self):
        root = self.work("src4")
        config = copy.deepcopy(CLASSIFICATION_CONFIG)
        config["model"]["directory"] = "elsewhere"
        layout = os.path.join(self.tmp, "badref")
        entries = mp_oci.collect_entries([("model", make_model_dir(root)),
                                          ("labels/tiny.txt",
                                           make_labels(root))])
        os.makedirs(os.path.join(layout, "blobs", "sha256"))
        staged = os.path.join(layout, "staged")
        digest, size = mp_oci.write_layer(entries, staged)
        mp_oci.write_layout(layout, config, staged, digest, size, "t.tar.gz")
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("but 'elsewhere/deploy.json' is absent",
                      " | ".join(problems))


class RoundTrip(TempCase):
    def roundtrip(self, config, name):
        root = self.work("src-" + name)
        model = make_model_dir(root)
        labels = make_labels(root)
        layout = self.pack(config, model, labels, name)
        destination = os.path.join(self.tmp, "unpacked-" + name)
        _, manifest = self.manifest_of(layout)
        mp_inspect.safe_extract(layout, manifest["layers"][0]["digest"],
                                destination)
        entries = mp_oci.collect_entries([(config["model"]["directory"], model),
                                          (config["labels"]["path"], labels)])
        source = mp_inspect.inventory_plan(entries)
        unpacked = mp_inspect.inventory_directory(destination)
        return source, unpacked, mp_inspect.compare_inventories(source, unpacked)

    def test_all_three_classes_round_trip(self):
        for config in (CLASSIFICATION_CONFIG, DETECTION_CONFIG,
                       SEGMENTATION_CONFIG):
            source, unpacked, differences = self.roundtrip(
                config, config["decoder"]["class"])
            self.assertEqual(differences, [])
            self.assertEqual(set(source), set(unpacked))
            self.assertEqual(len(source), 9,
                             "model dir + 3 files, preprocess dir + 2 files, "
                             "labels dir + 1 file")

    def test_comparison_detects_a_missing_file(self):
        source, unpacked, _ = self.roundtrip(CLASSIFICATION_CONFIG, "detect")
        broken = dict(unpacked)
        broken.pop("model/deploy.so")
        differences = mp_inspect.compare_inventories(source, broken)
        self.assertEqual(differences, ["missing from unpacked tree: "
                                       "model/deploy.so"])

    def test_comparison_detects_an_extra_file(self):
        source, unpacked, _ = self.roundtrip(CLASSIFICATION_CONFIG, "extra")
        broken = dict(unpacked)
        broken["model/stowaway"] = ("file", 3, "deadbeef", 0o644)
        differences = mp_inspect.compare_inventories(source, broken)
        self.assertEqual(differences, ["unexpected in unpacked tree: "
                                       "model/stowaway"])

    def test_comparison_detects_content_and_mode_drift(self):
        source, unpacked, _ = self.roundtrip(CLASSIFICATION_CONFIG, "drift")
        broken = dict(unpacked)
        kind, size, digest, mode = broken["model/deploy.json"]
        broken["model/deploy.json"] = (kind, size, "0" * 64, 0o600)
        differences = mp_inspect.compare_inventories(source, broken)
        self.assertEqual(len(differences), 2)
        self.assertIn("sha256", differences[0] + differences[1])
        self.assertIn("mode", differences[0] + differences[1])

    def test_extracted_modes_follow_policy(self):
        root = self.work("src-mode")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "modes")
        destination = os.path.join(self.tmp, "unpacked-modes")
        _, manifest = self.manifest_of(layout)
        mp_inspect.safe_extract(layout, manifest["layers"][0]["digest"],
                                destination)
        for dirpath, dirnames, filenames in os.walk(destination):
            for name in dirnames:
                self.assertEqual(
                    stat.S_IMODE(os.stat(os.path.join(dirpath, name)).st_mode),
                    mp_oci.DIR_MODE)
            for name in filenames:
                self.assertEqual(
                    stat.S_IMODE(os.stat(os.path.join(dirpath, name)).st_mode),
                    mp_oci.FILE_MODE)


class SafeExtraction(TempCase):
    def _layout_with_hostile_layer(self, member_name, member_type=None):
        """Hand-build a layout whose layer carries a member the producer refuses."""
        import gzip
        import io
        import tarfile

        layout = self.work("hostile-" + member_name.replace("/", "_"))
        os.makedirs(os.path.join(layout, "blobs", "sha256"), exist_ok=True)
        buffer = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=buffer,
                           mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w",
                              format=tarfile.GNU_FORMAT) as tar:
                info = tarfile.TarInfo(member_name)
                if member_type is not None:
                    info.type = member_type
                    info.linkname = "target"
                    info.size = 0
                    tar.addfile(info)
                else:
                    payload = b"pwned"
                    info.size = len(payload)
                    tar.addfile(info, io.BytesIO(payload))
        raw = buffer.getvalue()
        digest = mp_oci.sha256_bytes(raw)
        with open(os.path.join(layout, "blobs", "sha256", digest), "wb") as out:
            out.write(raw)
        return layout, "sha256:" + digest

    def test_absolute_path_member_is_refused(self):
        layout, digest = self._layout_with_hostile_layer("/etc/passwd")
        with self.assertRaises(mp_inspect.InspectionError) as caught:
            mp_inspect.safe_extract(layout, digest,
                                    os.path.join(self.tmp, "dest1"))
        self.assertIn("unsafe member path", str(caught.exception))

    def test_traversal_member_is_refused(self):
        layout, digest = self._layout_with_hostile_layer("../../escape")
        with self.assertRaises(mp_inspect.InspectionError) as caught:
            mp_inspect.safe_extract(layout, digest,
                                    os.path.join(self.tmp, "dest2"))
        self.assertIn("unsafe member path", str(caught.exception))

    def test_symlink_member_is_refused(self):
        import tarfile
        layout, digest = self._layout_with_hostile_layer(
            "link", member_type=tarfile.SYMTYPE)
        with self.assertRaises(mp_inspect.InspectionError) as caught:
            mp_inspect.safe_extract(layout, digest,
                                    os.path.join(self.tmp, "dest3"))
        self.assertIn("tar type", str(caught.exception))

    def test_device_node_member_is_refused(self):
        import tarfile
        layout, digest = self._layout_with_hostile_layer(
            "dev/null", member_type=tarfile.CHRTYPE)
        with self.assertRaises(mp_inspect.InspectionError):
            mp_inspect.safe_extract(layout, digest,
                                    os.path.join(self.tmp, "dest4"))

    def test_layer_members_lists_hostile_member_without_extracting(self):
        """_layer_members is the raw tar listing, used by inspect_layout's
        own unsafe-path check (see InspectorTampering, which exercises that
        check itself through inspect_layout rather than this lower-level
        listing) -- it must surface the traversal name for that check to
        see, without ever calling safe_extract/extractfile on it."""
        layout, digest = self._layout_with_hostile_layer("../../escape")
        members, _, _ = mp_inspect._layer_members(layout, digest)
        self.assertIn("../../escape", members)


class CommandLine(TempCase):
    def test_validate_exit_codes(self):
        root = self.work("cli")
        good = write_config(root, CLASSIFICATION_CONFIG, "good.json")
        bad_config = copy.deepcopy(CLASSIFICATION_CONFIG)
        bad_config["accelerator"] = "nope"
        bad = write_config(root, bad_config, "bad.json")
        self.assertEqual(modelpack.main(["validate", "--config", good]), 0)
        self.assertEqual(modelpack.main(["validate", "--config", bad]), 1)

    def test_inspect_and_roundtrip_exit_zero_on_clean_layout(self):
        root = self.work("cli2")
        model = make_model_dir(root)
        labels = make_labels(root)
        layout = self.pack(CLASSIFICATION_CONFIG, model, labels, "cli-layout")
        self.assertEqual(modelpack.main(["inspect", "--layout", layout]), 0)
        self.assertEqual(modelpack.main(
            ["roundtrip", "--layout", layout, "--model-dir", model,
             "--labels", labels]), 0)

    def test_inspect_exits_nonzero_on_tampered_layout(self):
        root = self.work("cli3")
        layout = self.pack(CLASSIFICATION_CONFIG, make_model_dir(root),
                           make_labels(root), "cli-tampered")
        _, manifest = self.manifest_of(layout)
        blob = os.path.join(layout, "blobs", "sha256",
                            manifest["layers"][0]["digest"].split(":", 1)[1])
        with open(blob, "ab") as handle:
            handle.write(b"\x00")
        self.assertEqual(modelpack.main(["inspect", "--layout", layout]), 1)

    def test_roundtrip_detects_a_substituted_source(self):
        root = self.work("cli4")
        model = make_model_dir(root)
        labels = make_labels(root)
        layout = self.pack(CLASSIFICATION_CONFIG, model, labels, "cli-sub")
        with open(os.path.join(model, "deploy.params"), "ab") as handle:
            handle.write(b"changed")
        self.assertEqual(modelpack.main(
            ["roundtrip", "--layout", layout, "--model-dir", model,
             "--labels", labels]), 1)


class MemberTyping(TempCase):
    """Presence is not enough: a required member must have the right type."""

    def test_preprocess_as_regular_file_is_rejected(self):
        root = self.work("src")
        model = make_model_dir(root)
        shutil.rmtree(os.path.join(model, "preprocess"))
        with open(os.path.join(model, "preprocess"), "w") as handle:
            handle.write("not a directory\n")
        layout = self.pack(CLASSIFICATION_CONFIG, model, make_labels(root), "pp")
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("'model/preprocess' must be a dir, found a file",
                      " | ".join(problems))

    def test_deploy_json_as_directory_is_rejected(self):
        root = self.work("src2")
        model = make_model_dir(root)
        os.unlink(os.path.join(model, "deploy.json"))
        os.makedirs(os.path.join(model, "deploy.json", "inner"))
        with open(os.path.join(model, "deploy.json", "inner", "x"), "w") as f:
            f.write("x")
        layout = self.pack(CLASSIFICATION_CONFIG, model, make_labels(root), "dj")
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("'model/deploy.json' must be a file, found a dir",
                      " | ".join(problems))

    def test_producer_refuses_a_directory_as_labels(self):
        root = self.work("src3")
        directory = self.work("src3/labels-dir")
        argv = ["pack", "--config", write_config(root, CLASSIFICATION_CONFIG),
                "--model-dir", make_model_dir(root), "--labels", directory,
                "--output", os.path.join(self.tmp, "dirlabels")]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(modelpack.main(argv), modelpack.EXIT_FAILED)

    def test_inspector_rejects_labels_packed_as_a_directory(self):
        """A layout built outside the producer still has to fail inspection."""
        root = self.work("src4")
        model = make_model_dir(root)
        labels_dir = os.path.join(root, "labels-as-dir")
        os.makedirs(labels_dir)
        with open(os.path.join(labels_dir, "inner.txt"), "w") as handle:
            handle.write("alpha\n")
        layout = os.path.join(self.tmp, "dirlabels-layout")
        entries = mp_oci.collect_entries([("model", model),
                                          ("labels/tiny.txt", labels_dir)])
        os.makedirs(os.path.join(layout, "blobs", "sha256"))
        staged = os.path.join(layout, "staged")
        digest, size = mp_oci.write_layer(entries, staged)
        mp_oci.write_layout(layout, CLASSIFICATION_CONFIG, staged, digest, size,
                            "t.tar.gz")
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("'labels/tiny.txt' must be a file, found a dir",
                      " | ".join(problems))


class HandBuiltLayer(TempCase):
    """Layouts the producer would never emit still have to be judged correctly."""

    def build(self, member_specs, config=None):
        import gzip
        import tarfile

        config = config or CLASSIFICATION_CONFIG
        layout = os.path.join(self.tmp, "hand-%d" % len(os.listdir(self.tmp)))
        os.makedirs(os.path.join(layout, "blobs", "sha256"))
        staged = os.path.join(layout, "staged")
        with open(staged, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                               mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w",
                                  format=tarfile.GNU_FORMAT) as tar:
                    for name, kind, payload in member_specs:
                        info = tarfile.TarInfo(name)
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mtime = 0
                        if kind == "dir":
                            info.type = tarfile.DIRTYPE
                            info.mode = mp_oci.DIR_MODE
                            tar.addfile(info)
                        else:
                            info.type = tarfile.REGTYPE
                            info.mode = mp_oci.FILE_MODE
                            info.size = len(payload)
                            tar.addfile(info, io.BytesIO(payload))
        digest, size = mp_oci.sha256_file(staged), os.path.getsize(staged)
        mp_oci.write_layout(layout, config, staged, digest, size, "t.tar.gz")
        return layout

    def standard_members(self):
        deploy = json.dumps(DEPLOY_JSON).encode()
        return [("labels", "dir", None),
                ("labels/tiny.txt", "file", LABELS_TEXT.encode()),
                ("model", "dir", None),
                ("model/deploy.json", "file", deploy),
                ("model/deploy.params", "file", b"p"),
                ("model/deploy.so", "file", b"s"),
                ("model/preprocess", "dir", None),
                ("model/preprocess/pp.mem", "file", b"m")]

    def test_baseline_hand_built_layout_is_clean(self):
        layout = self.build(self.standard_members())
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertEqual(problems, [])

    def test_duplicate_member_is_reported(self):
        members = self.standard_members()
        members.append(("labels/tiny.txt", "file", b"one\ntwo\n"))
        layout = self.build(members)
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("appears more than once", " | ".join(problems))

    def test_duplicate_member_refuses_extraction(self):
        members = self.standard_members()
        members.append(("model/deploy.so", "file", b"second"))
        layout = self.build(members)
        _, manifest = self.manifest_of(layout)
        with self.assertRaises(mp_inspect.InspectionError) as caught:
            mp_inspect.safe_extract(layout, manifest["layers"][0]["digest"],
                                    os.path.join(self.tmp, "dupdest"))
        self.assertIn("duplicate member", str(caught.exception))

    def test_labels_must_be_utf8(self):
        members = [m for m in self.standard_members()
                   if m[0] != "labels/tiny.txt"]
        members.append(("labels/tiny.txt", "file", b"\xff\xfe\x00bad"))
        layout = self.build(members)
        _, problems = mp_inspect.inspect_layout(layout)
        self.assertIn("is not valid UTF-8", " | ".join(problems))

    def test_oversized_member_is_reported_not_skipped(self):
        """A check that cannot run must say so rather than pass silently."""
        layout = self.build(self.standard_members())
        original = mp_inspect.MAX_INSPECT_BYTES
        mp_inspect.MAX_INSPECT_BYTES = 4
        try:
            _, problems = mp_inspect.inspect_layout(layout)
        finally:
            mp_inspect.MAX_INSPECT_BYTES = original
        joined = " | ".join(problems)
        self.assertIn("above the 4-byte inspection limit", joined)
        self.assertIn("label-count check did not run", joined)
        self.assertIn("output/label count check did not run", joined)


class EnvelopeTampering(InspectorTampering):
    """The OCI envelope's own fields, not only the blobs they point at."""

    def rewrite_index(self, mutate):
        index = read_json(self.index_path)
        mutate(index)
        with open(self.index_path, "wb") as handle:
            handle.write(mp_oci.canonical_json(index))

    def test_index_schema_version(self):
        self.rewrite_index(lambda i: i.__setitem__("schemaVersion", 99))
        self.assert_problem("index.json: schemaVersion must be 2")

    def test_index_media_type(self):
        self.rewrite_index(lambda i: i.__setitem__(
            "mediaType", "application/vnd.oci.image.manifest.v1+json"))
        self.assert_problem("index.json: mediaType must be")

    def test_index_descriptor_artifact_type(self):
        self.rewrite_index(lambda i: i["manifests"][0].__setitem__(
            "artifactType", "application/octet-stream"))
        self.assert_problem("artifactType must be")

    def test_index_ref_name_must_match_config(self):
        self.rewrite_index(lambda i: i["manifests"][0]["annotations"].__setitem__(
            mp_schema.REF_NAME_ANNOTATION, "someone-else:9"))
        self.assert_problem("must be 'tiny-classifier:1'")

    def test_manifest_media_type(self):
        self.rewrite_manifest(lambda m: m.__setitem__(
            "mediaType", "application/vnd.oci.image.index.v1+json"))
        self.assert_problem("manifest: mediaType must be")


class NonFiniteNumbers(TempCase):
    def test_nan_and_infinity_are_rejected(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            for key in ("scoreThreshold", "iouThreshold"):
                config = copy.deepcopy(DETECTION_CONFIG)
                config["decoder"][key] = value
                errors = mp_schema.validate_config(config)
                self.assertTrue(errors, "%r in %s should be rejected"
                                % (value, key))
                self.assertIn("must be a finite number", " | ".join(errors))

    def test_canonical_json_refuses_non_finite(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.assertRaises(ValueError):
                mp_oci.canonical_json({"scoreThreshold": value})

    def test_nan_config_cannot_be_packed(self):
        root = self.work("nan")
        config = copy.deepcopy(DETECTION_CONFIG)
        config["decoder"]["scoreThreshold"] = float("nan")
        path = os.path.join(root, "nan.json")
        # json.dump would write the bare token NaN; write it the same way a
        # permissive producer would, so the validator is what has to catch it.
        with open(path, "w") as handle:
            json.dump(config, handle)
        argv = ["pack", "--config", path, "--model-dir", make_model_dir(root),
                "--labels", make_labels(root), "--output",
                os.path.join(self.tmp, "nanout")]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(modelpack.main(argv), modelpack.EXIT_FAILED)


if __name__ == "__main__":
    unittest.main(verbosity=2)
