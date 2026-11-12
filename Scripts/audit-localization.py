#!/usr/bin/env python3
"""Static localization inventory. Candidates require review; they are not coverage claims."""
import argparse
import collections
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
PAIR = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"', re.M)
CALL = re.compile(r'\b(?:L|L10n\.translate|L10n\.format|format)\(\s*"((?:[^"\\]|\\.)*)"')
TOKEN = re.compile(r'%(?:\d+\$)?(?:[-+0#]*\d*(?:\.\d+)?)(?:ll|l|z)?[@diufgs]|%%')

def signature(text):
    """Argument index/type pairs allow positional reordering but reject changed types."""
    result = []; sequential = 0
    for token in TOKEN.findall(text):
        if token == '%%':
            result.append((0, '%%')); continue
        match = re.match(r'%(\d+)\$', token)
        if match:
            index = int(match.group(1)); spec = '%' + token[match.end():]
        else:
            sequential += 1; index = sequential; spec = token
        result.append((index, spec))
    return sorted(result)

def audit():
    dictionaries = {}
    duplicates = {}; mismatches = {}; newlines = {}
    for lang, name in [('zh-Hans', 'Chinese'), ('fr', 'French')]:
        pairs = PAIR.findall((ROOT / f'Sources/HighballKit/L10n{name}.swift').read_text())
        counts = collections.Counter(k for k, _ in pairs)
        duplicates[lang] = [k for k, n in counts.items() if n > 1]
        dictionaries[lang] = dict(pairs)
        mismatches[lang] = [k for k, v in pairs if signature(k) != signature(v)]
        newlines[lang] = [k for k, v in pairs if k.count('\\n') != v.count('\\n')]
    used = set(); candidates = []; dynamic = []
    # Include the complete app and kit: runtime diagnostics and external data are intentionally
    # reported as candidates, never blindly rewritten as display text.
    for path in sorted((ROOT / 'Sources').rglob('*.swift')):
        if path.name in {'L10n.swift', 'L10nChinese.swift', 'L10nFrench.swift'}: continue
        text = path.read_text()
        used.update(CALL.findall(text))
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith('//'): continue
            if '"' not in line: continue
            loc = {'file': str(path.relative_to(ROOT)), 'line': number, 'source': stripped}
            if '\\(' in line and re.search(r'\b(Text|headline|meaning|detail|runBusy|stage|return)\b', line):
                dynamic.append(loc)
            if re.search(r'\b(?:Text|Button|Label|Toggle|Picker|Section|TextField)\(\s*"|\.(?:help|navigationTitle|accessibilityLabel)\(\s*"|\b(?:return|headline:|meaning:|detail:|stage\s*=|busyTitle\s*=)\s*"', line):
                candidates.append(loc)
    return {
        'entries': {k: len(v) for k,v in dictionaries.items()},
        'localized_keys': len(used),
        'missing': {lang: sorted(used-set(d)) for lang,d in dictionaries.items()},
        'duplicates': duplicates, 'placeholder_mismatches': mismatches, 'newline_mismatches': newlines,
        'unreferenced_or_dynamic_keys': {lang: sorted(set(d)-used) for lang,d in dictionaries.items()},
        'potentially_untranslated_source_lines': candidates,
        'dynamic_source_lines_to_review': dynamic,
        'limitations': 'Static candidates include technical identifiers, CLI diagnostics, numbers, external database text and nested localization calls. Unreferenced keys may be runtime values; do not delete automatically.'
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path)
    args = parser.parse_args(); report = audit()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k in ['entries','localized_keys','duplicates','placeholder_mismatches','newline_mismatches']}, ensure_ascii=False, indent=2))
    for lang, missing in report['missing'].items(): print(f'{lang}: {len(missing)} missing keys (English fallback)')
    # Preserve upstream's warning-only policy for incomplete translations.
    raise SystemExit(1 if any(report['duplicates'].values()) or report['placeholder_mismatches']['zh-Hans'] or report['newline_mismatches']['zh-Hans'] else 0)
