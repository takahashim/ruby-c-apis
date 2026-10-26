#!/usr/bin/env python3
"""Build a call graph from linked LLVM IR and find the public API functions
that can reach a longjmp-like escape point.

Usage:
    python3 analyze.py --ir all.ll --api api.json --release 3.4.9 \
        --config macos-arm64 --out 3.4.9.json [--indirect any|typed]

The analysis is deliberately conservative:

* a call to a named function is an edge;
* a function name passed as an argument is also an edge (callbacks);
* with --indirect any, every function whose address is taken can be called
  from every indirect call site;
* with --indirect typed, only functions with a compatible rough signature
  can be called.

It does not model dlopen'd code, callbacks registered in data structures that
are never referenced by name in the IR, or external libraries.
"""

from __future__ import annotations

import argparse
import collections
import datetime as _dt
import json
import re
import sys
from pathlib import Path

DEFINE_RE = re.compile(r'^define\b.*?@(?:"([^"]+)"|([^\s(]+))\s*\(')
DECLARE_RE = re.compile(r'^declare\b.*?@(?:"([^"]+)"|([^\s(]+))')
AT_RE = re.compile(r'@(?:"([^"]+)"|([A-Za-z0-9_.$-]+))')
CALL_RE = re.compile(
    r"^\s*(?:%[^=]+=\s*)?(?:tail\s+|musttail\s+|notail\s+)?(?:call|invoke|callbr)\b"
)
INDIRECT_RE = re.compile(r"%([A-Za-z0-9_.]+)\s*\(")
PARAM_NAME_RE = re.compile(r"%[A-Za-z0-9_.]+\s*$")
ATTR_WORDS = {
    "noundef", "nonnull", "null", "signext", "zeroext", "inreg", "nocapture",
    "readonly", "writeonly", "readnone", "noalias", "noinline", "alwaysinline",
    "cold", "hot", "noreturn", "nounwind", "uwtable", "willreturn",
    "mustprogress", "immarg", "returned", "swiftself", "swifterror",
    "swifttailcc", "tailcc", "fastcc", "coldcc", "cc10", "cc11",
}
ALIGN_RE = re.compile(r"\balign\s+\d+\b")
DEREF_RE = re.compile(r"\b(?:dereferenceable|dereferenceable_or_null|byval|byref|sret|inalloca|preallocated)\([^)]*\)")


def at_names(line: str):
    """Yield function names referenced with @ in a line."""
    for quoted, bare in AT_RE.findall(line):
        yield quoted or bare


def split_top_level(text: str, sep: str = ","):
    parts, depth, start = [], 0, 0
    for index, char in enumerate(text):
        if char in "([{<":
            depth += 1
        elif char in ")]}>":
            depth -= 1
        elif char == sep and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def first_type(text: str):
    """Very rough first type token of an LLVM operand/parameter."""
    text = DEREF_RE.sub("", text)
    text = ALIGN_RE.sub("", text)
    text = PARAM_NAME_RE.sub("", text).strip()
    if not text:
        return "?"
    # Drop the parameter name and common attribute words from the left.
    tokens = text.replace(",", " ").split()
    for token in tokens:
        word = token.strip("()*[]{}<>")
        if word in ATTR_WORDS or not word:
            continue
        return word
    return "?"


def parse_signature(line: str):
    """Return (return_type, [param_type], variadic) for a define line."""
    match = DEFINE_RE.match(line)
    if not match:
        return None
    name = match.group(1) or match.group(2)
    prefix = line[: match.start(2) if match.group(2) else line.index("@")]
    ret = first_type(prefix.split()[-1] if prefix.split() else "?")
    rest = line[match.end():]
    depth = 0
    end = len(rest)
    for index, char in enumerate(rest):
        if char == "(":
            depth += 1
        elif char == ")":
            if depth == 0:
                end = index
                break
            depth -= 1
    params_text = rest[:end]
    params = split_top_level(params_text)
    variadic = any(p.strip() == "..." for p in params)
    types = [first_type(p) for p in params if p.strip() != "..."]
    return name, (ret, tuple(types), variadic)


def parse_call_args(line: str):
    """Return (return_type, [arg_type], variadic) for an indirect call site.

    The signature is derived from the call syntax rather than the callee,
    because the callee is a register.  It is only an approximation, which is
    why --indirect typed is opt-in.
    """
    # Remove the result assignment.
    if "=" in line.split("call", 1)[0]:
        line = line.split("=", 1)[1]
    match = re.search(r"\b(?:call|invoke|callbr)\b", line)
    if not match:
        return None
    rest = line[match.end():].strip()
    # Explicit function type: call i32 (i8*, ...) %fn(i8* %x)
    explicit = re.match(r"([^%]*?)(%[A-Za-z0-9_.]+)\s*\(", rest)
    if explicit:
        ret = first_type(explicit.group(1).split()[0]) if explicit.group(1).split() else "?"
    else:
        ret = "?"
    callee = INDIRECT_RE.search(rest)
    if not callee:
        return None
    args_text = rest[callee.end():]
    depth = 0
    end = len(args_text)
    for index, char in enumerate(args_text):
        if char in "([{<":
            depth += 1
        elif char in ")]}>":
            if depth == 0:
                end = index
                break
            depth -= 1
    args = split_top_level(args_text[:end])
    types = [first_type(a) for a in args if a.strip()]
    variadic = explicit is not None and "..." in explicit.group(1)
    return ret, tuple(types), variadic


def is_escape(name: str) -> bool:
    if name == "rb_ec_tag_jump":
        return True
    if name.startswith("llvm.eh.sjlj.longjmp"):
        return True
    return "longjmp" in name


def signature_compatible(call_sig, def_sig) -> bool:
    if call_sig is None or def_sig is None:
        return False
    call_ret, call_args, call_var = call_sig
    def_ret, def_args, def_var = def_sig
    if call_ret not in ("?", def_ret):
        return False
    if call_var or def_var:
        if len(call_args) < len(def_args):
            return False
    elif len(call_args) != len(def_args):
        return False
    # Compare the fixed prefix.  Pointer/integer differences are common in
    # LLVM's opaque-pointer IR, so only reject an obviously different type.
    for got, want in zip(call_args, def_args):
        if got in ("?", "ptr") or want in ("?", "ptr"):
            continue
        if got != want:
            return False
    return True


def scan_ir(path: Path):
    defined = set()
    declared = set()
    signatures = {}
    reverse = collections.defaultdict(set)
    address_taken = set()
    indirect_callers = set()
    indirect_sites = collections.defaultdict(list)
    global_refs = set()

    current = None
    current_callees = set()
    current_indirect = []
    current_refs = set()

    with path.open("r", encoding="utf-8", errors="replace") as ir:
        for raw in ir:
            line = raw.rstrip("\n")
            if current is None:
                if line.startswith("define "):
                    sig = parse_signature(line)
                    if sig:
                        name, signature = sig
                        current = name
                        defined.add(name)
                        signatures[name] = signature
                        current_callees = set()
                        current_indirect = []
                        current_refs = set()
                    continue
                if line.startswith("declare "):
                    match = DECLARE_RE.match(line)
                    if match:
                        declared.add(match.group(1) or match.group(2))
                    continue
                if line and not line.startswith((";", "attributes", "!", "source_filename",
                                                 "target ", "module ", "$")):
                    global_refs.update(at_names(line))
                continue

            if line.startswith("}"):
                if current_callees:
                    for callee in current_callees:
                        reverse[callee].add(current)
                if current_refs:
                    address_taken.update(current_refs)
                if current_indirect:
                    indirect_callers.add(current)
                    indirect_sites[current].extend(current_indirect)
                current = None
                continue

            names = set(at_names(line))
            is_call = CALL_RE.match(line) is not None
            has_indirect_callee = is_call and INDIRECT_RE.search(line) is not None

            if names:
                if is_call:
                    current_callees.update(names)
                    # The first @ in a direct call is the callee itself, not
                    # an address-taken function.  Everything else in the
                    # argument list may be stored and called later.
                    if has_indirect_callee:
                        current_refs.update(names)
                    else:
                        callee_name = next(at_names(line))
                        current_refs.update(names - {callee_name})
                else:
                    current_refs.update(names)

            if is_call and has_indirect_callee:
                call_sig = parse_call_args(line)
                if call_sig is not None:
                    current_indirect.append(call_sig)

    address_taken.update(global_refs)
    # A function whose address is taken may be called indirectly.  Direct
    # callees are also in address_taken because we add every @ reference;
    # that only makes the analysis more conservative.
    return {
        "defined": defined,
        "declared": declared,
        "signatures": signatures,
        "reverse": {k: sorted(v) for k, v in reverse.items()},
        "address_taken": address_taken,
        "indirect_callers": indirect_callers,
        "indirect_sites": {k: v for k, v in indirect_sites.items()},
    }


def reachability(graph, mode: str):
    defined = graph["defined"]
    declared = graph["declared"]
    signatures = graph["signatures"]
    reverse = graph["reverse"]
    addr = graph["address_taken"]
    indirect_callers = graph["indirect_callers"]
    indirect_sites = graph["indirect_sites"]

    tainted = {}
    queue = collections.deque()

    def mark(name, target, next_name, via):
        if name in tainted:
            return
        tainted[name] = {"target": target, "next": next_name, "via": via}
        queue.append(name)

    escapes = sorted(name for name in (defined | declared) if is_escape(name))
    for name in escapes:
        mark(name, name, None, "escape")

    any_indirect_done = False

    while queue:
        callee = queue.popleft()
        info = tainted[callee]

        for caller in reverse.get(callee, ()):
            mark(caller, info["target"], callee, "call")

        # Indirect calls.  In "any" mode the first tainted address-taken
        # function unlocks every indirect call site.  In "typed" mode only
        # call sites with a compatible rough signature are unlocked.
        if callee in addr:
            if mode == "any":
                if not any_indirect_done:
                    any_indirect_done = True
                    for caller in indirect_callers:
                        mark(caller, info["target"], callee, "indirect")
            else:
                for caller in indirect_callers:
                    if caller in tainted:
                        continue
                    if any(
                        signature_compatible(sig, signatures.get(callee))
                        for sig in indirect_sites.get(caller, ())
                    ):
                        mark(caller, info["target"], callee, "indirect")

    return tainted, escapes


def build_path(root, tainted):
    if root not in tainted:
        return None, None, None
    path = [root]
    current = root
    via = [tainted[root]["via"]]
    seen = {root}
    while True:
        info = tainted[current]
        nxt = info["next"]
        if nxt is None:
            return path, info["target"], via
        if nxt in seen or len(path) > 128:
            return path, info["target"], via
        path.append(nxt)
        via.append(tainted[nxt]["via"])
        seen.add(nxt)
        current = nxt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ir", required=True, type=Path)
    parser.add_argument("--api", required=True, type=Path)
    parser.add_argument("--release", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--indirect", choices=("any", "typed"), default="any")
    parser.add_argument("--commit", default="")
    parser.add_argument("--source-url", default="")
    args = parser.parse_args()

    graph = scan_ir(args.ir)
    tainted, escapes = reachability(graph, args.indirect)
    api = json.loads(args.api.read_text(encoding="utf-8"))

    defined = graph["defined"]
    funcs = []
    stats = collections.Counter()

    for fn in api["functions"]:
        name = fn["name"]
        kind = fn["kind"]
        wrapper = fn.get("wrapper")
        internal = bool(fn.get("internal"))

        if kind == "inline":
            root = wrapper
            if not root or root not in defined:
                funcs.append({
                    "name": name,
                    "header": fn["header"],
                    "internal": internal,
                    "kind": kind,
                    "status": "unsupported_inline",
                })
                stats["unsupported_inline"] += 1
                continue
        else:
            root = name
            if root not in defined:
                funcs.append({
                    "name": name,
                    "header": fn["header"],
                    "internal": internal,
                    "kind": kind,
                    "status": "not_defined",
                })
                stats["not_defined"] += 1
                continue

        path, target, vias = build_path(root, tainted)
        if path is None:
            funcs.append({
                "name": name,
                "header": fn["header"],
                "internal": internal,
                "kind": kind,
                "status": "no_path",
            })
            stats["no_path"] += 1
        else:
            # Replace the artificial wrapper root with the API name.
            if kind == "inline" and path and path[0] == wrapper:
                path = [name] + path[1:]
                if len(path) > 1 and path[1] == name:
                    path = [name] + path[2:]
                vias = vias[1:] if vias else vias
                if vias and path:
                    vias = ["inline"] + vias
            funcs.append({
                "name": name,
                "header": fn["header"],
                "internal": internal,
                "kind": kind,
                "status": "raises",
                "target": target,
                "path": path,
                "via": vias,
            })
            stats["raises"] += 1

    controls = []
    for name in ("rb_ary_push", "rb_jump_tag", "rb_exc_raise", "rb_ary_new_capa"):
        path, target, _ = build_path(name, tainted) if name in defined else (None, None, None)
        controls.append({
            "name": name,
            "reachable": path is not None,
            "path": path or [],
            "defined": name in defined,
        })

    result = {
        "schema": 1,
        "release": args.release,
        "config": args.config,
        "indirect": args.indirect,
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "commit": args.commit,
        "source_url": args.source_url,
        "ir": str(args.ir),
        "api": str(args.api),
        "stats": {
            "defined_functions": len(defined),
            "declared_functions": len(graph["declared"]),
            "address_taken": len(graph["address_taken"]),
            "indirect_callers": len(graph["indirect_callers"]),
            "public_api": len(api["functions"]),
            **stats,
        },
        "escape_points": escapes,
        "controls": controls,
        "controls_ok": all(c["reachable"] for c in controls),
        "functions": sorted(funcs, key=lambda f: f["name"]),
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(result["stats"], ensure_ascii=False))
    if not result["controls_ok"]:
        print("warning: reachability controls failed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
