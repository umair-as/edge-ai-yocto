"""ModelPack config contract, schema version 1.0.

The config blob is the runner contract. It carries only facts a runner cannot
read out of the compiled model directory: which decoder to dispatch, the
index-to-name mapping, the decoder's own parameters, and the accelerator the
blob was compiled for.

Input shape, layout, colour order, resize and normalization are authoritative
inside the compiled preprocess/ object executed by PreRuntime. They are rejected
here by name: a second copy can disagree with the object that actually runs.
"""

import math
import re

SCHEMA_VERSION = "1.0"

# MAJOR.MINOR. A consumer accepts an equal MAJOR and a MINOR no greater than its
# own; a MAJOR bump is breaking and an older consumer must refuse it.
SUPPORTED_SCHEMA_VERSIONS = frozenset({"1.0"})

CONFIG_MEDIA_TYPE = "application/vnd.cncf.model.config.v1+json"
MANIFEST_MEDIA_TYPE = "application/vnd.oci.image.manifest.v1+json"
ARTIFACT_TYPE = "application/vnd.cncf.model.manifest.v1+json"
WEIGHT_LAYER_MEDIA_TYPE = "application/vnd.cncf.model.weight.v1.tar+gzip"
INDEX_MEDIA_TYPE = "application/vnd.oci.image.index.v1+json"

ACCELERATOR_ANNOTATION = "io.edge-ai.accelerator"
CREATED_ANNOTATION = "org.opencontainers.image.created"
REF_NAME_ANNOTATION = "org.opencontainers.image.ref.name"
TITLE_ANNOTATION = "org.opencontainers.image.title"

ACCELERATORS = frozenset({"drpai-v2l"})
DECODER_CLASSES = frozenset({"classification", "detection", "segmentation"})

# Entries every compiled DRP-AI model directory contains, with the archive
# member type each one must have. Presence alone is not enough: a directory
# standing in for deploy.json, or a file standing in for preprocess/, is a
# broken model that must not pass inspection.
REQUIRED_MODEL_ENTRIES = (
    ("deploy.json", "file"),
    ("deploy.params", "file"),
    ("deploy.so", "file"),
    ("preprocess", "dir"),
)

NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
PATH_SEGMENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# Preprocessing and tensor metadata that rides inside the compiled artifact.
# Named explicitly so the diagnostic says why, not merely "unknown key".
FORBIDDEN_KEYS = {
    "colorformat", "colororder", "colourorder", "cofadd", "cofmul",
    "inputformat", "inputlayout", "inputshape", "layout", "mean",
    "normalization", "normalize", "preprocess", "preprocessing", "resize",
    "shape", "std", "tensorshape",
}

_TOP_LEVEL_KEYS = {"schemaVersion", "name", "version", "accelerator", "model",
                   "labels", "decoder"}


class _Errors(list):
    def add(self, path, message):
        self.append("%s: %s" % (path, message))


def _check_str(errors, path, value, pattern, what):
    if not isinstance(value, str):
        errors.add(path, "must be a string, got %s" % type(value).__name__)
        return False
    if not pattern.match(value):
        errors.add(path, "%s (got %r)" % (what, value))
        return False
    return True


def _check_int(errors, path, value, low, high):
    # bool is an int subclass; a JSON true must not pass as 1.
    if isinstance(value, bool) or not isinstance(value, int):
        errors.add(path, "must be an integer, got %s" % type(value).__name__)
        return False
    if not low <= value <= high:
        errors.add(path, "must be in [%d, %d], got %d" % (low, high, value))
        return False
    return True


def _check_number(errors, path, value, low, high, low_exclusive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        errors.add(path, "must be a number, got %s" % type(value).__name__)
        return False
    # NaN compares false against every bound, so a range test alone lets it
    # through; infinities serialize outside strict JSON.
    if not math.isfinite(value):
        errors.add(path, "must be a finite number, got %r" % value)
        return False
    too_low = value <= low if low_exclusive else value < low
    if too_low or value > high:
        errors.add(path, "must be in %s%g, %g], got %g"
                   % ("(" if low_exclusive else "[", low, high, value))
        return False
    return True


def _check_keys(errors, path, obj, allowed):
    for key in sorted(obj):
        if key.lower() in FORBIDDEN_KEYS:
            errors.add("%s.%s" % (path, key),
                       "forbidden: input and preprocessing metadata is "
                       "authoritative inside the compiled preprocess/ artifact "
                       "and must not be duplicated in the config")
        elif key not in allowed:
            errors.add("%s.%s" % (path, key), "unknown field")


def _check_relative_path(errors, path, value):
    """Relative, forward-slash, no traversal, no absolute root, no empty parts."""
    if not isinstance(value, str):
        errors.add(path, "must be a string, got %s" % type(value).__name__)
        return False
    if not value:
        errors.add(path, "must not be empty")
        return False
    if value.startswith("/") or "\\" in value:
        errors.add(path, "must be a relative path using '/' (got %r)" % value)
        return False
    parts = value.split("/")
    for part in parts:
        if part in ("", ".", ".."):
            errors.add(path, "must not contain empty or traversal segments "
                             "(got %r)" % value)
            return False
        if not PATH_SEGMENT_RE.match(part):
            errors.add(path, "segment %r is not a portable path component" % part)
            return False
    return True


def _validate_decoder(errors, decoder, labels_count):
    if not isinstance(decoder, dict):
        errors.add("decoder", "must be an object, got %s" % type(decoder).__name__)
        return
    cls = decoder.get("class")
    if cls is None:
        errors.add("decoder.class", "is required")
        return
    if cls not in DECODER_CLASSES:
        errors.add("decoder.class", "must be one of %s, got %r"
                   % (sorted(DECODER_CLASSES), cls))
        return

    if cls == "classification":
        _check_keys(errors, "decoder", decoder, {"class", "topK"})
        if "topK" not in decoder:
            errors.add("decoder.topK", "is required for classification")
        elif _check_int(errors, "decoder.topK", decoder["topK"], 1, 1000):
            if labels_count is not None and decoder["topK"] > labels_count:
                errors.add("decoder.topK",
                           "must not exceed labels.count (%d > %d)"
                           % (decoder["topK"], labels_count))
    elif cls == "detection":
        _check_keys(errors, "decoder", decoder,
                    {"class", "scoreThreshold", "iouThreshold", "maxDetections"})
        for key in ("scoreThreshold", "iouThreshold", "maxDetections"):
            if key not in decoder:
                errors.add("decoder.%s" % key, "is required for detection")
        if "scoreThreshold" in decoder:
            _check_number(errors, "decoder.scoreThreshold",
                          decoder["scoreThreshold"], 0.0, 1.0)
        if "iouThreshold" in decoder:
            _check_number(errors, "decoder.iouThreshold",
                          decoder["iouThreshold"], 0.0, 1.0, low_exclusive=True)
        if "maxDetections" in decoder:
            _check_int(errors, "decoder.maxDetections",
                       decoder["maxDetections"], 1, 10000)
    else:
        # segmentation decodes by argmax over the class channel; the closed set
        # of parameters is empty.
        _check_keys(errors, "decoder", decoder, {"class"})


def validate_config(config):
    """Return a sorted list of human-readable errors; empty means valid."""
    errors = _Errors()
    if not isinstance(config, dict):
        errors.add("<config>", "must be a JSON object, got %s"
                   % type(config).__name__)
        return list(errors)

    _check_keys(errors, "<config>", config, _TOP_LEVEL_KEYS)

    version = config.get("schemaVersion")
    if version is None:
        errors.add("schemaVersion", "is required")
    elif not isinstance(version, str):
        errors.add("schemaVersion", "must be a string, got %s"
                   % type(version).__name__)
    elif version not in SUPPORTED_SCHEMA_VERSIONS:
        errors.add("schemaVersion", "unsupported version %r (supported: %s)"
                   % (version, sorted(SUPPORTED_SCHEMA_VERSIONS)))

    if "name" not in config:
        errors.add("name", "is required")
    else:
        _check_str(errors, "name", config["name"], NAME_RE,
                   "must be a lowercase DNS label")

    if "version" not in config:
        errors.add("version", "is required")
    else:
        _check_str(errors, "version", config["version"], VERSION_RE,
                   "must be 1-64 chars of [A-Za-z0-9._-] starting alphanumeric")

    accelerator = config.get("accelerator")
    if accelerator is None:
        errors.add("accelerator", "is required")
    elif accelerator not in ACCELERATORS:
        errors.add("accelerator", "must be one of %s, got %r"
                   % (sorted(ACCELERATORS), accelerator))

    model = config.get("model")
    if model is None:
        errors.add("model", "is required")
    elif not isinstance(model, dict):
        errors.add("model", "must be an object, got %s" % type(model).__name__)
    else:
        _check_keys(errors, "model", model, {"directory"})
        if "directory" not in model:
            errors.add("model.directory", "is required")
        else:
            _check_relative_path(errors, "model.directory", model["directory"])

    labels_count = None
    labels = config.get("labels")
    if labels is None:
        errors.add("labels", "is required")
    elif not isinstance(labels, dict):
        errors.add("labels", "must be an object, got %s" % type(labels).__name__)
    else:
        _check_keys(errors, "labels", labels, {"path", "count"})
        if "path" not in labels:
            errors.add("labels.path", "is required")
        else:
            _check_relative_path(errors, "labels.path", labels["path"])
        if "count" not in labels:
            errors.add("labels.count", "is required")
        elif _check_int(errors, "labels.count", labels["count"], 1, 1000000):
            labels_count = labels["count"]

    if "decoder" not in config:
        errors.add("decoder", "is required")
    else:
        _validate_decoder(errors, config["decoder"], labels_count)

    return sorted(errors)


def schema_version_accepted(version, consumer=SCHEMA_VERSION):
    """Compatibility rule: equal MAJOR, consumer MINOR not exceeded."""
    try:
        major, minor = (int(part) for part in version.split("."))
        c_major, c_minor = (int(part) for part in consumer.split("."))
    except (AttributeError, ValueError):
        return False
    return major == c_major and minor <= c_minor
