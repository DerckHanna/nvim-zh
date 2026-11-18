"""Enforce translations/glossary/zh_CN.toml on the help translations too.

The glossary was originally wired only into tools/catalog_tool.py, which reads
translations/po/*.po. That left doc/*.cnx unchecked, and the accepted help
corpus drifted to 窗口 / 缓冲区 / 寄存器 while the glossary requires
Window / Buffer / Register to stay in English. The glossary is the project's
single terminology source, so a term marked `preserve` must not appear in its
forbidden Chinese form anywhere we ship Chinese help text.

The rule set is read from the glossary file, not hard-coded, so adding a term
there extends this check automatically.
"""

from __future__ import annotations

import os
import unittest
from pathlib import Path

ROOT = Path(os.environ['NVIM_ZH_ROOT']).resolve()
DOC = ROOT / 'doc'
GLOSSARY = ROOT / 'translations' / 'glossary' / 'zh_CN.toml'

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    import tomli as tomllib  # type: ignore


def _terms() -> list[tuple[str, list[str]]]:
    data = tomllib.loads(GLOSSARY.read_text(encoding='utf-8'))
    terms = data.get('term', [])
    result = []
    for term in terms:
        if term.get('policy') != 'preserve':
            continue
        forbidden = [t for t in term.get('forbidden', []) if t]
        if forbidden:
            result.append((term['source'], forbidden))
    return result


class HelpTerminologyTests(unittest.TestCase):
    def test_glossary_declares_preserved_terms(self) -> None:
        self.assertTrue(_terms(), 'glossary declares no preserved term with forbidden forms')

    def test_translated_help_never_uses_forbidden_terms(self) -> None:
        translations = sorted(DOC.glob('*.cnx'))
        self.assertTrue(translations, 'no doc/*.cnx translations to check')
        problems: list[str] = []
        for term, forbidden in _terms():
            for path in translations:
                text = path.read_text(encoding='utf-8')
                for word in forbidden:
                    if word not in text:
                        continue
                    for number, line in enumerate(text.splitlines(), 1):
                        if word in line:
                            problems.append(
                                f'{path.name}:{number}: {term!r} must stay English, '
                                f'found forbidden {word!r}: {line.strip()[:80]}')
        self.assertEqual(problems, [], 'glossary violations in doc/*.cnx:\n' + '\n'.join(problems))


if __name__ == '__main__':
    unittest.main(verbosity=1)
