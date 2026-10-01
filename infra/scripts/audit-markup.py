#!/usr/bin/env python3
"""
audit-markup.py — add semantic markup (module headers + per-function contracts) to unmarked
.rs/.zig source files in the bsdOS project.

Idempotent: files that already have START_AI_HEADER are skipped. Each per-function contract
inserts `// NAME:start` + a 4-line contract block BEFORE the function and `// NAME:end`
on its own line AFTER the function body (brace-matched, so it always lands on the right line).

Usage:
  audit-markup.py                       # scan and mark all unmarked sources
  audit-markup.py PATH [PATH ...]       # mark specific files
  audit-markup.py --list                # list unmarked files (no edits)
  audit-markup.py --status              # show per-subsystem coverage stats

Detects project root from the script location (../../ from infra/scripts/), so it works
when copied around the repo. See SEMANTIC_MARKUP.md for the contract format and trigger
rules — the inserted stubs use the same `// purpose:/input:/output:/sideEffects:` shape
that the rest of the codebase uses.
"""
import argparse
import os
import re
import sys
from pathlib import Path

FN_RS  = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
FN_ZIG = re.compile(r"^\s*(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")

EXCLUDE_DIRS = {"target", ".zig-cache", "zig-out", "node_modules", ".git",
                "artefacts", ".virtfs_metadata", "ui-plasma-qml/build",
                "zenoh-link-commons-patched"}
EXCLUDE_FILES = {"build.zig", "build.rs"}  # config, not logic — skip the body scan

def detect_lang(path: Path) -> str:
    return "rust" if path.suffix == ".rs" else "zig" if path.suffix == ".zig" else ""

def has_header(text: str) -> bool:
    return "START_AI_HEADER" in text

def find_open_brace(lines, start_idx):
    for i in range(start_idx, len(lines)):
        if '{' in lines[i]:
            return i
    return -1

def find_function_end(lines, open_brace_idx):
    """Walk from open_brace_idx forward to find the matching close brace."""
    depth = 0
    for i in range(open_brace_idx, len(lines)):
        for ch in lines[i]:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return i
    return len(lines) - 1

def module_path(file: Path, root: Path) -> str:
    rel = file.relative_to(root)
    return str(rel)

def contract_block(name: str, indent: str) -> str:
    return (
        f"{indent}// {name}:start\n"
        f"{indent}//   purpose: TODO: describe what {name} does (see SEMANTIC_MARKUP.md).\n"
        f"{indent}//   input:  TODO: list parameters with their meaning.\n"
        f"{indent}//   output: TODO: describe return value and error semantics.\n"
        f"{indent}//   sideEffects: TODO: list file/network/registry/zenoh effects; 'none' if pure.\n"
    )

def module_header(mod_path: str) -> str:
    return (
        "// START_AI_HEADER\n"
        f"// MODULE: {mod_path}\n"
        "// PURPOSE: TODO: what this module is for.\n"
        "// INTENT: TODO: why this module exists; what design constraint or workaround it captures.\n"
        "// DEPENDENCIES: TODO: list crates / @import modules / libc headers used.\n"
        "// PUBLIC_API: TODO: list exported types, functions, and constants.\n"
        "// END_AI_HEADER\n"
        "\n"
    )

def process_file(path: Path, root: Path) -> tuple[str, str]:
    """Return (status, msg) where status is one of: 'marked', 'skipped', 'error'."""
    try:
        text = path.read_text()
    except Exception as e:
        return "error", str(e)
    if has_header(text):
        return "skipped", "already-marked"
    lang = detect_lang(path)
    if not lang:
        return "skipped", "skip-non-source"
    fn_pat = FN_RS if lang == "rust" else FN_ZIG

    lines = text.splitlines(keepends=True)
    mod_path = module_path(path, root)

    # Find function defs (line index, name, brace line)
    fns = []
    for i, line in enumerate(lines):
        m = fn_pat.match(line)
        if m:
            name = m.group(1)
            brace = find_open_brace(lines, i)
            if brace >= 0:
                fns.append((i, name, brace))

    if not fns:
        new = module_header(mod_path) + text
        path.write_text(new)
        return "marked", "header-only"

    out = list(lines)
    # Walk in reverse so earlier offsets stay valid as we insert.
    for start_line, name, brace_line in reversed(fns):
        body_end = find_function_end(out, brace_line)
        m_indent = re.match(r"^(\s*)", out[start_line])
        indent = m_indent.group(1) if m_indent else ""
        out.insert(body_end + 1, f"{indent}// {name}:end\n")
        out.insert(start_line, contract_block(name, indent))

    final = module_header(mod_path) + "".join(out)
    path.write_text(final)
    return "marked", f"marked {len(fns)} fns"

def collect_sources(root: Path):
    """Yield (path, has_header) for every .rs/.zig under root, respecting EXCLUDE_DIRS."""
    for dirpath, dirnames, filenames in os.walk(root):
        # prune excluded dirs
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_DIRS]
        for fn in filenames:
            if fn not in EXCLUDE_FILES and fn.endswith((".rs", ".zig")):
                p = Path(dirpath) / fn
                try:
                    has = has_header(p.read_text())
                except Exception:
                    continue
                yield p, has

def cmd_list(root: Path):
    unmarked = 0
    for p, has in collect_sources(root):
        if not has:
            print(p.relative_to(root))
            unmarked += 1
    print(f"\nunmarked files: {unmarked}", file=sys.stderr)

def cmd_status(root: Path):
    by_dir: dict[str, tuple[int, int]] = {}
    for p, has in collect_sources(root):
        rel = p.relative_to(root)
        top = rel.parts[0] if len(rel.parts) > 1 else "<root>"
        marked, total = by_dir.get(top, (0, 0))
        by_dir[top] = (marked + (1 if has else 0), total + 1)
    print(f"{'subsystem':<30} {'marked':>8} {'total':>8} {'%':>6}")
    for top, (m, t) in sorted(by_dir.items()):
        pct = 100 * m // t if t else 0
        print(f"{top:<30} {m:>8} {t:>8} {pct:>5}%")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="Files to mark (default: all unmarked under project root)")
    ap.add_argument("--list", action="store_true", help="List unmarked files (no edits)")
    ap.add_argument("--status", action="store_true", help="Per-subsystem coverage stats")
    args = ap.parse_args()

    # Project root: parent of parent of this script's dir (infra/scripts/<file> → root).
    script_dir = Path(__file__).resolve().parent
    root = script_dir.parent.parent

    if args.list:
        cmd_list(root)
        return 0
    if args.status:
        cmd_status(root)
        return 0

    targets = []
    for p in args.paths if args.paths else [
        str(p) for p, has in collect_sources(root) if not has
    ]:
        pp = Path(p)
        if not pp.is_absolute():
            pp = (root / pp).resolve()
        targets.append(pp)

    n_marked = n_skipped = n_err = 0
    for p in targets:
        if not p.exists():
            print(f"MISSING: {p}", file=sys.stderr)
            n_err += 1
            continue
        status, msg = process_file(p, root)
        if status == "marked":
            n_marked += 1
            print(f"OK  {p}: {msg}")
        elif status == "skipped":
            n_skipped += 1
        else:
            n_err += 1
            print(f"ERR {p}: {msg}", file=sys.stderr)
    print(f"\nmarked={n_marked} skipped={n_skipped} errors={n_err}", file=sys.stderr)
    return 0 if n_err == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
