# D360 DevOps — Data Cloud Deployment

This repository manages Data Cloud metadata across three environments using a branch-per-org pipeline.

---

## Branch Structure

| Branch         | Salesforce Org       | Purpose                                    |
|----------------|----------------------|--------------------------------------------|
| `prod`         | `<your-prod-alias>`  | Desired state of production                |
| `stage`        | `<your-stage-alias>` | Desired state of staging                   |
| `dev`          | `<your-dev-alias>`   | Integration / experimentation              |
| `feature/xxx`  | —                    | One branch per change, branched off `prod` |

---

## Promotion Workflow

Each change gets its own feature branch, promoted through dev → stage → prod in order.

### Checklist before starting

- [ ] Change is built and published in the dev org
- [ ] Manifest re-exported from Data Kit UI **today** (check file date)
- [ ] New `package.xml` dropped into `manifests/` on the feature branch
- [ ] After retrieve: `DataPackageKitObjects/` contains a file for every `DataPackageKitObject` member in the manifest

---

### Step 1 — Create a feature branch off prod

```bash
git checkout prod && git pull
git checkout -b feature/your-change-name
```

### Step 2 — Retrieve from dev org

Build your change in your dev org, export the manifest(s) from the Data Kit UI, place them in `manifests/`, then run:

```bash
./scripts/1-retrieve.sh <your-dev-alias> "describe what changed"
```

### Step 3 — Merge to dev

Dev already has the changes you built there — PR only, no deploy needed:

```bash
./scripts/2-pr.sh feature/your-change-name dev
gh pr merge <PR#> --merge
```

### Step 4 — Deploy to stage

```bash
./scripts/2-pr.sh feature/your-change-name stage
gh pr merge <PR#> --merge
git checkout stage && git pull
./scripts/3-deploy.sh <your-stage-alias>
```

After the deploy succeeds, complete the required UI steps (see [After Deployment](#after-deployment--manual-steps-required)).

### Step 5 — Deploy to prod

Once validated in stage:

```bash
./scripts/2-pr.sh feature/your-change-name prod
gh pr merge <PR#> --merge
git checkout prod && git pull
echo "yes" | ./scripts/3-deploy.sh <your-prod-alias>
```

After the deploy succeeds, complete the required UI steps in prod.

### Step 6 — Clean up feature branch

```bash
git branch -d feature/your-change-name
git push origin --delete feature/your-change-name
```

### Dry run (validate without deploying)

```bash
./scripts/3-deploy.sh <your-stage-alias> --dry-run
./scripts/3-deploy.sh <your-prod-alias> --dry-run
```

---

## Repository Structure

```
manifests/
└── *.xml                                ← One or more deployment manifests (package.xml files)

force-app/main/default/
├── DataPackageKitObjects/               ← Data Kit component list
├── dataKitObjectDependencies/           ← Data Kit dependency definitions
├── dataKitObjectTemplates/              ← Stream, identity resolution & data graph templates
├── dataPackageKitDefinitions/           ← Data Kit definition
├── dataSourceBundleDefinitions/         ← Ingest API bundle configs
├── dataSourceObjects/                   ← Data stream field mappings
├── dataSrcDataModelFieldMaps/           ← Field-level source-to-model mappings
├── dataStreamTemplates/                 ← Data stream blueprints
├── extDataTranObjectTemplates/          ← External data transformation templates
├── fieldSrcTrgtRelationships/           ← DMO relationship definitions
├── mktDataSources/                      ← Ingest API connector references
├── mktDatalakeSrcKeyQualifier/          ← Key qualifier definitions
└── objects/
    └── <ObjectName>/
        ├── <ObjectName>.object-meta.xml ← DMO schema definition
        └── fields/
            └── <FieldName>.field-meta.xml  ← Individual field definitions

config/
└── pipeline.config                      ← Defines required promotion order for feature branches

scripts/
├── 1-retrieve.sh                        ← Retrieve from org, commit and push to GitHub
├── 2-pr.sh                              ← Create PR with option to auto-merge
├── 3-deploy.sh                          ← Pull latest, preprocess, conflict check, deploy
└── 4-compare.sh                         ← Compare metadata between orgs and branches
```

> **Note:** This project uses Salesforce DX source format. All metadata files use the `-meta.xml` suffix and fields are stored as individual files under `objects/<ObjectName>/fields/`.

---

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf` command)
- All orgs authenticated:
  ```bash
  sf org login web --alias <your-dev-alias>
  sf org login web --alias <your-stage-alias>
  sf org login web --alias <your-prod-alias>
  ```
- Git configured with push access to this repository

---

## How the Scripts Work

### 1-retrieve.sh

```
1. Delete .sf/ to clear any stale source tracking state
2. Clear dataPackageKitDefinitions/ and DataPackageKitObjects/ (prevent stale entries)
3. Strip ExtDataTranFieldTemplate from each manifest (unsupported by Metadata API)
4. Retrieve each manifest into a clean temp directory outside the repo
5. Copy retrieved files back into force-app/main/default/
6. Restore all manifests to original state
7. Commit and push all retrieved metadata to GitHub
```

Retrieves use a temp directory outside the repo so SF CLI has no prior tracking state to consult, ensuring every manifest member is downloaded fresh. See `docs/decisions.md` for the full reasoning.

### 2-pr.sh

```
1. Check pipeline.config — enforce promotion order before allowing merge to next branch
2. Create PR from source branch to target branch
3. Present menu: open in browser / merge now / skip
```

> The interactive merge prompt requires stdin and won't work in automated contexts. Create the PR with `2-pr.sh`, then merge with `gh pr merge <PR#> --merge`.

### pipeline.config

Defines the required promotion sequence for feature branches. Edit `config/pipeline.config` to match your pipeline:

```
PROMOTION_ORDER=dev,stage,prod
```

With this setting, `2-pr.sh` will block a feature branch from being merged to `stage` unless it has already been merged to `dev`, and block `prod` unless already merged to `stage`.

### 3-deploy.sh

```
1. git pull — ensure local branch is up to date
2. Back up all manifests
3. Strip ExtDataTranFieldTemplate from each manifest
4. Orphan check — remove manifest members with no corresponding file on disk
5. Remove KQ_ fields — delete KQ_*.field-meta.xml files (platform bug workaround)
6. Sync CustomField members in manifests to match files on disk
7. DataPackageKitObject orphan check
8. Pre-deploy conflict check — retrieve org snapshot, compare against local
   - Real conflict (local ≠ org): abort and report differences
   - Fake conflict (local = org, no tracking state): approve --ignore-conflicts
9. Deploy each manifest separately with --ignore-conflicts
10. Restore all manifests to original state
```

### 4-compare.sh

Compares metadata between environments to detect drift or backlogs. Three modes:

```bash
./scripts/4-compare.sh org-vs-branch <org>                      # detect manual org changes
./scripts/4-compare.sh org-vs-org <org-a> <org-b>               # find env backlogs
./scripts/4-compare.sh branch-vs-branch <branch-a> <branch-b>   # find git backlogs
```

Each run:
1. Takes snapshots of both sides — retrieving from each org into a temp dir and/or adding a worktree for each branch.
2. Calls `diff_report.py` to diff the snapshots, filtered to the manifest(s) in `manifests/`.
3. Writes an HTML report to `reports/` (gitignored) and auto-opens it in the browser.

Temp dirs and git worktrees are deleted automatically after each run.

**Known gap — destructive changes in the Data Cloud UI are not detected.** When a mapping or field is manually deleted from the Data Cloud UI, the retrieve continues to return it because the published data kit state still references the deleted component. To confirm a UI deletion, check Data Cloud Setup directly.

---

## Known Workarounds Applied Automatically

| Issue | Workaround |
|---|---|
| `ExtDataTranFieldTemplate` not supported by Metadata API | Stripped from manifests before retrieve and deploy; restored afterwards |
| `KQ_` prefixed fields cause deployment errors (platform bug GUS W-19660646) | `KQ_*.field-meta.xml` files deleted before deploy; their `CustomField` members removed from manifests |
| Members in manifests not present in source org | Automatically detected and removed (orphan check) |
| SF CLI flags existing org components as conflicts (no tracking state) | Pre-deploy check distinguishes real vs fake conflicts; deploys with `--ignore-conflicts` only when org matches local |
| `<externalDataTranField>` and `<externalDataTranObject>` in `ExtDataTranObjectTemplate` cause false drift | Stripped by `diff_report.py` before hashing and diffing — present in natively-authored orgs (dev), absent after deployment (stage, prod); functionally redundant |

---

## After Deployment — Manual Steps Required

The required UI steps depend on what was deployed:

| What was deployed | UI step |
|---|---|
| Data streams, field mappings, data sources, bundles | **Data Cloud Setup → Data Kits → Deploy** |
| Calculated Insights with dependencies | Deploy base kit first, wait for it to publish, then deploy dependent kit |
| DMO relationships (`FieldSrcTrgtRelationship`), CustomFields, CustomObjects | None — active immediately after metadata deploy |
| KQ_ fields (stripped by script) | Re-add via **Data Cloud Setup → Data Lake Objects** |

---

## Known Limitations

### Calculated Insights with dependencies

**`3-deploy.sh` is not affected** — both Calculated Insights can be deployed together in a single run regardless of dependency order.

The dependency only matters for the **Data Kit deploy** (the manual UI step). If one Calculated Insight references another via `__cio`, the base must be deployed and published before you trigger the Data Kit deploy for the dependent one:

1. In **Data Cloud Setup → Data Kits**, deploy and publish the base Calculated Insight's kit first.
2. Once published (schema established), deploy and publish the dependent kit.

Put the two Calculated Insights in **separate Data Kits** so you can control the publish order in the UI.

### DMO relationships

`FieldSrcTrgtRelationship` metadata is not exported in Data Kit manifests by default. To deploy a DMO relationship through the pipeline:

1. Add the `FieldSrcTrgtRelationship` member and its generated `rel_*` CustomField to the manifest manually.
2. Run `1-retrieve.sh` to pull the relationship file from the source org.
3. Proceed with normal promotion.

No Data Kit deploy is required after deploying a relationship — it takes effect immediately.
