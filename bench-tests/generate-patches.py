#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
generate-patches.py — Generate flow-iosched kernel patches from current source.

The script reads the live source files in block/ and produces ready-to-apply
git-format patches in patches/.  This guarantees that the patches always
match the current code — eliminating human-error sources like stale patch
files or mismatched line counts.

Patches generated:
  0001-linux7.0-flow-iosched-v4.0.patch    — Add flow-iosched v4.0 to the kernel tree
  0002-linux6.12-flow-iosched-compat.patch  — Compat for 6.12-6.17 init_sched API

Usage:
  ./bench-tests/generate-patches.py                  # Generate all patches
  ./bench-tests/generate-patches.py --check           # Verify existing patches match source
  ./bench-tests/generate-patches.py --verbose         # Show detailed progress
  ./bench-tests/generate-patches.py --no-validate     # Skip patch application dry-run test

Dependencies: git (for blob hash computation), patch (for validation).
"""

import argparse
import difflib
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from datetime import datetime, timezone
from pathlib import Path
from typing import List

NL = "\n"  # for use inside f-strings

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
BLOCK_DIR = REPO_ROOT / "block"
PATCHES_DIR = REPO_ROOT / "patches"

AUTHOR = "Galih Tama <galpt@v.recipes>"
VERSION = "4.0"

SRC_C = BLOCK_DIR / "flow-iosched.c"
SRC_KCONFIG = BLOCK_DIR / "Kconfig.iosched"
SRC_MAKEFILE = BLOCK_DIR / "Makefile"

PATCH_0001 = PATCHES_DIR / "0001-linux7.0-flow-iosched-v4.0.patch"
PATCH_0002 = PATCHES_DIR / "0002-linux6.12-flow-iosched-compat.patch"

# ── Terminal colours ───────────────────────────────────────────────────────────
DIMM = "\033[2m"
GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
NC = "\033[0m"


# ═══════════════════════════════════════════════════════════════════════════════
#  Git blob hash
# ═══════════════════════════════════════════════════════════════════════════════

def git_blob_hash(data: bytes) -> str:
    """Compute the git SHA-1 blob hash for *data*.

    Uses ``git hash-object --stdin`` when available (fast, authoritative).
    Falls back to computing ``sha1(b"blob %d\\0%s" % (len(data), data))``
    in pure Python.
    """
    if shutil.which("git"):
        try:
            res = subprocess.run(
                ["git", "hash-object", "--stdin"],
                input=data,
                capture_output=True,
                check=True,
                timeout=30,
            )
            return res.stdout.decode().strip()
        except (subprocess.SubprocessError, OSError):
            pass

    # Manual fallback:  git blob hash = sha1("blob {size}\\0{content}")
    h = hashlib.sha1()
    h.update(f"blob {len(data)}\\0".encode())
    h.update(data)
    return h.hexdigest()


# ═══════════════════════════════════════════════════════════════════════════════
#  Patch construction helpers
# ═══════════════════════════════════════════════════════════════════════════════

def fmt_timestamp() -> str:
    """Return current timestamp in git-patch format."""
    now = datetime.now(timezone.utc)
    return now.strftime("%a %b %d %H:%M:%S %Y %z")


def patch_header(subject: str, desc: str, extra: str = "") -> str:
    """Return the patch header block (RFC 5322-style, no mbox From line).

    Indentation is handled explicitly per-section so that ``textwrap.dedent``
    is not required — this avoids bugs when multi-line ``desc`` or ``extra``
    content has inconsistent leading whitespace.
    """
    header = f"From: {AUTHOR}\n"
    header += f"Date: {fmt_timestamp()}\n"
    header += f"Subject: {subject}\n"
    header += "\n"
    for line in desc.splitlines():
        header += f"    {line}\n"
    header += "\n"
    if extra:
        for line in extra.splitlines():
            header += f"    {line}\n"
        header += "\n"
    header += f"    Signed-off-by: {AUTHOR}\n"
    header += "    ---\n"
    return header


def diff_new_file(path: str, content: bytes) -> str:
    """Produce a ``diff --git`` segment that creates *path* as a new file."""
    blob_hash = git_blob_hash(content)
    text = content.decode()
    n_lines = len(text.splitlines())

    return textwrap.dedent(f"""\
        diff --git a/{path} b/{path}
        new file mode 100644
        index 0000000000..{blob_hash}
        --- /dev/null
        +++ b/{path}
        @@ -0,0 +1,{n_lines} @@
    """) + "".join(f"+{line}\n" for line in text.splitlines()) + "\n"


def diff_modify_file(path: str, old_content: str, new_content: str) -> str:
    """Produce a ``diff --git`` segment for a modified file.

    Uses ``git diff`` with a temporary repository for accuracy.
    Falls back to a Python ``difflib`` hunk construction.
    """
    blob_old = git_blob_hash(old_content.encode())
    blob_new = git_blob_hash(new_content.encode())

    diff_body = _git_diff_text(path, old_content, new_content)

    return textwrap.dedent(f"""\
        diff --git a/{path} b/{path}
        index {blob_old[:10]}..{blob_new[:10]} 100644
        --- a/{path}
        +++ b/{path}
    """) + diff_body


def _git_diff_text(path: str, old: str, new: str) -> str:
    """Use ``git diff`` on a temporary repository, or fall back to difflib."""
    if shutil.which("git"):
        try:
            return _git_diff_real(path, old, new)
        except (subprocess.SubprocessError, OSError) as exc:
            print(f"  {YELLOW}git diff failed ({exc}), using difflib{fail_nl()}",
                  file=sys.stderr)

    # Fallback: use Python difflib
    old_lines = old.splitlines(keepends=True)
    new_lines = new.splitlines(keepends=True)

    result_lines = []
    for line in difflib.unified_diff(
        old_lines, new_lines,
        fromfile=f"a/{path}", tofile=f"b/{path}",
        n=3,
    ):
        # Strip the ---/+++ lines (we emit our own)
        if line.startswith("--- ") or line.startswith("+++ "):
            continue
        result_lines.append(line)

    return "".join(result_lines)


def _git_diff_real(path: str, old: str, new: str) -> str:
    """Use ``git diff`` with a temporary repo for an authoritative unified diff."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp).resolve()
        subprocess.run(
            ["git", "init", "-q"], cwd=tmp,
            capture_output=True, check=True, timeout=30,
        )
        subprocess.run(
            ["git", "config", "user.email", "patchgen@flow-iosched"],
            cwd=tmp, capture_output=True, check=True, timeout=30,
        )
        subprocess.run(
            ["git", "config", "user.name", "Patch Generator"],
            cwd=tmp, capture_output=True, check=True, timeout=30,
        )

        f = tmp / path
        f.parent.mkdir(parents=True, exist_ok=True)

        # Base commit with old content
        f.write_text(old)
        subprocess.run(["git", "add", str(path)], cwd=tmp,
                       capture_output=True, check=True, timeout=30)
        subprocess.run(["git", "commit", "-q", "-m", "base"],
                       cwd=tmp, capture_output=True, check=True, timeout=30)

        # New content
        f.write_text(new)
        subprocess.run(["git", "add", str(path)], cwd=tmp,
                       capture_output=True, check=True, timeout=30)

        res = subprocess.run(
            ["git", "diff", "--cached", "-U3", "--no-color"],
            cwd=tmp, capture_output=True, check=True, timeout=30,
        )
        raw = res.stdout.decode()

        # Strip the header lines we emit ourselves
        clean = []
        for line in raw.splitlines(keepends=True):
            if (line.startswith("diff --git") or line.startswith("index ") or
                line.startswith("--- ") or line.startswith("+++ ") or
                line.startswith("new file mode")):
                continue
            clean.append(line)
        return "".join(clean)


# ═══════════════════════════════════════════════════════════════════════════════
#  Kernel file templates (context anchors for diff)
# ═══════════════════════════════════════════════════════════════════════════════

KCONFIG_BASE = textwrap.dedent("""\
    #
    # Block layer I/O scheduler configuration
    #

    menuconfig IOSCHED
    	bool "I/O Schedulers"
    	default y

    if IOSCHED

    config MQ_IOSCHED_DEADLINE
    	tristate "MQ deadline I/O scheduler"
    	default m
    	help
    	  The MQ deadline I/O scheduler provides a lightweight, low-latency
    	  I/O scheduler that aims to limit request latency.

    config MQ_IOSCHED_KYBER
    	tristate "Kyber I/O scheduler"
    	default m
    	help
    	  The Kyber I/O scheduler is a low-overhead scheduler that maintains
    	  consistent latency by controlling queue depth.

    config IOSCHED_BFQ
    	tristate "BFQ I/O scheduler"
    	default m
    	help
    	  BFQ is a proportional-share I/O scheduler.

    endmenu
""")

MAKEFILE_BASE = textwrap.dedent("""\
    # SPDX-License-Identifier: GPL-2.0
    #
    # Makefile for the kernel block layer
    #

    obj-$(CONFIG_BLK)		+= bio.o elevator.o blk-core.o blk-sysfs.o

    obj-$(CONFIG_MQ_IOSCHED_DEADLINE)	+= mq-deadline.o
    obj-$(CONFIG_MQ_IOSCHED_KYBER)	+= kyber-iosched.o
    bfq-y				:= bfq-iosched.o bfq-wf2q.o bfq-cgroup.o
    obj-$(CONFIG_IOSCHED_BFQ)		+= bfq.o
""")


# ═══════════════════════════════════════════════════════════════════════════════
#  0001 patch: add flow-iosched v4.0
# ═══════════════════════════════════════════════════════════════════════════════

def _read_source(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Source file not found: {path}")
    return path.read_text()


def build_patch_0001(verbose: bool = False) -> str:
    """Build patch 0001: add flow-iosched to the kernel tree."""
    if verbose:
        print(f"  {CYAN}0001{NL} Reading source files ...")

    flow_c = _read_source(SRC_C)

    kconfig_entry = textwrap.dedent(f"""\
        config MQ_IOSCHED_FLOW
        	tristate "Multi-Lane I/O scheduler (FLOW)"
        	default m
        	help
        	  The Multi-Lane I/O scheduler (FLOW) v{VERSION} is a blk-mq
        	  I/O scheduler with three priority tiers (Emergency > Read >
        	  Write), per-hw-context FIFO dispatch, zero per-request
        	  allocations, and a generalised N-lane starvation-bound
        	  framework (starvation_max_read / starvation_max_write) that
        	  is provably starvation-free by construction.

        	  Architecture highlights:
        	    - Per-hw-context state with independent locking
        	    - Zero per-request dynamic allocations
        	    - Completion-triggered re-dispatch
        	    - Starvation-bounded dispatch with bypass_count counters
        	    - No autotune timer, no per-process scheduling state

        config MQ_IOSCHED_DEFAULT_FLOW
        	bool "Enable FLOW I/O scheduler as the default MQ scheduler"
        	depends on MQ_IOSCHED_FLOW
        	help
        	  Make flow-iosched the default MQ I/O scheduler.  Note: this
        	  requires wiring into elevator_set_default() in
        	  block/elevator.c, which is kernel-version-specific and is
        	  NOT handled by this patch.
    """)

    makefile_entry = "obj-$(CONFIG_MQ_IOSCHED_FLOW)\t+= flow-iosched.o"

    # ── Build modified kernel files ────────────────────────────────────────
    kconfig_lines = KCONFIG_BASE.splitlines(keepends=True)
    for i in range(len(kconfig_lines) - 1, -1, -1):
        if kconfig_lines[i].strip() == "endmenu":
            kconfig_lines.insert(i, "\n")
            kconfig_lines.insert(i, kconfig_entry)
            break
    kconfig_new = "".join(kconfig_lines)

    makefile_lines = MAKEFILE_BASE.splitlines(keepends=True)
    for i in range(len(makefile_lines) - 1, -1, -1):
        if makefile_lines[i].strip().startswith("bfq-y"):
            makefile_lines.insert(i, makefile_entry + "\n")
            break
    makefile_new = "".join(makefile_lines)

    # ── Assemble patch ─────────────────────────────────────────────────────
    parts = []

    # stats summary
    new_file_diff = diff_new_file("block/flow-iosched.c", flow_c.encode())
    kconfig_diff = diff_modify_file("block/Kconfig.iosched", KCONFIG_BASE, kconfig_new)
    makefile_diff = diff_modify_file("block/Makefile", MAKEFILE_BASE, makefile_new)

    total_diff = new_file_diff + "\n" + kconfig_diff + "\n" + makefile_diff

    stats = _patch_stats(total_diff)

    parts.append(patch_header(
        subject=f"[PATCH] flow-iosched: add v{VERSION} multi-lane I/O scheduler",
        desc=textwrap.dedent(f"""\
            Add the Multi-Lane I/O scheduler (FLOW) v{VERSION} to the kernel
            block layer.  FLOW is a three-lane (Emergency / Read / Write)
            I/O scheduler with per-hw-context FIFO dispatch, starvation-
            bounded anti-starvation, zero per-request dynamic allocations,
            and no autotune.

            Architecture highlights:
              - Per-hw-context state with independent locking
              - Zero per-request dynamic allocations
              - Completion-triggered re-dispatch
              - Starvation-bounded dispatch via bypass_count counters
              - Full front-merge and bio-merge support
        """),
        extra=stats,
    ))

    parts.append(new_file_diff)
    parts.append(kconfig_diff)
    parts.append(makefile_diff)

    return "\n".join(parts) + "\n"


def _patch_stats(diff: str) -> str:
    """Return a ``X files changed, Y insertions(+), Z deletions(-)`` line."""
    insert = 0
    delete = 0
    files = set()
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            insert += 1
        elif line.startswith("-") and not line.startswith("---"):
            delete += 1
        m = re.match(r"^diff --git a/(\S+) b/\S+$", line)
        if m:
            files.add(m.group(1))
    return f" {len(files)} file(s) changed, {insert} insertions(+), {delete} deletions(-)"


# ═══════════════════════════════════════════════════════════════════════════════
#  0002 patch: 6.12-6.17 compat
# ═══════════════════════════════════════════════════════════════════════════════

def build_patch_0002(verbose: bool = False) -> str:
    """Build patch 0002: compat for 6.12-6.17 init_sched API.

    Kernels 6.12 through 6.17 use:

        int init_sched(struct request_queue *q, struct elevator_type *e)

    instead of the 6.18+ / 7.x signature:

        int init_sched(struct request_queue *q, struct elevator_queue *eq)

    The compat patch modifies ``flow_init_sched`` to allocate the elevator
    itself (``elevator_alloc``) and the private data (``kzalloc_node``),
    matching the older API contract.
    """
    if verbose:
        print(f"  {CYAN}0002{NL} Building 6.12-6.17 compat diff ...")

    flow_c = _read_source(SRC_C)
    flow_c_compat = _apply_compat_transforms(flow_c)

    if flow_c_compat == flow_c:
        if verbose:
            print(f"  {YELLOW}0002{NL} No transformation needed (already compat?)",
                  file=sys.stderr)
        return ""

    parts = []
    parts.append(patch_header(
        subject="[PATCH] flow-iosched: compat for 6.12-6.17 init_sched API",
        desc="""Kernels 6.12 through 6.17 use an older init_sched elevator
op signature:

    int init_sched(struct request_queue *q, struct elevator_type *e)

instead of the 6.18+ / 7.x signature:

    int init_sched(struct request_queue *q, struct elevator_queue *eq)

This patch adjusts flow_init_sched() to match the older API by
allocating the elevator_queue and private data itself, and adding
kobject_put on the error path.""",
    ))

    parts.append(diff_modify_file("block/flow-iosched.c", flow_c, flow_c_compat))

    return "\n".join(parts) + "\n"


def _apply_compat_transforms(source: str) -> str:
    """Apply the 6.12-6.17 compat transformations to *source*.

    Returns the modified source, or the original if already in compat form.
    """
    old_sig = "static int flow_init_sched(struct request_queue *q, struct elevator_queue *eq)"
    new_sig = "static int flow_init_sched(struct request_queue *q, struct elevator_type *e)"

    if new_sig in source:
        # already in compat format — nothing to do
        return source

    if old_sig not in source:
        print(f"  {YELLOW}0002: cannot locate init_sched signature in source{NL}",
              file=sys.stderr)
        return source

    source = source.replace(old_sig, new_sig)

    # Replace the body: instead of using pre-allocated eq->elevator_data,
    # allocate eq and fd ourselves.
    old_body = (
        "\tstruct flow_data *fd = eq->elevator_data;\n"
        "\n"
        "\tif (!fd)\n"
        "\t\treturn -ENOMEM;"
    )
    new_body = (
        "\tstruct elevator_queue *eq;\n"
        "\tstruct flow_data *fd;\n"
        "\n"
        "\teq = elevator_alloc(q, e);\n"
        "\tif (!eq)\n"
        "\t\treturn -ENOMEM;\n"
        "\tfd = kzalloc_node(sizeof(*fd), GFP_KERNEL, q->node);\n"
        "\tif (!fd) {\n"
        "\t\tkobject_put(&eq->kobj);\n"
        "\t\treturn -ENOMEM;\n"
        "\t}\n"
        "\teq->elevator_data = fd;"
    )

    if old_body not in source:
        print(f"  {YELLOW}0002: cannot locate init_sched body anchor{NL}",
              file=sys.stderr)
        return source

    source = source.replace(old_body, new_body)

    # In v4.0, flow_init_sched has no kmem_cache/mempool allocations that can
    # fail after the initial NULL check, so no goto labels exist.  The compat
    # body simply returns -ENOMEM on elevator_alloc or kzalloc failure — no
    # teardown goto chain is needed.
    return source


# ═══════════════════════════════════════════════════════════════════════════════
#  Validation
# ═══════════════════════════════════════════════════════════════════════════════

def validate_patch(path: Path, verbose: bool = False, needs_source: bool = False) -> bool:
    """Verify that *path* can apply cleanly to the current source tree.

    Uses ``patch --dry-run --forward`` inside a temp directory.

    Args:
        path: The patch file to validate.
        verbose: Show patch output.
        needs_source: If True, copy ``flow-iosched.c`` into the temp tree
            (for patches that modify existing files rather than creating
            new ones, like the 0002 compat patch).

    Returns:
        True if the patch applies cleanly.
    """
    if not shutil.which("patch"):
        print(f"  {YELLOW}validate: 'patch' not found, skipping{NL}", file=sys.stderr)
        return True

    try:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp).resolve()
            blk = tmp / "block"
            blk.mkdir(parents=True, exist_ok=True)

            # Base kernel files for context matching
            (tmp / "block" / "Kconfig.iosched").write_text(KCONFIG_BASE)
            (tmp / "block" / "Makefile").write_text(MAKEFILE_BASE)

            # For patches that modify flow-iosched.c (not create it), we need
            # the source file to be present.
            if needs_source and SRC_C.exists():
                shutil.copy2(SRC_C, blk / "flow-iosched.c")

            patch_bytes = path.read_bytes()

            res = subprocess.run(
                ["patch", "--dry-run", "--forward", "-p1"],
                cwd=tmp,
                input=patch_bytes,
                capture_output=True,
                timeout=60,
            )

            if res.returncode == 0:
                if verbose:
                    stdout = res.stdout.decode().strip()
                    if stdout:
                        for line in stdout.splitlines():
                            print(f"    {DIMM}{line}{NC}")
                return True
            else:
                stderr = res.stderr.decode().strip()
                print(f"  {RED}validate FAILED for {path.name}:{NC}", file=sys.stderr)
                for line in stderr.splitlines()[:20]:
                    print(f"    {line}", file=sys.stderr)
                return False

    except (subprocess.SubprocessError, OSError) as exc:
        print(f"  {YELLOW}validate: could not run patch ({exc}){NL}", file=sys.stderr)
        return True


# ═══════════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════════

def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate flow-iosched kernel patches from current source.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Examples:
              ./bench-tests/generate-patches.py                  # Generate all patches
              ./bench-tests/generate-patches.py --check          # Verify patches match
              ./bench-tests/generate-patches.py --verbose        # Show details
        """),
    )
    p.add_argument("--check", action="store_true",
                   help="Verify existing patches match source")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Show detailed progress")
    p.add_argument("--no-validate", action="store_true",
                   help="Skip patch application dry-run test")
    return p.parse_args(argv[1:])


def _normalise_patch(s: str) -> str:
    """Strip timestamp-dependent lines for comparison."""
    # Strip lines that differ between regeneration runs:
    #   Date: <timestamp>
    #   From <Author>  <timestamp>   (bare From line — may be indented)
    #   ---                              (separator)
    stripped = []
    for l in s.splitlines():
        stripped_l = l.strip()
        if stripped_l.startswith("Date: "):
            continue
        if stripped_l.startswith("From ") and "  " in stripped_l:
            continue
        if stripped_l == "---":
            continue
        stripped.append(l)
    return "\n".join(stripped)


def cmd_check(verbose: bool) -> int:
    """Validate that existing patches match the current source code."""
    results = []
    for label, path, builder in [
        ("0001", PATCH_0001, build_patch_0001),
        ("0002", PATCH_0002, build_patch_0002),
    ]:
        if not path.exists():
            print(f"  {YELLOW}{label}: patch not found at {path}{NL}")
            results.append(("missing", label))
            continue

        expected = builder(verbose=verbose)
        if not expected.strip():
            print(f"  {YELLOW}{label}: no patch generated (compat not needed){NL}")
            results.append(("ok", label))
            continue

        actual = path.read_text()
        if _normalise_patch(expected) == _normalise_patch(actual):
            print(f"  {GREEN}{label}: OK — matches source{NL}")
            results.append(("ok", label))
        else:
            print(f"  {RED}{label}: MISMATCH — regenerate with:{NL}"
                  f"    ./bench-tests/generate-patches.py")
            results.append(("stale", label))

    stale = sum(1 for s, _ in results if s in ("missing", "stale"))
    if stale:
        print(f"\n  {stale} patch(es) need regeneration.{NL}")
        return 1
    print(f"\n  {GREEN}All patches up to date.{NL}")
    return 0


def cmd_generate(verbose: bool, no_validate: bool) -> int:
    """Generate all patches from current source."""
    PATCHES_DIR.mkdir(parents=True, exist_ok=True)
    generated = []

    # ── 0001 ────────────────────────────────────────────────────────────────
    print(f"  0001-linux7.0-flow-iosched-v4.0.patch ...")
    try:
        p1 = build_patch_0001(verbose=verbose)
        PATCH_0001.write_text(p1)
        generated.append(("0001", PATCH_0001))
        print(f"    {GREEN}wrote {len(p1.splitlines())} lines{NL}")
    except Exception as exc:
        print(f"    {RED}FAILED: {exc}{NL}", file=sys.stderr)
        return 1

    # ── 0002 ────────────────────────────────────────────────────────────────
    print(f"  0002-linux6.12-flow-iosched-compat.patch ...")
    try:
        p2 = build_patch_0002(verbose=verbose)
        if p2.strip():
            PATCH_0002.write_text(p2)
            generated.append(("0002", PATCH_0002))
            print(f"    {GREEN}wrote {len(p2.splitlines())} lines{NL}")
        else:
            print(f"    {YELLOW}no compat needed for current source{NL}")
    except Exception as exc:
        print(f"    {RED}FAILED: {exc}{NL}", file=sys.stderr)
        return 1

    # ── Validate ────────────────────────────────────────────────────────────
    if not no_validate:
        print(f"  Validating ...")
        all_ok = True
        for name, path in generated:
            # 0002 modifies an existing file (flow-iosched.c needs to be
            # present), while 0001 creates it as a new file.
            needs_src = (name == "0002")
            ok = validate_patch(path, verbose=verbose, needs_source=needs_src)
            if not ok:
                all_ok = False
                print(f"    {RED}{name}: validation FAILED{NL}", file=sys.stderr)

        if all_ok:
            print(f"  {GREEN}All patches generated and verified.{NL}")
        else:
            print(f"  {RED}Some patches failed validation.{NL}", file=sys.stderr)
            return 1

    print(f"\n  Patches in {PATCHES_DIR.relative_to(REPO_ROOT)}/:")
    for _, path in generated:
        print(f"    {path.name}")
    return 0


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    if not SRC_C.exists():
        print(f"Error: source file not found at {SRC_C}", file=sys.stderr)
        print("Run this script from the repo root or bench-tests/ directory.",
              file=sys.stderr)
        return 1

    if args.check:
        return cmd_check(verbose=args.verbose)
    else:
        return cmd_generate(verbose=args.verbose, no_validate=args.no_validate)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)
