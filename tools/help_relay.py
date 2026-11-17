#!/usr/bin/env python3
"""Serial-relay helper for help documents too large for one agent context.

A mega document (runtime/doc/vimfn.txt is 12 491 lines) cannot be read,
translated and byte-compared inside a single agent context, while the project
rule is one writer per doc/*.cnx. So the relay is *serial*: agents take
consecutive line ranges of the same file, one agent at a time, each only
appending its own range, and the file on disk is the only state.

An agent never copies an example-block body. It emits prose, then the fence line
verbatim, then exactly one ``@@BLOCK@@`` line per block in its range. That form is
the "skeleton", and it is checkable because:

  * help tags and |links| only ever exist *outside* block bodies, so the skeleton
    has exactly the tag set and link counts of the finished translation;
  * block bodies are re-injected from the pinned upstream by position, so a wide
    ASCII table can never be mangled by hand-copying.

``verify`` checks the skeleton while the file is incomplete; ``assemble`` injects
the bodies and applies the real byte-for-byte contract.

The fence predicate and the tag/block/link counters are imported from
tests/phase8/check_help_parity.py: there is exactly one parity engine.

Usage:
    python3 tools/help_relay.py plan     <name.txt> [--lines N]
    python3 tools/help_relay.py verify   <name.txt>
    python3 tools/help_relay.py assemble <name.txt>
    python3 tools/help_relay.py check-segment <name.txt> --from A --to B \
        --segment doc/<name>.cnx.segNN

Exit codes: 0 = PARTIAL/READY/COMPLETE/PASS as reported, 1 = FAIL, 2 = file missing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests' / 'phase8'))
import check_help_parity as parity  # noqa: E402

# The relay always reads the upstream the manifest pins, never "whatever Neovim
# happens to be installed": a different runtime silently produces a plan for
# text the translation was not written against. The directory is resolved
# (--runtime, then $NVIM_ZH_RUNTIME/$VIMRUNTIME, then a probe of $NVIM_BIN or
# nvim) and every file is checked against the manifest sha256 before use, so a
# wrong-version runtime fails loudly instead of poisoning a plan.
RUNTIME_DOC: Path | None = None
PLACEHOLDER = '@@BLOCK@@'
FENCE = re.compile(r'(^| )>[a-z0-9]*$')
FORBIDDEN = ('\u7a97\u53e3', '\u7f13\u51b2\u533a', '\u5bc4\u5b58\u5668')
WINDOW = 150  # search radius (in lines) for a safe cut point


def runtime_doc(explicit: str | None = None) -> Path:
    """The doc/ directory to read pinned upstream text from."""
    if explicit:
        path = Path(explicit)
    else:
        value = os.environ.get('NVIM_ZH_RUNTIME') or os.environ.get('VIMRUNTIME')
        if value and (Path(value) / 'doc').is_dir():
            path = Path(value)
        else:
            nvim = os.environ.get('NVIM_BIN', 'nvim')
            out = subprocess.run(
                [nvim, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
                capture_output=True, text=True, timeout=60,
                env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', '/tmp')})
            path = Path(out.stdout.strip())
    if (path / 'doc').is_dir():
        return path / 'doc'
    if path.is_dir() and any(path.glob('*.txt')):
        return path
    raise SystemExit(f'{path}: no doc/ directory to read; pass --runtime <$VIMRUNTIME>')


def _document_metadata(name: str) -> dict:
    """Return metadata only for an exact, safely anchored manifest basename."""
    if (not isinstance(name, str) or not name or Path(name).is_absolute()
            or Path(name).name != name or '/' in name or '\\' in name
            or name in ('.', '..')):
        raise SystemExit(f'invalid upstream document name {name!r}: expected a manifest basename')
    manifest = json.loads((ROOT / 'manifests/upstreams.json').read_text(encoding='utf-8'))
    documents = manifest['upstreams']['neovim']['documents']
    if name not in documents:
        raise SystemExit(f'{name}: not an exact basename registered in the upstream manifest')
    return documents[name]


def pinned_sha256(name: str) -> str:
    expected = _document_metadata(name).get('sha256')
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise SystemExit(f'{name}: missing or invalid pinned manifest sha256')
    return expected


def upstream_text(name: str) -> str:
    global RUNTIME_DOC
    expected = pinned_sha256(name)
    if RUNTIME_DOC is None:
        RUNTIME_DOC = runtime_doc()
    path = RUNTIME_DOC / name
    if path.is_symlink():
        raise SystemExit(f'{path}: pinned upstream source may not be a symlink')
    if not path.is_file():
        raise SystemExit(f'{path}: pinned upstream source not found')
    # ``name`` cannot contain a separator, so this also proves that resolving
    # the leaf did not escape the selected runtime through an ancestor link.
    if path.resolve(strict=True).parent != RUNTIME_DOC.resolve(strict=True):
        raise SystemExit(f'{path}: pinned upstream source escapes the runtime doc directory')
    raw = path.read_bytes()
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected:
        raise SystemExit(
            f'{path}: sha256 {actual} differs from the pinned manifest {expected}; '
            'this is not the pinned upstream runtime, refusing to build a plan from it')
    return raw.decode('utf-8')


def target(name: str) -> Path:
    """The file the relay is currently writing.

    ``doc/<name>.cnx`` is the finished translation. While a document is still in
    progress the same file is kept as ``doc/<name>.cnx.partial`` so that a
    half-written translation can never be picked up by ``:helptags``/``tags-cn``.
    Prefer the finished file when both exist, and fall back to the partial so
    ``verify``/``assemble`` work on an in-progress relay without renaming it.
    """
    pinned_sha256(name)  # validate the exact basename and fail closed on a missing pin
    doc_dir = ROOT / 'doc'
    if doc_dir.is_symlink():
        raise SystemExit(f'{doc_dir}: relay target directory may not be a symlink')
    path = doc_dir / (name[:-4] + '.cnx')
    partial = path.with_name(path.name + '.partial')
    for candidate in (path, partial):
        if candidate.is_symlink():
            raise SystemExit(f'{candidate}: relay target may not be a symlink')
    if not path.is_file() and partial.is_file():
        return partial
    return path


def split_lines(text: str) -> list[str]:
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return lines


def block_spans(lines: list[str]) -> list[tuple[int, int]]:
    """(fence_index, body_end_exclusive) per example block, in document order."""
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(lines):
        if FENCE.search(lines[index]):
            cursor = index + 1
            while cursor < len(lines) and not re.match(r'^[^ \t]', lines[cursor]):
                cursor += 1
            spans.append((index, cursor))
            index = cursor
        else:
            index += 1
    return spans


def skeleton(text: str) -> str:
    """Replace every example-block body with a single @@BLOCK@@ line."""
    out: list[str] = []
    lines = split_lines(text)
    index = 0
    while index < len(lines):
        out.append(lines[index])
        if FENCE.search(lines[index]):
            cursor = index + 1
            while cursor < len(lines) and not re.match(r'^[^ \t]', lines[cursor]):
                cursor += 1
            out.append(PLACEHOLDER)
            index = cursor
        else:
            index += 1
    return '\n'.join(out) + '\n'


def _validate_target_lines(target_lines: int) -> None:
    if isinstance(target_lines, bool) or not isinstance(target_lines, int) or target_lines <= 0:
        raise ValueError(f'target_lines must be a positive integer, got {target_lines!r}')


def plan(name: str, target_lines: int) -> list[dict]:
    """Consecutive 1-based line ranges that never split an example block.

    A cut is allowed only on a blank line at column 0 outside any block, so every
    range contains whole blocks and an agent is never handed half a code sample.
    If no safe cut exists, retain the old all-remaining-lines fallback for corpus
    compatibility, but mark and report it explicitly instead of hiding it.
    """
    _validate_target_lines(target_lines)
    lines = split_lines(upstream_text(name))
    total = len(lines)
    inside = [False] * total
    for start, end in block_spans(lines):
        for i in range(start, end):
            inside[i] = True
    ranges: list[tuple[int, int]] = []
    unsplittable: set[int] = set()
    start = 0
    while start < total:
        want = min(start + target_lines, total)
        if want >= total:
            ranges.append((start, total))
            break
        best: int | None = None
        best_distance = None
        for cut in range(max(start + 1, want - WINDOW), min(total, want + WINDOW)):
            if (lines[cut].strip() == '' and not inside[cut]
                    and (cut + 1 == total or not inside[cut + 1])):
                distance = abs(cut - want)
                if best_distance is None or distance < best_distance:
                    best, best_distance = cut, distance
        if best is None or best <= start:
            unsplittable.add(len(ranges))
            ranges.append((start, total))
            break
        ranges.append((start, best))
        start = best
    rows: list[dict] = []
    for index, (a, b) in enumerate(ranges):
        sk = skeleton('\n'.join(lines[a:b]) + '\n')
        cannot_split = index in unsplittable
        oversized = cannot_split and b - a > target_lines
        warning = ''
        if cannot_split:
            warning = (f'unsplittable segment={index + 1} range={a + 1}-{b} '
                       f'lines={b - a} target_lines={target_lines}: no safe cut within '
                       f'WINDOW={WINDOW}; keeping all remaining lines together'
                       + (' (oversized)' if oversized else ''))
        rows.append({
            'segment': index + 1,
            'from': a + 1,
            'to': b,
            'lines': b - a,
            'blocks': sk.count(PLACEHOLDER),
            'tags': len(set(parity.tags(sk))),
            'links': sum(parity.links(sk).values()),
            'oversized': oversized,
            'unsplittable': cannot_split,
            'warning': warning,
        })
    return rows


def print_plan_warnings(rows: list[dict], upto: int | None = None) -> None:
    """Report fallback ranges without changing the established success code."""
    for row in rows:
        if row['unsplittable'] and (upto is None or row['segment'] <= upto):
            print(f'RELAY_WARNING={row["warning"]}')


def upstream_bodies(name: str, text_hint: str = '') -> list[list[str]]:
    """Example-block bodies as *line lists*, in document order.

    Deliberately not `parity.example_blocks()`: that joins a body with "\\n", so a
    block with no body lines and a block with one blank line both become `''`.
    Upstream has 4 such empty blocks (motion.txt), and injecting one blank line
    where upstream had none would break the byte-for-byte contract. Working from
    `block_spans()` indices keeps `[]` and `['']` distinct.
    """
    lines = split_lines(upstream_text(name))
    return [lines[start + 1:end] for start, end in block_spans(lines)]


def _fences(text: str) -> list[int]:
    return [i for i, line in enumerate(split_lines(text)) if FENCE.search(line)]


def skeleton_structure_problems(text: str, require_terminator: bool = False) -> list[str]:
    """Check the one-to-one ``fence / immediate placeholder`` skeleton shape.

    The same engine guards whole relay files and independent segments. In
    segment mode a placeholder must additionally end at EOF or at a column-0,
    non-blank line so injection cannot swallow following prose. A following
    fence is a valid terminator, which preserves consecutive example blocks.
    """
    problems: list[str] = []
    lines = split_lines(text)
    fences = _fences(text)
    placeholders = [i for i, line in enumerate(lines) if line == PLACEHOLDER]
    if len(fences) != len(placeholders):
        problems.append(f'fence lines {len(fences)} != placeholder lines {len(placeholders)}; '
                        'every fence must be followed by exactly one @@BLOCK@@ line')
    for i, line in enumerate(lines):
        if PLACEHOLDER in line and line != PLACEHOLDER:
            if line.strip() == PLACEHOLDER:
                problems.append(f'indented placeholder at line {i + 1}')
            else:
                problems.append(f'placeholder at line {i + 1} is not a standalone line')
    for i in fences:
        if i + 1 >= len(lines) or lines[i + 1] != PLACEHOLDER:
            problems.append(f'fence at line {i + 1} is not immediately followed by @@BLOCK@@')
    for i in placeholders:
        if i == 0 or not FENCE.search(lines[i - 1]):
            problems.append(f'placeholder at line {i + 1} does not follow a fence line')
        if require_terminator:
            following = lines[i + 1] if i + 1 < len(lines) else None
            if following is not None and (following == '' or following[0] in ' \t'):
                problems.append(f'placeholder at line {i + 1} is not terminated by a '
                                'column-0 line')
    return problems


def _gate(text: str, upstream: str) -> tuple[str, list[str], dict]:
    """Contract checks that hold for the skeleton *and* the finished file.

    Returns (state, problems, stats). The tag/link expectation depends on how far
    the relay has got:

      placeholders remain -> compare with the upstream *skeleton*, because the
          agent has not written any block bodies yet, and block bodies can
          contain |links| (api.txt has 2, lua.txt 5, vimfn.txt 1);
      no placeholders     -> compare with the *full* upstream text, which is what
          a finished (or already-injected) translation must match exactly.

    Using the skeleton for a finished file would report a false FAIL, and using
    the full text mid-relay would report every not-yet-written tag as missing.
    """
    problems: list[str] = []
    tr_blocks = text.count(PLACEHOLDER)
    reference = upstream if tr_blocks == 0 else skeleton(upstream)
    up_tags = set(parity.tags(reference))
    tr_tags = set(parity.tags(text))
    tr_list = parity.tags(text)
    up_links = parity.links(reference)
    tr_links = parity.links(text)
    up_blocks = skeleton(upstream).count(PLACEHOLDER)

    extra = sorted(tr_tags - up_tags)
    if extra:
        problems.append(f'unverified tags: {extra[:10]}')
    dup = sorted({t for t in tr_tags if tr_list.count(t) > 1})
    if dup:
        problems.append(f'duplicated tags: {dup[:10]}')
    exceeded = sorted({k for k in tr_links if tr_links[k] > up_links.get(k, 0)})
    if exceeded:
        problems.append(f'link count exceeded: {exceeded[:10]}')
    hit = [w for w in FORBIDDEN if w in text]
    if hit:
        problems.append(f'glossary violation: {hit}')
    raw = text.encode('utf-8')
    if raw[:3] == b'\xef\xbb\xbf' or b'\r' in raw or not raw.endswith(b'\n'):
        problems.append('encoding: BOM/CRLF/missing final newline')
    if tr_blocks > up_blocks:
        problems.append(f'placeholder overflow: {tr_blocks} > upstream blocks {up_blocks}')

    # In-progress invariant: the skeleton is exactly "fence line, then @@BLOCK@@".
    # Every fence the agent wrote must own a placeholder, and no placeholder may
    # appear under anything but a fence. Finished files have real bodies instead,
    # so this structural check applies only while placeholders remain.
    if tr_blocks:
        problems.extend(skeleton_structure_problems(text))
    if problems:
        return 'FAIL', problems, {}

    stats = {
        'tags': len(tr_tags), 'up_tags': len(up_tags),
        'links': sum(tr_links.values()), 'up_links': sum(up_links.values()),
        'blocks': tr_blocks, 'up_blocks': up_blocks,
        'missing_tags': len(up_tags - tr_tags),
    }
    if tr_blocks == 0:
        if up_tags == tr_tags:
            if tr_links != up_links:
                changed = sorted(k for k in set(up_links) | set(tr_links)
                                 if up_links.get(k, 0) != tr_links.get(k, 0))
                return 'FAIL', [f'link multiset differs for {changed[:10]}'], stats
            return 'COMPLETE', [], stats
        return 'PARTIAL', [], stats
    if tr_blocks == up_blocks and up_tags == tr_tags:
        if tr_links != up_links:
            changed = sorted(k for k in set(up_links) | set(tr_links)
                             if up_links.get(k, 0) != tr_links.get(k, 0))
            return 'FAIL', [f'link multiset differs for {changed[:10]}'], stats
        return 'READY', [], stats
    return 'PARTIAL', [], stats


def range_skeletons(name: str, target_lines: int) -> list[dict]:
    """Plan rows extended with each range's skeleton and tag set."""
    lines = split_lines(upstream_text(name))
    rows = plan(name, target_lines)
    for row in rows:
        sk = skeleton('\n'.join(lines[row['from'] - 1:row['to']]) + '\n')
        row['skeleton'] = sk
        row['tag_set'] = set(parity.tags(sk))
    return rows


def cumulative(name: str, target_lines: int, upto: int) -> dict:
    """Exact expected state after ranges 1..upto have been appended.

    The planned ranges partition the upstream file line by line and never split
    an example block, so tags, |links| and block counts add up across ranges and
    the tag set is their union. That makes the per-range check exact rather than
    a lower bound, and it pins any mismatch to range ``upto``: an agent that
    invents a tag, copies a neighbour's tag line or forgets a placeholder is
    caught at its own range instead of after 40 ranges of relay work.
    """
    if isinstance(upto, bool) or not isinstance(upto, int) or upto <= 0:
        raise ValueError(f'--upto must be a positive integer, got {upto!r}')
    rows = range_skeletons(name, target_lines)
    if upto > len(rows):
        raise ValueError(f'--upto {upto} exceeds planned ranges {len(rows)}')
    rows = rows[:upto]
    tags: set[str] = set()
    links: dict[str, int] = {}
    blocks = 0
    for row in rows:
        tags |= row['tag_set']
        blocks += row['blocks']
        for link, count in parity.links(row['skeleton']).items():
            links[link] = links.get(link, 0) + count
    return {'tags': tags, 'links': links, 'blocks': blocks}


def verify(name: str, upto: int | None = None, target_lines: int = 300) -> int:
    """Skeleton-level check of a relay file in progress (or a finished one).

      MISSING   file not created yet.
      FAIL      invented/duplicated tags, exceeded link counts, glossary hits,
                placeholder overflow, a placeholder not under its fence line,
                bad encoding.
      PARTIAL   more ranges still to write (counts are reported, nothing is
                claimed as done).
      READY     every range written, all tags present, placeholders remain: run
                ``assemble`` to inject the block bodies.
      COMPLETE  no placeholders, tags and links exactly equal upstream.
    """
    try:
        _validate_target_lines(target_lines)
        if upto is not None and (isinstance(upto, bool) or not isinstance(upto, int) or upto <= 0):
            raise ValueError(f'--upto must be a positive integer, got {upto!r}')
    except ValueError as error:
        print(f'RELAY_PROBLEM={error}')
        print(f'RELAY_VERIFY=FAIL name={name}')
        return 1
    path = target(name)
    if not path.is_file():
        print(f'RELAY_VERIFY=MISSING {path}')
        return 2
    text = path.read_text(encoding='utf-8')
    upstream = upstream_text(name)
    state, problems, stats = _gate(text, upstream)
    # Validate --upto even for an assembled file; otherwise a complete file used
    # to hide impossible range arguments. The cumulative comparison itself is a
    # skeleton-level expectation and applies only while placeholders remain.
    if upto is not None and not problems:
        rows = plan(name, target_lines)
        if upto > len(rows):
            problems.append(f'--upto {upto} exceeds planned ranges {len(rows)}')
        else:
            print_plan_warnings(rows, upto)
            if text.count(PLACEHOLDER):
                exp = cumulative(name, target_lines, upto)
                tr_tags = set(parity.tags(text))
                tr_links = parity.links(text)
                tr_blocks = text.count(PLACEHOLDER)
                missing = sorted(exp['tags'] - tr_tags)
                extra = sorted(tr_tags - exp['tags'])
                if missing:
                    problems.append(f'range {upto} did not contribute tags: {missing[:10]}')
                if extra:
                    problems.append(f'tags beyond range {upto}, copied from a later '
                                    f'range?: {extra[:10]}')
                if tr_blocks != exp['blocks']:
                    problems.append(f'range {upto}: placeholders {tr_blocks} != planned '
                                    f'{exp["blocks"]}')
                ldiff = sorted({k for k in set(exp['links']) | set(tr_links)
                                if exp['links'].get(k, 0) != tr_links.get(k, 0)})
                if ldiff:
                    problems.append(f'range {upto}: link counts differ for {ldiff[:10]}')
    if problems:
        state = 'FAIL'
    for problem in problems:
        print(f'RELAY_PROBLEM={problem}')
    if stats:
        print(('RELAY_VERIFY=%s name=%s tags=%d/%d placeholders=%d/%d links=%d/%d '
               'missing_tags=%d')
              % (state, name, stats['tags'], stats['up_tags'], stats['blocks'],
                 stats['up_blocks'], stats['links'], stats['up_links'],
                 stats['missing_tags']))
    else:
        print(f'RELAY_VERIFY={state} name={name}')
    return 1 if problems else 0


def inject_text(name: str, current: str) -> tuple[str, list[str]]:
    """Replace each @@BLOCK@@ line with the next upstream block body, verbatim.

    Bodies come from ``upstream_bodies`` as line lists, so an empty block injects
    zero lines and a block whose body is one blank line injects that blank line.
    """
    bodies = upstream_bodies(name)
    found = current.count(PLACEHOLDER)
    if found != len(bodies):
        return current, [f'placeholders={found} upstream_blocks={len(bodies)}']
    out: list[str] = []
    cursor = 0
    for line in current.split('\n'):
        if line == PLACEHOLDER:
            out.extend(bodies[cursor])
            cursor += 1
        else:
            out.append(line)
    rebuilt = '\n'.join(out)
    if not rebuilt.endswith('\n'):
        rebuilt += '\n'
    if PLACEHOLDER in rebuilt:
        return current, ['placeholder survived injection']
    return rebuilt, []


def _assembly_check(name: str, upstream: str, tr: str) -> tuple[list[str], dict]:
    """Run the complete post-injection contract without touching the target."""
    problems: list[str] = []
    up_tags, tr_tags = set(parity.tags(upstream)), set(parity.tags(tr))
    if tr_tags - up_tags:
        problems.append(f'unverified tags {sorted(tr_tags - up_tags)[:10]}')
    if up_tags - tr_tags:
        problems.append(f'missing tags {sorted(up_tags - tr_tags)[:10]}')
    dup = sorted({t for t in tr_tags if parity.tags(tr).count(t) > 1})
    if dup:
        problems.append(f'duplicated tags {dup[:10]}')
    sb, tb = parity.example_blocks(upstream), parity.example_blocks(tr)
    if len(sb) != len(tb):
        problems.append(f'block count {len(tb)} != {len(sb)}')
    else:
        bad = [i for i, (a, b) in enumerate(zip(sb, tb), 1) if a != b]
        if bad:
            problems.append(f'blocks diverge at {bad[:10]}')
    sl, tl = parity.links(upstream), parity.links(tr)
    ldiff = sorted({k for k in set(sl) | set(tl) if sl.get(k, 0) != tl.get(k, 0)})
    if ldiff:
        problems.append(f'link diff {ldiff[:10]}')
    hits = sum(tr.count(w) for w in FORBIDDEN)
    if hits:
        problems.append(f'glossary hits {hits}')
    if name not in tr_tags:
        problems.append(f'dropped its own file tag {name}')
    stats = {'lines': len(split_lines(tr)), 'tags': len(tr_tags),
             'blocks': len(tb), 'links': sum(tl.values())}
    return problems, stats


def _atomic_write(path: Path, text: str) -> None:
    """Replace ``path`` only after the complete temporary file is durable."""
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
                mode='w', encoding='utf-8', newline='', dir=path.parent,
                prefix=f'.{path.name}.', suffix='.tmp', delete=False) as out:
            temporary = out.name
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def assemble(name: str) -> int:
    """Validate injection and the full contract before one atomic replacement."""
    path = target(name)
    if not path.is_file():
        print(f'RELAY_ASSEMBLE=NO_FILE {path}')
        return 2
    upstream = upstream_text(name)
    current = path.read_text(encoding='utf-8')
    rebuilt, problems = inject_text(name, current)
    if problems:
        for problem in problems:
            print(f'RELAY_PROBLEM={problem}')
        print(f'RELAY_ASSEMBLE=FAIL name={name} (file left untouched)')
        return 1

    # No write or chmod is permitted until every skeleton and assembled-file
    # check has returned. Any validation exception therefore leaves the original
    # bytes and mode intact; _atomic_write gives the same guarantee on I/O errors
    # before the final os.replace().
    _, gate_problems, _ = _gate(current, upstream)
    _, rebuilt_gate_problems, _ = _gate(rebuilt, upstream)
    check_problems, stats = _assembly_check(name, upstream, rebuilt)
    problems.extend(gate_problems)
    problems.extend(rebuilt_gate_problems)
    problems.extend(check_problems)
    for problem in problems:
        print(f'RELAY_PROBLEM={problem}')
    if problems:
        print('RELAY_ASSEMBLE=FAIL name=%s lines=%d tags=%d blocks=%d links=%d '
              '(file left untouched)'
              % (name, stats['lines'], stats['tags'], stats['blocks'], stats['links']))
        return 1
    _atomic_write(path, rebuilt)
    print('RELAY_ASSEMBLE=PASS name=%s lines=%d tags=%d blocks=%d links=%d'
          % (name, stats['lines'], stats['tags'], stats['blocks'], stats['links']))
    return 0


def check_segment(name: str, frm: int, to: int, seg_path: str) -> int:
    """Check one relay segment against the skeleton of its exact upstream range.

    Segments are written independently (one agent per range), so each one must be
    verifiable on its own before the ranges are concatenated. The expectation is
    the skeleton of ``upstream[frm-1:to]``: same tag set, same |link| counts, same
    number of example blocks, and every ``@@BLOCK@@`` terminated by a column-0
    line (otherwise the injected body would swallow the following prose).
    """
    up = split_lines(upstream_text(name))
    if not 1 <= frm <= to <= len(up):
        print(f'SEGMENT_PROBLEM=bad range {frm}-{to} (upstream has {len(up)} lines)')
        print('SEGMENT_CHECK=FAIL')
        return 1
    path = Path(seg_path)
    if not path.is_file():
        print(f'SEGMENT_PROBLEM=missing segment file {path}')
        print('SEGMENT_CHECK=FAIL')
        return 1
    text = path.read_text(encoding='utf-8')
    expected = skeleton('\n'.join(up[frm - 1:to]) + '\n')
    problems: list[str] = []

    up_tags, tr_tags = set(parity.tags(expected)), set(parity.tags(text))
    tr_list = parity.tags(text)
    for tag in sorted(up_tags - tr_tags):
        problems.append(f'missing tag {tag}')
    for tag in sorted(tr_tags - up_tags):
        problems.append(f'unverified tag {tag}')
    dup = sorted({t for t in tr_tags if tr_list.count(t) > 1})
    if dup:
        problems.append(f'duplicated tags {dup[:10]}')

    exp_blocks, tr_blocks = expected.count(PLACEHOLDER), text.count(PLACEHOLDER)
    if exp_blocks != tr_blocks:
        problems.append(f'placeholders {tr_blocks} != expected {exp_blocks}')

    up_links, tr_links = parity.links(expected), parity.links(text)
    ldiff = sorted({k for k in set(up_links) | set(tr_links)
                    if up_links.get(k, 0) != tr_links.get(k, 0)})
    if ldiff:
        problems.append(f'link diff {ldiff[:10]}')

    hit = [w for w in FORBIDDEN if w in text]
    if hit:
        problems.append(f'glossary violation {hit}')
    raw = text.encode('utf-8')
    if raw[:3] == b'\xef\xbb\xbf' or b'\r' in raw or not raw.endswith(b'\n'):
        problems.append('encoding: BOM/CRLF/missing final newline')

    lines = split_lines(text)
    problems.extend(skeleton_structure_problems(text, require_terminator=True))

    for problem in problems:
        print(f'SEGMENT_PROBLEM={problem}')
    print('SEGMENT_CHECK=%s name=%s range=%d-%d lines=%d blocks=%d/%d tags=%d/%d '
          'links=%d/%d'
          % ('FAIL' if problems else 'PASS', name, frm, to, len(lines),
             tr_blocks, exp_blocks, len(tr_tags), len(up_tags),
             sum(tr_links.values()), sum(up_links.values())))
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    global RUNTIME_DOC
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command',
                        choices=('plan', 'verify', 'assemble', 'check-segment'))
    parser.add_argument('name', help='upstream file name, e.g. vimfn.txt')
    parser.add_argument('--runtime',
                        help='$VIMRUNTIME to read pinned upstream text from (defaults to '
                             '$NVIM_ZH_RUNTIME/$VIMRUNTIME or a probe of $NVIM_BIN/nvim)')
    parser.add_argument('--lines', type=int, default=300, help='target lines per range')
    parser.add_argument('--upto', type=int, default=None,
                        help='verify against the exact cumulative expectation for '
                             'ranges 1..N (the range the last agent just wrote)')
    parser.add_argument('--from', dest='frm', type=int,
                        help='check-segment: first upstream line (1-based)')
    parser.add_argument('--to', dest='to', type=int,
                        help='check-segment: last upstream line (1-based, inclusive)')
    parser.add_argument('--segment', help='check-segment: segment file to check')
    args = parser.parse_args(argv)
    RUNTIME_DOC = runtime_doc(args.runtime)
    name = args.name
    if args.command == 'plan':
        try:
            rows = plan(name, args.lines)
        except ValueError as error:
            print(f'RELAY_PROBLEM={error}')
            print(f'RELAY_PLAN=FAIL name={name}')
            return 1
        for row in rows:
            print('SEG=%d %d-%d lines=%d blocks=%d tags=%d links=%d'
                  % (row['segment'], row['from'], row['to'], row['lines'],
                     row['blocks'], row['tags'], row['links']))
        print_plan_warnings(rows)
        print('RELAY_PLAN=%s segments=%d total_blocks=%d total_lines=%d '
              'oversized=%d unsplittable=%d'
              % (name, len(rows), sum(r['blocks'] for r in rows),
                 sum(r['lines'] for r in rows), sum(r['oversized'] for r in rows),
                 sum(r['unsplittable'] for r in rows)))
        return 0
    if args.command == 'verify':
        return verify(name, args.upto, args.lines)
    if args.command == 'check-segment':
        if args.frm is None or args.to is None or not args.segment:
            print('SEGMENT_PROBLEM=check-segment needs --from, --to and --segment')
            print('SEGMENT_CHECK=FAIL')
            return 2
        return check_segment(name, args.frm, args.to, args.segment)
    return assemble(name)


if __name__ == '__main__':
    raise SystemExit(main())
