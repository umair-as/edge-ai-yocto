#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuse to start a bitbake/kas/make build or parse
while one is already running on this host.

The constraint is host resources, not directory locks, so a parse for another
board is refused as well. Reads the hook JSON on stdin; prints a deny decision
when it blocks. Any internal error lets the command through.
"""
import json
import re
import shlex
import subprocess
import sys

# Makefile targets that end up running bitbake; keep in step with the Makefile.
MAKE_BUILD_TARGETS = {"base", "dev", "prod", "bundle", "parse", "layers", "shell"}
KAS_BUILD_SUBCOMMANDS = {"build", "shell"}
# Words that only wrap the real command.
WRAPPERS = {"nice", "ionice", "nohup", "time", "exec", "setsid", "env", "stdbuf",
            "chrt", "taskset", "systemd-inhibit", "sudo", "command"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")", "|&", ";;"}
RUNNING = r"bin/(bitbake|bitbake-server|kas|kas-container)( |$)"


def segments(command):
    """Yield the token list of each simple command in a shell command line."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        # Unbalanced quotes (heredocs and the like): fall back to a crude split.
        for part in re.split(r"[;\n&|()]+", command):
            yield part.split()
        return
    current = []
    for tok in tokens:
        if tok in SEPARATORS:
            yield current
            current = []
        else:
            current.append(tok)
    yield current


def starts_build(command, depth=0):
    if depth > 3:
        return False
    for seg in segments(command.replace("\n", " ; ")):
        # Drop VAR=value prefixes, wrapper words and their options.
        while seg and (re.match(r"^\w+=", seg[0]) or seg[0] in WRAPPERS
                       or seg[0].startswith("-") or seg[0].isdigit()):
            seg = seg[1:]
        if not seg:
            continue
        word, args = seg[0].rsplit("/", 1)[-1], seg[1:]
        if word.startswith("bitbake"):
            return True
        if word in ("kas", "kas-container") and KAS_BUILD_SUBCOMMANDS & set(args):
            return True
        if word == "make" and MAKE_BUILD_TARGETS & set(args):
            return True
        if word in ("bash", "sh") and "-c" in args:
            rest = args[args.index("-c") + 1:]
            if rest and starts_build(rest[0], depth + 1):
                return True
        # `tpane run <pane> <command...>` types the command into another pane.
        if word == "tpane" and len(args) > 2 and args[0] == "run":
            if starts_build(" ".join(args[2:]), depth + 1):
                return True
    return False


def running_builds():
    out = subprocess.run(["pgrep", "-af", RUNNING], capture_output=True, text=True).stdout
    # Ignore shell wrappers that merely mention a path in their eval string.
    return [l for l in out.splitlines() if not re.match(r"\d+ \S*sh -c ", l)]


def main():
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    if not command or not starts_build(command):
        return
    running = running_builds()
    if not running:
        return
    listing = "; ".join(l[:120] for l in running[:3])
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "A bitbake/kas build is already running on this host (" + listing + "). "
            "Only one bitbake/kas/make build or parse may run at a time, even for a "
            "different board. Wait for it to finish (watch its log or pane), then retry. "
            "Do not work around this; if the user wants a parallel run they will start it themselves."
        )}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
