"""Report every help-parity break between a doc/*.cnx translation and upstream.

01_help_catalog_spec.lua asserts the same contract but aborts on the first
failure, which makes a full-document translation painful to iterate on. This
checker applies the identical rules (tags, example blocks, @-style links) and
prints *all* differences, then exits non-zero if any remain. It is a strict
gate wired into tests/run/integration.sh, not a replacement for the Lua spec.

The upstream side is the runtime the manifest pins. A runtime that is not that
baseline cannot answer parity questions: it may not ship a pinned document at
all (0.11.5 lacks 10 of the 133, nightly dropped pi_zip.txt) or may ship
different English text (0.11.5 has *deprecated-0.11*, the pinned baseline has
*deprecated-0.12*). Instead of asserting pinned text against it, the checker
reports HELP_PARITY=SKIP and exits 0; the translation contract itself is still
enforced on every version by the Lua specs and the other Help tools.
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
TAG_STOP = set(' \t\n*')


def _open_fence(line: str) -> bool:
    """help.vim helpExample start="\\%(^\\| \\)>[a-z0-9]*$"."""
    return re.search(r'(^| )>[a-z0-9]*$', line) is not None


def tags(text: str) -> list[str]:
    """Mirror of the tag scanner in 01_help_catalog_spec.lua.

    Like Neovim's :helptags, a "*tag*" inside an example block is example text
    and is not a real help tag. helphelp.txt documents the help-file header
    format inside such a block, so a raw-text scan would demand a tags-cn entry
    that :helptags never writes.
    """
    found: list[str] = []
    in_example = False
    for line in (text + '\n').split('\n')[:-1]:
        if in_example and not re.match(r'^[^ \t]', line):
            continue
        in_example = False
        cursor = 0
        while True:
            start = line.find('*', cursor)
            if start < 0:
                break
            previous = line[start - 1] if start > 0 else '\n'
            if previous in (' ', '\t', '\n'):
                index = start + 1
                while index < len(line) and line[index] not in TAG_STOP:
                    index += 1
                if index > start + 1 and index < len(line) and line[index] == '*':
                    following = line[index + 1:index + 2]
                    if following in ('', '\n', ' ', '\t', '*'):
                        found.append(line[start + 1:index])
            cursor = start + 1
        if _open_fence(line):
            in_example = True
    return found


def example_blocks(text: str) -> list[str]:
    """Mirror of runtime/syntax/help.vim's helpExample region."""
    lines = text.split('\n')
    blocks: list[str] = []
    index = 0
    while index < len(lines):
        if not re.search(r'(^| )>[a-z0-9]*$', lines[index]):
            index += 1
            continue
        body: list[str] = []
        cursor = index + 1
        while cursor < len(lines) and not re.match(r'^[^ \t]', lines[cursor]):
            body.append(lines[cursor])
            cursor += 1
        blocks.append('\n'.join(body))
        index = cursor
    return blocks


def links(text: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for link in re.findall(r'\|([^\s|]+)\|', text):
        counts[link] = counts.get(link, 0) + 1
    return counts


def runtime_dir(nvim: str) -> Path:
    value = os.environ.get('VIMRUNTIME')
    if value and (Path(value) / 'doc').is_dir():
        return Path(value)
    out = subprocess.run(
        [nvim, '--headless', '-u', 'NONE', '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
        capture_output=True, text=True, timeout=60,
        env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', tempfile.gettempdir())},
    )
    if out.returncode != 0:
        raise RuntimeError(f'VIMRUNTIME probe exited {out.returncode}: {out.stderr.strip()}')
    value = out.stdout.strip()
    if not value or not (Path(value) / 'doc').is_dir():
        raise RuntimeError(f'VIMRUNTIME probe returned an unusable path: {value!r}')
    return Path(value)


def nvim_version(nvim: str) -> str:
    """Return a readable Neovim version; probe failure is never an off-pin SKIP."""
    out = subprocess.run(
        [nvim, '--version'],
        capture_output=True, text=True, timeout=60,
        env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', tempfile.gettempdir())},
    )
    if out.returncode != 0:
        raise RuntimeError(f'Neovim version probe exited {out.returncode}: {out.stderr.strip()}')
    match = re.search(r'^NVIM v(\S+)', out.stdout, re.M)
    if not match:
        raise RuntimeError(f'Neovim version probe returned unrecognised output: {out.stdout!r}')
    return match.group(1)


def compare(name: str, meta: dict, runtime: Path, tags_cn: dict[str, str]) -> list[str]:
    problems: list[str] = []
    translated = (ROOT / meta['translation']).read_text(encoding='utf-8')
    upstream = (runtime / meta['source'].removeprefix('runtime/')).read_text(encoding='utf-8')
    basename = Path(meta['translation']).name

    source_tags, target_tags = tags(upstream), tags(translated)
    source_set, target_set = set(source_tags), set(target_tags)
    for tag in sorted(source_set - target_set):
        problems.append(f'{name}: missing help tag {tag}')
    for tag in sorted(target_set - source_set):
        problems.append(f'{name}: unverified help tag {tag}')
    for tag in sorted(target_set):
        if tag in tags_cn and tags_cn[tag] != basename:
            problems.append(f'{name}: tags-cn sends {tag} to {tags_cn[tag]}, not {basename}')
    duplicates = {tag for tag in target_set if target_tags.count(tag) > 1}
    for tag in sorted(duplicates):
        problems.append(f'{name}: duplicated help tag {tag}')

    source_blocks, target_blocks = example_blocks(upstream), example_blocks(translated)
    if len(source_blocks) != len(target_blocks):
        problems.append(f'{name}: example block count {len(target_blocks)} != {len(source_blocks)}')
    for index, (want, got) in enumerate(zip(source_blocks, target_blocks), 1):
        if want != got:
            want_lines, got_lines = want.split('\n'), got.split('\n')
            first = next((i for i, (a, b) in enumerate(zip(want_lines, got_lines), 1) if a != b), None)
            problems.append(
                f'{name}: example block {index} diverges'
                + (f' at block line {first}: want {want_lines[first - 1]!r} got {got_lines[first - 1]!r}'
                   if first else f' (line count {len(got_lines)} != {len(want_lines)})'))

    source_links, target_links = links(upstream), links(translated)
    for link in sorted(set(source_links) | set(target_links)):
        want, got = source_links.get(link, 0), target_links.get(link, 0)
        if want != got:
            problems.append(f'{name}: help link {link} appears {got}x, upstream {want}x')

    return problems


def probe_documents(present: list[str]) -> list[str]:
    """Documents whose pinned text is verified before a runtime is trusted.

    The version string is self-reported, so the installed text has to confirm
    it. Probing a single document is too weak: a foreign runtime that happens to
    ship the first manifest document verbatim would be accepted as the baseline.
    Probe the first, middle and last *present* document instead. ``present`` is
    expected in manifest order, as built by main() below.
    """
    if not present:
        return []
    picked = [present[0], present[len(present) // 2], present[-1]]
    ordered: list[str] = []
    for name in picked:
        if name not in ordered:
            ordered.append(name)
    return ordered


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='*', help='document names; defaults to every manifest document')
    parser.add_argument('--nvim', default=os.environ.get('NVIM_BIN', 'nvim'))
    args = parser.parse_args(argv)
    manifest = json.loads((ROOT / 'manifests/upstreams.json').read_text(encoding='utf-8'))
    documents = manifest['upstreams']['neovim']['documents']
    names = args.names or sorted(documents)
    unknown = [name for name in names if name not in documents]
    if unknown:
        print(f'PARITY_ERROR=unknown document {unknown[0]}', file=sys.stderr)
        return 2
    # Only the pinned baseline can answer parity: comparing the 0.12.6-derived
    # translations against another runtime reports version drift as breakage.
    # The shipped index is parsed before the gate so the SKIP line can report
    # exactly how much this run declined to compare.
    tags_cn: dict[str, str] = {}
    for line in (ROOT / 'doc/tags-cn').read_text(encoding='utf-8').splitlines():
        if line:
            tag, filename, _ = line.split('\t')
            tags_cn[tag] = filename
    try:
        runtime = runtime_dir(args.nvim)
        runtime_version = nvim_version(args.nvim)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f'HELP_PARITY=FAIL reason=runtime_probe_failed error={exc}', file=sys.stderr)
        return 2
    pinned_version = manifest['upstreams']['neovim']['version']
    if runtime_version != pinned_version:
        print(
            f'HELP_PARITY=SKIP pinned={pinned_version} runtime={runtime_version} '
            f'documents={len(names)} tags={len(tags_cn)} '
            f'translation_contract=checked_by_01_help_catalog_spec runtime_dir={runtime}'
        )
        return 0
    # The version string is self-reported. Before trusting it, confirm the
    # installed runtime really carries the pinned text, so a runtime that merely
    # reports the pinned version cannot be compared as if it were the baseline.
    present = [name for name in names
               if (runtime / documents[name]['source'].removeprefix('runtime/')).is_file()]
    if not present:
        print(f'HELP_PARITY=FAIL reason=pinned_runtime_missing_documents '
              f'pinned={pinned_version} runtime={runtime_version} runtime_dir={runtime}')
        return 1
    for probe in probe_documents(present):
        installed = (runtime / documents[probe]['source'].removeprefix('runtime/')).read_bytes()
        if hashlib.sha256(installed).hexdigest() != documents[probe]['sha256']:
            print(f'HELP_PARITY=FAIL reason=pinned_runtime_content_mismatch document={probe} '
                  f'pinned={pinned_version} runtime_dir={runtime}')
            return 1
    problems: list[str] = []
    for name in names:
        problems.extend(compare(name, documents[name], runtime, tags_cn))
    for problem in problems:
        print(f'PARITY_ERROR={problem}')
    for name in names:
        status = 'FAIL' if any(p.startswith(f'{name}:') for p in problems) else 'PASS'
        print(f'PARITY_DOC={name} status={status}')
    print(f'HELP_PARITY={"FAIL" if problems else "PASS"} documents={len(names)} problems={len(problems)}')
    return 1 if problems else 0


if __name__ == '__main__':
    raise SystemExit(main())
