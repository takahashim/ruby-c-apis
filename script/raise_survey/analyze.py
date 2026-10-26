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


LABEL_RE = re.compile(r'^(?:"([^"]+)"|([A-Za-z0-9_.$-]+)):')
SSA_DEF_RE = re.compile(r'^\s*(%[A-Za-z0-9_.]+)\s*=\s*(.*)$')
LOAD_RE = re.compile(r'^load\s+(?!volatile|atomic)[^,]+,\s*ptr\s+(%[A-Za-z0-9_.]+)')
ICMP_RE = re.compile(r'^icmp\s+(?:samesign\s+)?(\w+)\s+(i\d+|ptr)\s+(\S+),\s*(\S+)')
ZEXT_RE = re.compile(r'^zext\s+(?:nneg\s+)?\S+\s+(\S+)\s+to\b')
STORE_PARAM_RE = re.compile(r'^\s*store\s+\S+\s+(%[A-Za-z0-9_.]+),\s*ptr\s+(%[A-Za-z0-9_.]+)')
LABEL_REF_RE = re.compile(r'label\s+%("[^"]+"|[A-Za-z0-9_.$-]+)')
BR_COND_RE = re.compile(r'^\s*br\s+i1\s+(\S+),\s*label\s+%("[^"]+"|[A-Za-z0-9_.$-]+),\s*label\s+%("[^"]+"|[A-Za-z0-9_.$-]+)')
TERM_RE = re.compile(r'^\s*(?:br|switch|indirectbr|invoke|callbr|ret|unreachable|resume|cleanupret|catchret|catchswitch)\b')
SSA_TOKEN_RE = re.compile(r'%[A-Za-z0-9_.]+(?![A-Za-z0-9_.])')
INT_RE = re.compile(r'^-?\d+$')

# Cap on the number of (function, constant arguments) nodes.  The analysis
# only specializes functions whose behavior depends on an integer argument,
# so this is far above what a real build produces.
MAX_SPECIALIZATIONS = 200000


def param_names(line: str):
    match = DEFINE_RE.match(line)
    if not match:
        return []
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
    names = []
    for index, param in enumerate(split_top_level(rest[:end])):
        if param.strip() == "...":
            continue
        last = param.split()[-1] if param.split() else ""
        names.append(last if last.startswith("%") else "%%%d" % index)
    return names


def operand(token: str):
    """('lit', n) for an integer constant, ('ssa', name) for a register."""
    token = token.strip()
    if INT_RE.match(token):
        return ("lit", int(token))
    if token in ("true", "false"):
        return ("lit", 1 if token == "true" else 0)
    if token == "null":
        return ("lit", 0)
    if token.startswith("%"):
        return ("ssa", token)
    return None


def call_args(line: str):
    """Operands of a direct call, in order (None for non-integer values)."""
    match = AT_RE.search(line)
    if not match or line[match.end():match.end() + 1] != "(":
        return None
    text = line[match.end() + 1:]
    depth = 0
    end = len(text)
    for index, char in enumerate(text):
        if char in "([{<":
            depth += 1
        elif char in ")]}>":
            if depth == 0:
                end = index
                break
            depth -= 1
    args = []
    for arg in split_top_level(text[:end]):
        words = arg.split()
        args.append(operand(words[-1]) if words else None)
    return args


def to_signed(value: int, bits: int):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def eval_icmp(pred: str, bits: int, left: int, right: int):
    mask = (1 << bits) - 1
    ul, ur = left & mask, right & mask
    sl, sr = to_signed(left, bits), to_signed(right, bits)
    return {
        "eq": ul == ur, "ne": ul != ur,
        "ugt": ul > ur, "uge": ul >= ur, "ult": ul < ur, "ule": ul <= ur,
        "sgt": sl > sr, "sge": sl >= sr, "slt": sl < sr, "sle": sl <= sr,
    }.get(pred)


def parse_body(header: str, lines):
    """Parse a function body for argument-sensitive reachability.

    Returns None unless the function branches on an integer argument or
    forwards one to another call.  Otherwise returns the basic blocks, with
    the register definitions needed to evaluate branch conditions.  Only
    arguments that are spilled once to an alloca and never touched again are
    trusted, so a known argument value is always the value seen at the branch.
    """
    params = param_names(header)
    if not params:
        return None
    param_index = {name: index for index, name in enumerate(params)}

    spills = {}
    for line in lines:
        match = STORE_PARAM_RE.match(line)
        if match and match.group(1) in param_index and match.group(2) not in spills:
            spills[match.group(2)] = param_index[match.group(1)]
    trusted = {}
    if spills:
        loads = collections.Counter()
        uses = collections.Counter()
        for line in lines:
            tokens = [t for t in SSA_TOKEN_RE.findall(line) if t in spills]
            if not tokens:
                continue
            def_match = SSA_DEF_RE.match(line)
            load_match = LOAD_RE.match(def_match.group(2)) if def_match else None
            if def_match and def_match.group(1) in spills and def_match.group(2).startswith("alloca"):
                continue
            if load_match and load_match.group(1) in spills:
                loads[load_match.group(1)] += 1
                uses[load_match.group(1)] += 1
                continue
            for token in tokens:
                uses[token] += 1
        for name, index in spills.items():
            # one store plus plain loads, nothing else
            if uses[name] == loads[name] + 1:
                trusted[name] = index

    defs = {}
    blocks = {}
    order = []
    current = None

    def open_block(label):
        nonlocal current
        current = {"calls": [], "refs": set(), "indirect": [], "term": None}
        blocks[label] = current
        order.append(label)

    open_block(None)
    in_switch = False
    for line in lines:
        if in_switch:
            # case list of a multi-line switch: one `i32 N, label %X` per line
            current["term"][1].extend(t.strip('"') for t in LABEL_REF_RE.findall(line))
            in_switch = "]" not in line
            continue
        label = LABEL_RE.match(line)
        if label and not line.startswith(" "):
            open_block(label.group(1) or label.group(2))
            continue
        def_match = SSA_DEF_RE.match(line)
        if def_match:
            name, expr = def_match.groups()
            load = LOAD_RE.match(expr)
            icmp = ICMP_RE.match(expr)
            zext = ZEXT_RE.match(expr)
            if load and load.group(1) in trusted:
                defs[name] = ("param", trusted[load.group(1)])
            elif icmp:
                defs[name] = ("icmp", icmp.group(1), icmp.group(2),
                              operand(icmp.group(3)), operand(icmp.group(4)))
            elif zext:
                defs[name] = ("zext", operand(zext.group(1)))
        if CALL_RE.match(line):
            names = list(at_names(line))
            if INDIRECT_RE.search(line):
                current["refs"].update(names)
                sig = parse_call_args(line)
                if sig is not None:
                    current["indirect"].append(sig)
            elif names:
                current["calls"].append((names[0], call_args(line)))
                current["refs"].update(names[1:])
            continue
        if TERM_RE.match(line):
            cond = BR_COND_RE.match(line)
            if cond:
                current["term"] = ("cond", operand(cond.group(1)), cond.group(2).strip('"'),
                                   cond.group(3).strip('"'))
            else:
                current["term"] = ("any", [t.strip('"') for t in LABEL_REF_RE.findall(line)])
                in_switch = "[" in line and "]" not in line
            continue
        names = list(at_names(line))
        if names:
            current["refs"].update(names)

    for index, name in enumerate(params):
        defs.setdefault(name, ("param", index))

    info = {"defs": defs, "blocks": blocks, "order": order,
            "cmp_params": set(), "forwards": []}
    for expr in defs.values():
        if expr[0] == "icmp":
            for side in expr[3:5]:
                index = value_param(info, side)
                if index is not None:
                    info["cmp_params"].add(index)
    for block in blocks.values():
        for callee, args in block["calls"]:
            for position, arg in enumerate(args or ()):
                index = value_param(info, arg)
                if index is not None:
                    info["forwards"].append((callee, position, index))
    if not info["cmp_params"] and not info["forwards"]:
        return None
    return info


def value_param(info, op):
    """Index of the argument an operand is a copy of, if any."""
    seen = 0
    while op is not None and op[0] == "ssa" and seen < 8:
        expr = info["defs"].get(op[1])
        if expr is None:
            return None
        if expr[0] == "param":
            return expr[1]
        if expr[0] != "zext":
            return None
        op = expr[1]
        seen += 1
    return None


def value_of(info, op, ctx, depth=0):
    """Integer value of an operand given known argument values, or None."""
    if op is None or depth > 8:
        return None
    if op[0] == "lit":
        return op[1]
    expr = info["defs"].get(op[1])
    if expr is None:
        return None
    if expr[0] == "param":
        return ctx.get(expr[1])
    if expr[0] == "zext":
        return value_of(info, expr[1], ctx, depth + 1)
    if expr[0] == "icmp":
        left = value_of(info, expr[3], ctx, depth + 1)
        right = value_of(info, expr[4], ctx, depth + 1)
        if left is None or right is None or expr[2] == "ptr":
            return None
        result = eval_icmp(expr[1], int(expr[2][1:]), left, right)
        return None if result is None else int(result)
    return None


def feasible_blocks(info, ctx):
    """Blocks reachable from the entry when the known arguments decide branches."""
    blocks = info["blocks"]
    seen = set()
    stack = [info["order"][0]]
    while stack:
        label = stack.pop()
        if label in seen or label not in blocks:
            continue
        seen.add(label)
        term = blocks[label]["term"]
        if term is None:
            continue
        if term[0] == "cond":
            value = value_of(info, term[1], ctx)
            if value is None:
                stack.extend((term[2], term[3]))
            else:
                stack.append(term[2] if value else term[3])
        else:
            stack.extend(term[1])
    return [blocks[label] for label in info["order"] if label in seen]


def specialize(reverse, bodies, literal_calls, direct_calls, plain_refs,
               indirect_callers, indirect_sites):
    """Add call edges that depend on constant integer arguments.

    A branch such as `if (type == MEMOP_TYPE_MALLOC)` guards a call only for
    some callers.  For each function whose behavior depends on an integer
    argument, one node per set of constant arguments is created, holding only
    the calls on blocks that those constants can reach.  Callers that pass a
    constant link to that node instead of the whole function.  Unknown
    arguments keep every block, so the result is never less conservative than
    the unspecialized graph.
    """
    sensitive = {name: set(info["cmp_params"]) for name, info in bodies.items()}
    changed = True
    while changed:
        changed = False
        for name, info in bodies.items():
            for callee, position, index in info["forwards"]:
                if position in sensitive.get(callee, ()) and index not in sensitive[name]:
                    sensitive[name].add(index)
                    changed = True
    sensitive = {name: indexes for name, indexes in sensitive.items() if indexes}

    nodes = {}
    queue = collections.deque()

    def key_of(callee, args, resolve):
        known = []
        for position in sorted(sensitive.get(callee, ())):
            if args and position < len(args):
                value = resolve(args[position])
                if value is not None:
                    known.append((position, value))
        return tuple(known)

    def node_for(callee, key):
        if not key:
            return callee
        name = "%s{%s}" % (callee, ",".join("arg%d=%d" % pair for pair in key))
        if name not in nodes and len(nodes) < MAX_SPECIALIZATIONS:
            nodes[name] = (callee, key)
            queue.append(name)
        return name if name in nodes else callee

    def link(owner, info, ctx):
        callees = set()
        sites = []
        for block in feasible_blocks(info, ctx):
            callees.update(block["refs"])
            sites.extend(block["indirect"])
            for callee, args in block["calls"]:
                key = key_of(callee, args, lambda op: value_of(info, op, ctx))
                callees.add(node_for(callee, key))
        for callee in callees:
            reverse[callee].add(owner)
        if sites:
            indirect_callers.add(owner)
            indirect_sites[owner].extend(sites)

    for name, info in bodies.items():
        link(name, info, {})

    # Functions without a parsed body keep their plain edges, minus direct
    # calls that all pass constants to an argument-sensitive callee.
    for caller, records in literal_calls.items():
        if caller in bodies:
            continue
        redirected = collections.Counter()
        for callee, args in records:
            key = key_of(callee, args, lambda op: op[1] if op and op[0] == "lit" else None)
            if key:
                reverse[node_for(callee, key)].add(caller)
                redirected[callee] += 1
        for callee, count in redirected.items():
            if count == direct_calls[caller][callee] and callee not in plain_refs[caller]:
                reverse[callee].discard(caller)

    while queue:
        name = queue.popleft()
        callee, key = nodes[name]
        if callee in bodies:
            link(name, bodies[callee], dict(key))


def scan_ir(path: Path):
    defined = set()
    declared = set()
    signatures = {}
    reverse = collections.defaultdict(set)
    address_taken = set()
    indirect_callers = set()
    indirect_sites = collections.defaultdict(list)
    global_refs = set()
    bodies = {}
    literal_calls = collections.defaultdict(list)
    direct_calls = collections.defaultdict(collections.Counter)
    plain_refs = collections.defaultdict(set)

    current = None
    header = ""
    body = []
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
                        header = line
                        body = []
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
                info = parse_body(header, body)
                if info is not None:
                    # Edges of an argument-sensitive function are built later,
                    # per set of known argument values.
                    bodies[current] = info
                else:
                    for callee in current_callees:
                        reverse[callee].add(current)
                if current_refs:
                    address_taken.update(current_refs)
                if current_indirect:
                    indirect_callers.add(current)
                    indirect_sites[current].extend(current_indirect)
                current = None
                continue

            body.append(line)
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
                        direct_calls[current][callee_name] += 1
                        plain_refs[current].update(names - {callee_name})
                        args = call_args(line)
                        if args and any(a is not None and a[0] == "lit" for a in args):
                            literal_calls[current].append((callee_name, args))
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
    specialize(reverse, bodies, literal_calls, direct_calls, plain_refs,
               indirect_callers, indirect_sites)
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
