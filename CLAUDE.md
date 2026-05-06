# CLAUDE.md — d360-deploy-cli-pipeline

Template repository for a Salesforce Data Cloud metadata deployment pipeline. Provides scripts and structure for managing Data Cloud metadata across multiple environments using a branch-per-org model.

## What this repo is

A starting point for new Data Cloud devops projects. Copy the scripts, configure `pipeline.config` with your org aliases and promotion order, and follow the workflow below. For a working example of this pipeline in use, see `d360devops2`.

## Orgs and branches

Configured in `config/pipeline.config`:

```
PROMOTION_ORDER=dev,stage,prod
ORG_BRANCH_MAP="<your-dev-alias>:dev,<your-stage-alias>:stage,<your-prod-alias>:prod"
```

One branch per environment. The last branch in `PROMOTION_ORDER` is production. Feature branches are cut from the prod branch.
Both keys live in `config/pipeline.config`.

## Promotion workflow

```
1. Build change in dev org, export manifest from Data Kit UI → manifests/
2. ./scripts/1-retrieve.sh <dev-alias> "describe change"
3. ./scripts/2-pr.sh feature/name dev    → gh pr merge <#> --merge   (no deploy)
4. ./scripts/2-pr.sh feature/name stage  → gh pr merge <#> --merge
   git checkout stage && git pull && ./scripts/3-deploy.sh <stage-alias>
5. ./scripts/2-pr.sh feature/name prod   → gh pr merge <#> --merge
   git checkout prod && git pull && echo "yes" | ./scripts/3-deploy.sh <prod-alias>
   # Dry run: ./scripts/3-deploy.sh <prod-alias> --dry-run  (runs preflight checks, no actual deploy)
6. git branch -d feature/name && git push origin --delete feature/name
```

## What 3-deploy.sh does internally

1. `git pull`
2. Back up manifests
3. Strip `ExtDataTranFieldTemplate` (unsupported by Metadata API)
4. Orphan check — remove manifest members with no file on disk
5. Remove `KQ_*.field-meta.xml` files (platform bug GUS W-19660646)
6. Sync `CustomField` members to match files on disk
7. `DataPackageKitObject` orphan check
8. **Pre-deploy conflict check** — retrieve org into temp dir, compare against local
   - Local ≠ org → real conflict → abort, tell user to run `4-compare.sh org-vs-branch`
   - Local = org → fake conflict (no tracking state) → proceed with `--ignore-conflicts`
9. Deploy each manifest separately with `--ignore-conflicts`
10. Restore manifests

## After deployment — required UI steps

| What was deployed | UI step needed |
|---|---|
| Data streams, field mappings, data sources, bundles | Data Cloud Setup → Data Kits → **Deploy** |
| Calculated Insights with dependencies | Deploy base kit first, confirm published, then dependent kit |
| `FieldSrcTrgtRelationship`, CustomField, CustomObject | None — active immediately |
| KQ_ fields (stripped by script) | Re-add via Data Cloud Setup → Data Lake Objects |

## Known platform workarounds (all automated)

| Issue | Workaround |
|---|---|
| `ExtDataTranFieldTemplate` unsupported by Metadata API | Stripped before retrieve/deploy; restored after |
| `KQ_` fields cause deploy errors (GUS W-19660646) | Deleted before deploy; removed from manifests |
| Orphaned manifest members | Detected and removed before deploy |
| SF CLI conflict check false positives (no tracking state) | Pre-deploy check gates `--ignore-conflicts` |
| `<externalDataTranField>`/`<externalDataTranObject>` cause false drift in deployed orgs | Stripped by `diff_report.py` before hashing |

## Source tracking — disabled

`.sf/` is deleted at the start of every `1-retrieve.sh`. All retrieves go into a clean temp dir outside the repo. Reason: SF CLI tracking goes stale when changes are made in the org UI, causing silent skips on retrieve. Pipeline is manifest-driven — tracking provides no benefit and actively causes problems.

## DMO relationships

`FieldSrcTrgtRelationship` is not included in Data Kit manifests by default. To deploy one:
1. Add the `FieldSrcTrgtRelationship` member and its generated `rel_*` CustomField to the manifest manually
2. Run `1-retrieve.sh` to pull the file from dev
3. Promote normally — no Data Kit deploy needed after

## Drift detection

```bash
./scripts/4-compare.sh org-vs-branch <org>           # manual org changes
./scripts/4-compare.sh org-vs-org <org-a> <org-b>    # env backlogs
./scripts/4-compare.sh branch-vs-branch <a> <b>      # git backlogs
```

Outputs an HTML report in `reports/` (gitignored), auto-opened in browser.

**Known gap:** org-side destructive changes (e.g. manually deleting a field map in the UI) are NOT detected — Data Cloud's published Data Kit state still references them.
