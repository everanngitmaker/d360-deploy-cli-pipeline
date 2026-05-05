#!/usr/bin/env python3
"""
Pre-deploy conflict check.

Compares local force-app/main/default/ against an org snapshot to detect
real conflicts (local differs from what's in the org) vs fake conflicts
(component exists in org but matches local — SF CLI flags these because
we don't keep source tracking state).

Exit codes:
  0  — no real conflicts; safe to deploy with --ignore-conflicts
  1  — real conflicts found; print details and abort
  2  — usage error

Usage:
    pre_deploy_check.py <local_dir> <org_snapshot_dir> <manifests_dir> <org_alias>
"""

import sys
import os

# Import shared logic from diff_report in the same directory
sys.path.insert(0, os.path.dirname(__file__))
from diff_report import parse_manifests, collect_files, read_text, build_diff


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    local_dir, org_dir, manifests_dir, org_alias = sys.argv[1:5]

    expected = parse_manifests(manifests_dir)
    if not expected:
        print(f'ERROR: no manifest members found in {manifests_dir}', file=sys.stderr)
        sys.exit(2)

    local_files = collect_files(local_dir, expected)
    org_files   = collect_files(org_dir,   expected)

    # Real conflicts: file exists in both sides but content differs.
    # (Files only in local = new deployments, not conflicts.)
    real_conflicts = sorted(
        rel for rel in set(local_files) & set(org_files)
        if local_files[rel] != org_files[rel]
    )

    if not real_conflicts:
        in_org_count    = len(set(local_files) & set(org_files))
        new_count       = len(set(local_files) - set(org_files))
        print(f'  {in_org_count} component(s) already in org match local — safe to deploy.')
        if new_count:
            print(f'  {new_count} new component(s) will be created.')
        sys.exit(0)

    print()
    print('=' * 60)
    print(f'REAL CONFLICTS DETECTED — {org_alias} has manual changes')
    print('=' * 60)
    print(f'  {len(real_conflicts)} component(s) differ between local and {org_alias}:')
    print()
    for rel in real_conflicts:
        print(f'  {rel}')
        diff = build_diff(read_text(local_dir, rel), read_text(org_dir, rel))
        for line in diff.splitlines()[:20]:
            print(f'    {line}')
        if len(diff.splitlines()) > 20:
            print(f'    ... ({len(diff.splitlines()) - 20} more lines)')
        print()
    print('Run ./scripts/4-compare.sh org-vs-branch to review before deploying.')
    print('=' * 60)
    sys.exit(1)


if __name__ == '__main__':
    main()
