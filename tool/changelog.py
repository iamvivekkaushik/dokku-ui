#!/usr/bin/env python3
"""Prints the CHANGELOG.md section of one version, for the GitHub release.

    python3 tool/changelog.py 1.2.0

Exits with 1 when the version has no section, which is how CI refuses to
release a version nobody wrote notes for.
"""

import re
import sys


def section(text, version):
    m = re.search(r'^## ' + re.escape(version) + r'\b[^\n]*\n(.*?)(?=^## |\Z)', text, re.S | re.M)
    return m.group(1).strip() + '\n' if m else None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    version = sys.argv[1].lstrip('v')
    with open('CHANGELOG.md', encoding='utf-8') as f:
        body = section(f.read(), version)
    if not body:
        sys.exit(f'CHANGELOG.md has no section for {version}. Add "## {version} - <date>" with what changed.')
    sys.stdout.write(body)


if __name__ == '__main__':
    main()
