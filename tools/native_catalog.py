#!/usr/bin/env python3
"""Native (gettext) catalog tooling for the Neovim core messages.

The plugin runtime never installs a core MO file by itself; this tool only
maintains the translation resource and builds a catalog that can be reviewed
and, later, installed explicitly.

Commands
--------
check    validate translations/native/*.po against manifests/native.json (offline)
build    merge pinned upstream catalog + supplement + repairs into an MO file
sync     fetch/verify the pinned upstream catalog (network only with --fetch)
stats    print the manifest counts

The supplement PO keeps upstream msgids verbatim so it can be merged into (or
submitted to) the upstream catalog; msgids that upstream truncated are repaired
by translations/native/runtime_repairs.po, built from the pinned C sources.
The separate intro.po retains current welcome-screen keys alongside the
upstream catalog's older spacing/wording, with pinned source and binary evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog_tool import (  # noqa: E402
    PROTECTED_PATTERNS,
    CatalogError,
    atomic_write_bytes,
    atomic_write_text,
    load_glossary,
)

PRINTF = re.compile(r'%[-+ #0]*\d*(?:\.\d+|\.\*)?(?:hh|h|ll|l|j|z|t|L)?[diouxXeEfgGaAcsp]')
MACRO = re.compile(r'%<([A-Za-z0-9_]+)>')
DIRECTIVE = re.compile(r'^(msgctxt|msgid|msgid_plural|msgstr|msgstr\[(\d+)\])\s+(.*)$')
ERROR_CODE = re.compile(r'^([EW]\d+):')

PO_HEADER_FIELDS = (
    'Project-Id-Version',
    'MIME-Version',
    'Content-Type',
    'Content-Transfer-Encoding',
    'Language',
    'Plural-Forms',
)


class NativeError(ValueError):
    pass


# --------------------------------------------------------------------------- PO I/O


def po_escape(value: str) -> str:
    out = []
    for char in value:
        if char == '\\':
            out.append('\\\\')
        elif char == '"':
            out.append('\\"')
        elif char == '\n':
            out.append('\\n')
        elif char == '\t':
            out.append('\\t')
        else:
            out.append(char)
    return ''.join(out)


def _unquote(text: str, path: Path, line: int) -> str:
    if not text.startswith('"'):
        raise NativeError(f'{path}:{line}: PO string must be double-quoted')
    import ast

    try:
        value = ast.literal_eval(text)
    except (SyntaxError, ValueError) as exc:
        raise NativeError(f'{path}:{line}: malformed PO string') from exc
    if not isinstance(value, str):
        raise NativeError(f'{path}:{line}: malformed PO string')
    return value


def parse_po(path: Path) -> tuple[list[dict], dict[str, str]]:
    """Plural-aware PO parser: the pinned Neovim catalog contains plurals."""
    try:
        text = path.read_bytes().decode('utf-8')
    except UnicodeDecodeError as exc:
        raise NativeError(f'{path}: invalid UTF-8') from exc
    entries: list[dict] = []
    current: dict | None = None
    active: str | None = None

    def finish() -> None:
        nonlocal current, active
        if current is not None and 'msgid' in current:
            entries.append(current)
        current = None
        active = None

    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith('#'):
            if current is not None and ('msgstr' in current or 'msgstr_plural' in current):
                finish()
            if current is None:
                current = {'refs': [], 'flags': [], 'comments': []}
            if line.startswith('#:'):
                current['refs'].extend(line[2:].split())
            elif line.startswith('#,'):
                current['flags'].extend(f.strip() for f in line[2:].split(','))
            elif current is not None and 'msgid' not in current:
                current['comments'].append(line)
            continue
        match = DIRECTIVE.match(line)
        if match:
            keyword, index, value = match.group(1), match.group(2), match.group(3)
            base = 'msgstr' if keyword.startswith('msgstr') else keyword
            if base in ('msgctxt', 'msgid') and current is not None and 'msgid' in current:
                finish()
            if current is None:
                current = {'refs': [], 'flags': [], 'comments': []}
            if base == 'msgstr' and index is not None:
                current.setdefault('msgstr_plural', {})[int(index)] = _unquote(value, path, number)
                active = ('msgstr_plural', int(index))
            else:
                if base in current:
                    raise NativeError(f'{path}:{number}: duplicate {base}')
                current[base] = _unquote(value, path, number)
                active = base
            continue
        if line.startswith('"') and current is not None and active is not None:
            if isinstance(active, tuple):
                _, plural_index = active
                current['msgstr_plural'][plural_index] += _unquote(line, path, number)
            else:
                current[active] = current.get(active, '') + _unquote(line, path, number)
            continue
        raise NativeError(f'{path}:{number}: malformed PO syntax')
    finish()

    headers: dict[str, str] = {}
    messages: list[dict] = []
    for entry in entries:
        entry.pop('_active_plural', None)
        if entry['msgid'] == '' and not entry.get('msgctxt'):
            for line in entry.get('msgstr', '').splitlines():
                if ':' in line:
                    key, value = line.split(':', 1)
                    headers[key.strip()] = value.strip()
        else:
            messages.append(entry)
    charset = headers.get('Content-Type', '')
    if charset and not re.search(r'charset=UTF-8(?:\s|$)', charset, re.I):
        raise NativeError(f'{path}: PO Content-Type must use UTF-8')
    return messages, headers


def render_po(entries: list[dict], headers: dict[str, str] | None = None) -> str:
    lines: list[str] = []
    if headers is not None:
        lines.append('msgid ""')
        lines.append('msgstr ""')
        for key in PO_HEADER_FIELDS:
            if key in headers:
                lines.append(f'"{po_escape(key + ": " + headers[key])}\\n"')
        lines.append('')
    for entry in entries:
        for comment in entry.get('comments', []):
            lines.append(comment)
        for ref in entry.get('refs', []):
            lines.append('#: ' + ref)
        if entry.get('flags'):
            lines.append('#, ' + ', '.join(entry['flags']))
        context = entry.get('msgctxt')
        if context is not None:
            lines.append(f'msgctxt "{po_escape(context)}"')
        lines.append(f'msgid "{po_escape(entry["msgid"])}"')
        if entry.get('msgid_plural') is not None:
            lines.append(f'msgid_plural "{po_escape(entry["msgid_plural"])}"')
            plural = entry.get('msgstr_plural', {})
            for index in sorted(plural):
                lines.append(f'msgstr[{index}] "{po_escape(plural[index])}"')
        else:
            lines.append(f'msgstr "{po_escape(entry.get("msgstr", ""))}"')
        lines.append('')
    return '\n'.join(lines)


# --------------------------------------------------------------------------- checks


def placeholders(text: str) -> list[str]:
    """Ordered placeholder sequence: %<MACRO> tokens plus printf specifiers."""
    tokens: list[str] = []
    index = 0
    while index < len(text):
        if text[index] != '%':
            index += 1
            continue
        if text[index:index + 2] == '%%':
            index += 2
            continue
        macro = MACRO.match(text, index)
        if macro:
            tokens.append(macro.group(0))
            index = macro.end()
            continue
        spec = PRINTF.match(text, index)
        if spec:
            tokens.append(spec.group(0))
            index = spec.end()
            continue
        tokens.append('%')
        index += 1
    return tokens


def check_entry(entry: dict, path: Path, terms: list[dict]) -> None:
    msgid, msgstr = entry['msgid'], entry.get('msgstr', '')
    location = f'{path}: {msgid[:60]!r}'
    if entry.get('msgid_plural') is not None:
        raise NativeError(f'{location}: this catalog does not accept plural entries in the supplement')
    if not msgstr:
        raise NativeError(f'{location}: empty translation')
    if msgstr == msgid:
        raise NativeError(f'{location}: translation identical to msgid')
    if 'fuzzy' in entry.get('flags', []):
        raise NativeError(f'{location}: fuzzy translation must be reviewed')
    if placeholders(msgid) != placeholders(msgstr):
        raise NativeError(f'{location}: placeholder sequence changed '
                          f'({placeholders(msgid)} -> {placeholders(msgstr)})')
    for pattern in PROTECTED_PATTERNS:
        if Counter(pattern.findall(msgid)) != Counter(pattern.findall(msgstr)):
            raise NativeError(f'{location}: protected command, path, option, or code span changed')
    code = ERROR_CODE.match(msgid)
    if code and not msgstr.startswith(code.group(1) + ':'):
        raise NativeError(f'{location}: error code {code.group(1)} must be preserved at the start')
    for term in terms:
        source = term['source']
        present = re.search(rf'(?<![A-Za-z0-9_]){re.escape(source)}(?![A-Za-z0-9_])', msgid)
        if present and term.get('policy') == 'preserve' and source not in msgstr:
            raise NativeError(f'{location}: preserved term {source!r} was translated or removed')
        for forbidden in term.get('forbidden', []):
            if forbidden in msgstr:
                raise NativeError(f'{location}: forbidden translation {forbidden!r} for {source!r}')


def load_manifest(root: Path) -> dict:
    path = root / 'manifests/native.json'
    try:
        manifest = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as exc:
        raise NativeError(f'{path}: cannot read manifest: {exc}') from exc
    if manifest.get('schema_version') != 1:
        raise NativeError(f'{path}: unsupported schema_version')
    return manifest


def _read_catalog(po: Path, terms: list[dict], label: str) -> list[dict]:
    entries, _ = parse_po(po)
    for entry in entries:
        check_entry(entry, po, terms)
    if not entries:
        raise NativeError(f'{po}: {label} is empty')
    return entries


def check(root: Path) -> dict:
    manifest = load_manifest(root)
    glossary = root / 'translations/glossary/zh_CN.toml'
    terms = load_glossary(glossary)
    supplement = _read_catalog(root / manifest['supplement']['po'], terms, 'supplement')
    repairs = _read_catalog(root / manifest['repairs']['po'], terms, 'runtime repairs')

    gaps = {item['msgid'] for item in manifest['gaps']}
    exemptions = {item['msgid'] for item in manifest['exemptions']}
    if len(gaps) != manifest['upstream']['untranslated']:
        raise NativeError('manifest: gaps do not match upstream.untranslated')
    if not exemptions <= gaps:
        raise NativeError('manifest: exemptions must be a subset of gaps')
    supplement_ids = {entry['msgid'] for entry in supplement}
    repair_upstream = set(manifest['repairs']['upstream_msgids'])
    if len(supplement_ids) != len(supplement):
        raise NativeError('supplement: duplicate msgids')
    if supplement_ids & exemptions:
        raise NativeError('supplement: exempted msgid must not be translated here')
    if supplement_ids | exemptions != gaps:
        missing = sorted(gaps - supplement_ids - exemptions)
        extra = sorted(supplement_ids - gaps)
        raise NativeError(f'supplement does not cover the pinned gaps (missing={missing[:3]}, extra={extra[:3]})')
    if repair_upstream - gaps:
        raise NativeError('repairs: upstream msgid is not one of the pinned gaps')
    translated_repairs = {entry['msgid'] for entry in repairs}
    if translated_repairs & (supplement_ids | exemptions):
        raise NativeError('repairs: runtime msgid collides with an upstream msgid')
    intro = []
    if 'intro' in manifest:
        info = manifest['intro']
        intro = _read_catalog(root / info['po'], terms, 'intro')
        source = info['source']
        if source['commit'] != manifest['upstream']['commit']:
            raise NativeError('intro: source commit must match the pinned upstream')
        for field in ('sha256', 'binary_sha256'):
            if not re.fullmatch(r'[0-9a-f]{64}', source.get(field, '')):
                raise NativeError(f'intro: invalid source {field}')
        ids = {entry['msgid'] for entry in intro}
        expected = {item['msgid'] for item in info['messages']}
        if (len(ids) != len(intro) or len(intro) != info['entries']
                or len(info['messages']) != len(intro) or ids != expected):
            raise NativeError('intro: duplicate keys or entries differ from the manifest')
        if ids & (supplement_ids | exemptions | translated_repairs):
            raise NativeError('intro: runtime key collides with another local catalog')
        for item in info['messages']:
            if not item.get('previous_msgid') or item.get('source_line', 0) <= 0:
                raise NativeError('intro: previous msgid and pinned source line are required')
    for item in manifest['exemptions']:
        if 'do not translate' not in item.get('marker', ''):
            raise NativeError(f"exemption {item['msgid']!r}: marker does not record an upstream do-not-translate note")
    prefix_repairs = manifest.get('prefix_repairs', [])
    for item in prefix_repairs:
        if item['upstream_msgid'] not in supplement_ids:
            raise NativeError(f"prefix repair {item['upstream_msgid']!r} has no supplement entry")
        if not re.fullmatch(r'E\d{2,5}: ', item.get('prefix', '')):
            raise NativeError(f"prefix repair {item['upstream_msgid']!r}: prefix must look like 'E123: '")
        if not item.get('evidence'):
            raise NativeError(f"prefix repair {item['upstream_msgid']!r}: evidence is required")
    return {
        'gaps': len(gaps),
        'exemptions': len(exemptions),
        'supplement': len(supplement_ids),
        'repairs': len(translated_repairs),
        'prefix_repairs': len(prefix_repairs),
        'glossary_terms': len(terms),
        'intro': len(intro),
    }


# --------------------------------------------------------------------------- merge / build


def _key(entry: dict) -> tuple[str, str]:
    return entry.get('msgctxt') or '', entry['msgid']


def merge(manifest: dict, upstream: list[dict], supplement: list[dict], repairs: list[dict],
          intro: list[dict] | None = None) -> tuple[list[dict], dict]:
    gaps = {item['msgid'] for item in manifest['gaps']}
    exemptions = {item['msgid'] for item in manifest['exemptions']}
    prefix_repairs = manifest.get('prefix_repairs', [])
    merged: dict[tuple[str, str], dict] = {}
    for entry in upstream:
        key = _key(entry)
        if key in merged:
            raise NativeError(f'upstream: duplicate context/msgid key {key!r}')
        merged[key] = dict(entry)
    drift: list[str] = []
    translated: dict[str, dict] = {}
    for entry in supplement:
        key = _key(entry)
        target = merged.get(key)
        if target is None:
            raise NativeError(f'supplement msgid no longer exists upstream: {entry["msgid"]!r}')
        if target.get('msgstr', '').strip():
            drift.append(entry['msgid'])
            continue
        target['msgstr'] = entry['msgstr']
        translated[entry['msgid']] = entry
    if drift:
        raise NativeError('upstream already translated these supplement entries; drop them from the supplement: '
                          + ', '.join(sorted(drift)[:5]))
    for item in prefix_repairs:
        source = translated.get(item['upstream_msgid'])
        if source is None:
            raise NativeError(f'prefix repair {item["upstream_msgid"]!r} has no translated supplement entry')
        runtime_msgid = item['prefix'] + source['msgid']
        key = ('', runtime_msgid)
        if key in merged:
            raise NativeError(f'prefix repair collides with an existing catalog key: {key!r}')
        merged[key] = {
            'msgid': runtime_msgid,
            'msgstr': item['prefix'] + source['msgstr'],
            'refs': list(source.get('refs', [])),
            'flags': list(source.get('flags', [])),
            'comments': [f'#. runtime-prefixed key: {item["evidence"]}'],
        }
    for entry in repairs:
        key = _key(entry)
        if key in merged:
            raise NativeError(f'runtime repair collides with an existing catalog key: {key!r}')
        merged[key] = dict(entry)
    previous = {item['msgid']: item['previous_msgid'] for item in manifest.get('intro', {}).get('messages', [])}
    for entry in intro or []:
        key = _key(entry)
        if key in merged:
            raise NativeError(f'intro repair collides with an existing catalog key: {key!r}')
        legacy_key = ('', previous.get(entry['msgid'], ''))
        if legacy_key not in merged:
            raise NativeError(f'intro: previous upstream key no longer exists: {legacy_key!r}')
        merged[key] = dict(entry)
    by_msgid = {entry['msgid']: entry for entry in merged.values()}
    uncovered = sorted(g for g in gaps if g not in exemptions
                       and not by_msgid.get(g, {}).get('msgstr', '').strip())
    if uncovered:
        raise NativeError(f'merged catalog still misses {len(uncovered)} pinned gap(s): {uncovered[:3]}')
    entries = [merged[key] for key in sorted(merged)]
    stats = {
        'messages': len(entries),
        'translated': sum(1 for e in entries if e.get('msgstr', '').strip() or e.get('msgstr_plural')),
        'untranslated': sum(1 for e in entries if not e.get('msgstr', '').strip() and not e.get('msgstr_plural')),
        'exemptions': len(exemptions),
        'repairs': len(repairs),
        'intro': len(intro or []),
    }
    if stats['untranslated'] != stats['exemptions']:
        raise NativeError(f'merged catalog has {stats["untranslated"]} untranslated entries, '
                          f'expected only the {stats["exemptions"]} documented exemptions')
    return entries, stats


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _rel(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


MACRO_CONVERSIONS = {
    'PRId64': ('ld', 'lld', 'd'),
    'PRIu64': ('lu', 'llu', 'u'),
    'PRIx64': ('lx', 'llx', 'x'),
    'PRIo64': ('lo', 'llo', 'o'),
    'PRId32': ('d',),
    'PRIu32': ('u',),
    'PRIdVARNUMBER': ('ld', 'lld', 'd'),
}
GENERIC_CONVERSIONS = ('d', 'u', 'ld', 'lu', 'lld', 'llu')


def runtime_variants(msgid: str) -> list[str]:
    """Expand %<MACRO> placeholders into the platform's printf conversions."""
    macros = re.findall(r'%<([A-Za-z0-9_]+)>', msgid)
    if not macros:
        return [msgid]
    from itertools import product

    variants = []
    for combo in product(*[MACRO_CONVERSIONS.get(m, GENERIC_CONVERSIONS) for m in macros]):
        text = msgid
        for macro, conversion in zip(macros, combo):
            text = text.replace('%<' + macro + '>', '%' + conversion, 1)
        variants.append(text)
    return variants


def _runtime_file_variants(text: str) -> list[bytes]:
    """How a msgid may appear inside a Lua/Vimscript source literal."""
    escaped = text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    return [v.encode() for v in {text, escaped}]


def resolve_binary(binary: Path) -> Path:
    """Resolve a bare command name through PATH before reading its bytes."""
    if str(binary) == binary.name:
        resolved = shutil.which(binary.name)
        if resolved is None:
            raise NativeError(f'audit binary not found on PATH: {binary.name}')
        return Path(resolved)
    return binary


def probe_runtime(binary: Path) -> Path | None:
    """The $VIMRUNTIME reported by ``binary``, so an audit never scans a foreign tree."""
    try:
        out = subprocess.run(
            [str(binary), '--headless', '-u', 'NONE',
             '-c', 'lua io.write(vim.env.VIMRUNTIME)', '-c', 'qa!'],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, 'XDG_STATE_HOME': os.environ.get('XDG_STATE_HOME', '/tmp')})
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    value = out.stdout.strip()
    return Path(value) if value else None


def audit(root: Path, manifest: dict, binary: Path, runtime: Path | None = None) -> dict:
    """Classify supplement entries against one compiled Neovim and its runtime tree."""
    terms = load_glossary(root / 'translations/glossary/zh_CN.toml')
    supplement = _read_catalog(root / manifest['supplement']['po'], terms, 'supplement')
    data = binary.read_bytes()
    haystack = b''
    if runtime is not None and runtime.is_dir():
        chunks: list[bytes] = []
        for path in sorted(runtime.rglob('*')):
            if path.is_file() and path.suffix not in ('.mo', '.so', '.dll', '.dylib', '.o', '.a'):
                try:
                    chunks.append(path.read_bytes())
                except OSError:
                    continue
        haystack = b'\x00'.join(chunks)
    result = {'binary': str(binary), 'binary_sha256': _sha256(binary),
              'runtime': str(runtime) if runtime is not None else None,
              'entries': len(supplement), 'bare': [], 'bare_and_prefixed': [],
              'prefixed_only': [], 'runtime_file': [], 'unverified': []}
    for entry in supplement:
        msgid = entry['msgid']
        variants = runtime_variants(msgid)
        bare = next((v for v in variants if v.encode() in data), None)
        prefixed = None
        for variant in variants:
            match = re.search(rb'E\d{2,5}: ' + re.escape(variant.encode()), data)
            if match:
                prefixed = {'runtime_msgid': match.group().decode().rstrip(), 'variant': variant}
                break
        if bare and prefixed:
            result['bare_and_prefixed'].append({'msgid': msgid, **prefixed})
        elif bare:
            result['bare'].append(msgid)
        elif prefixed:
            result['prefixed_only'].append({'msgid': msgid, **prefixed})
        elif haystack and any(v in haystack for variant in variants for v in _runtime_file_variants(variant)):
            result['runtime_file'].append(msgid)
        else:
            result['unverified'].append(msgid)
    return result


def sync(root: Path, manifest: dict, fetch: bool) -> dict:
    upstream = manifest['upstream']
    target = root / 'build/upstream/zh_CN.UTF-8.po'
    url = f"{upstream['repository'].replace('github.com', 'raw.githubusercontent.com')}/{upstream['commit']}/{upstream['catalog']}"
    if fetch:
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
        except Exception as exc:  # noqa: BLE001 - network failures are reported, not raised
            raise NativeError(f'fetch failed: {exc}') from exc
        downloaded_sha = hashlib.sha256(data).hexdigest()
        if downloaded_sha != upstream['sha256']:
            raise NativeError(f'{target}: downloaded sha256 mismatch (have {downloaded_sha}, '
                              f'pinned {upstream["sha256"]}); cached file left untouched')
        atomic_write_bytes(target, data)
    if not target.is_file():
        return {'status': 'SKIP', 'reason': 'no local copy; run sync --fetch'}
    digest = _sha256(target)
    if digest != upstream['sha256']:
        raise NativeError(f'{target}: sha256 mismatch (have {digest}, pinned {upstream["sha256"]})')
    return {'status': 'PASS', 'path': str(target.relative_to(root)), 'sha256': digest}


def build(root: Path, manifest: dict, upstream_path: Path, out_dir: Path, expect_sha: str | None) -> dict:
    status = check(root)
    if expect_sha:
        digest = _sha256(upstream_path)
        if digest != expect_sha:
            raise NativeError(f'{upstream_path}: sha256 mismatch (have {digest}, pinned {expect_sha})')
    glossary = root / 'translations/glossary/zh_CN.toml'
    terms = load_glossary(glossary)
    upstream, headers = parse_po(upstream_path)
    if not upstream:
        raise NativeError(f'{upstream_path}: no messages')
    supplement = _read_catalog(root / manifest['supplement']['po'], terms, 'supplement')
    repairs = _read_catalog(root / manifest['repairs']['po'], terms, 'runtime repairs')
    intro = (_read_catalog(root / manifest['intro']['po'], terms, 'intro')
             if 'intro' in manifest else [])
    entries, stats = merge(manifest, upstream, supplement, repairs, intro)
    merged_text = render_po(entries, headers)
    out_dir.mkdir(parents=True, exist_ok=True)
    merged_po = out_dir / 'nvim.merged.po'
    mo_dir = out_dir / 'zh_CN.UTF-8/LC_MESSAGES'
    mo_dir.mkdir(parents=True, exist_ok=True)
    mo_path = mo_dir / 'nvim.mo'

    # msgfmt needs pathnames, so give it staged input/output and publish neither
    # artifact until compilation and all reported-count checks have succeeded.
    fd, staged_merged_name = tempfile.mkstemp(prefix='.nvim.merged.', suffix='.tmp', dir=out_dir)
    os.close(fd)
    staged_merged = Path(staged_merged_name)
    staged_mo: Path | None = None
    try:
        staged_merged.write_text(merged_text, encoding='utf-8', newline='\n')
        fd, staged_mo_name = tempfile.mkstemp(prefix='.nvim.', suffix='.tmp', dir=mo_dir)
        os.close(fd)
        staged_mo = Path(staged_mo_name)
        try:
            process = subprocess.run(
                ['msgfmt', '--statistics', '-o', str(staged_mo), str(staged_merged)],
                capture_output=True, text=True, check=False, timeout=60)
        except FileNotFoundError as exc:
            raise NativeError('msgfmt is required to build the native catalog; install gettext') from exc
        except (OSError, subprocess.SubprocessError) as exc:
            raise NativeError(f'msgfmt execution failed: {exc}') from exc
        if process.returncode != 0:
            raise NativeError(f'msgfmt failed: {process.stderr.strip()[:400]}')
        reported = {}
        for count, kind in re.findall(r'(\d+)\s+(translated|untranslated|fuzzy)\s+messages?', process.stderr):
            reported[kind] = int(count)
        if reported.get('untranslated', stats['untranslated']) != stats['exemptions']:
            raise NativeError(f'msgfmt reports {reported.get("untranslated")} untranslated, '
                              f'expected the {stats["exemptions"]} documented exemptions')
        if reported.get('fuzzy'):
            raise NativeError('msgfmt reports fuzzy messages')
        mo_data = staged_mo.read_bytes()
        atomic_write_text(merged_po, merged_text)
        atomic_write_bytes(mo_path, mo_data)
    finally:
        staged_merged.unlink(missing_ok=True)
        if staged_mo is not None:
            staged_mo.unlink(missing_ok=True)
    stats.update(status)
    stats['merged_po'] = _rel(merged_po, root)
    stats['mo'] = _rel(mo_path, root)
    stats['mo_sha256'] = hashlib.sha256(mo_data).hexdigest()
    stats['msgfmt'] = reported
    return stats


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'build', 'sync', 'stats', 'audit'))
    parser.add_argument('--root', type=Path, default=root)
    parser.add_argument('--upstream', type=Path, default=root / 'build/upstream/zh_CN.UTF-8.po')
    parser.add_argument('--binary', type=Path, help='compiled nvim used to audit runtime literals (audit only)')
    parser.add_argument('--runtime', type=Path, default=None,
                        help='runtime tree scanned for runtime-file msgids (audit only; '
                             'defaults to the --binary own $VIMRUNTIME)')
    parser.add_argument('--report', type=Path, default=root / 'build/native/audit.json')
    parser.add_argument('--expect-sha', choices=('pinned', 'any'), default='pinned')
    parser.add_argument('--out', type=Path, default=root / 'build/native')
    parser.add_argument('--fetch', action='store_true', help='allow one explicit read-only fetch of the pinned catalog')
    args = parser.parse_args(argv)
    try:
        if args.command == 'check':
            result = check(args.root)
            print('NATIVE_CHECK=PASS ' + ' '.join(f'{k}={v}' for k, v in sorted(result.items())))
        elif args.command == 'stats':
            manifest = load_manifest(args.root)
            upstream = manifest['upstream']
            print(f"NATIVE_STATS upstream={upstream['version']}@{upstream['commit'][:12]} "
                  f"messages={upstream['messages']} translated={upstream['translated']} "
                  f"untranslated={upstream['untranslated']} supplement={manifest['supplement']['entries']} "
                  f"exemptions={len(manifest['exemptions'])} repairs={manifest['repairs']['entries']} "
                  f"intro={manifest.get('intro', {}).get('entries', 0)}")
        elif args.command == 'sync':
            manifest = load_manifest(args.root)
            result = sync(args.root, manifest, args.fetch)
            print('NATIVE_SYNC=' + result.pop('status') + ' ' + ' '.join(f'{k}={v}' for k, v in sorted(result.items())))
        elif args.command == 'audit':
            if args.binary is None:
                raise NativeError('audit requires --binary /path/to/nvim')
            manifest = load_manifest(args.root)
            binary = resolve_binary(args.binary)
            if args.runtime is not None:
                runtime = args.runtime
            else:
                runtime = probe_runtime(binary)
                if runtime is None:
                    raise NativeError('audit could not determine the binary $VIMRUNTIME; '
                                      'pass --runtime explicitly after checking it matches the binary')
            result = audit(args.root, manifest, binary, runtime)
            args.report.parent.mkdir(parents=True, exist_ok=True)
            atomic_write_text(args.report, json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            print(f"NATIVE_AUDIT=PASS entries={result['entries']} bare={len(result['bare'])} "
                  f"bare_and_prefixed={len(result['bare_and_prefixed'])} "
                  f"prefixed_only={len(result['prefixed_only'])} runtime_file={len(result['runtime_file'])} "
                  f"unverified={len(result['unverified'])} "
                  f"binary_sha256={result['binary_sha256']} report={args.report}")
            for item in result['bare_and_prefixed'] + result['prefixed_only']:
                print(f"NATIVE_AUDIT_PREFIXED upstream_msgid={item['msgid']!r} runtime_msgid={item['runtime_msgid']!r}")
            for msgid in result['unverified']:
                print(f'NATIVE_AUDIT_UNVERIFIED msgid={msgid!r}')
        else:
            manifest = load_manifest(args.root)
            expect = manifest['upstream']['sha256'] if args.expect_sha == 'pinned' else None
            result = build(args.root, manifest, args.upstream, args.out, expect)
            print('NATIVE_BUILD=PASS ' + ' '.join(f'{k}={v}' for k, v in sorted(result.items())))
    except (NativeError, CatalogError) as exc:
        print(f'NATIVE_ERROR={exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
