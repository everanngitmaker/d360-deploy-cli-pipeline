---
name: d360-deploy
description: >
  Use this skill for any Salesforce Data Cloud metadata deployment task: deploying or
  retrieving Data Cloud metadata, promoting changes between environments (dev/stage/uat/prod),
  running pipeline scripts (1-retrieve.sh, 2-pr.sh, 3-deploy.sh), setting up a new Data Cloud
  devops repo from scratch, first-time repo setup, configuring pipeline.config promotion order,
  Data Kit deployments, troubleshooting failed deploys, ExtDataTranFieldTemplate errors, or
  working with d360devops2 or any similar branch-per-environment Salesforce pipeline.
  Trigger whenever the user wants to deploy, retrieve, promote, or set up a Data Cloud pipeline,
  even if they don't use those exact words.
---

# D360 Data Cloud Deployment Pipeline

This skill covers two scenarios:
- **Existing repo** — you already have a repo using this pipeline (e.g. `d360devops2`)
- **New repo** — you're setting up a new project from scratch

---

## How to orient yourself

Before helping the user, figure out which situation they're in:

1. **Existing repo** — run `cat config/pipeline.config` to find the actual `PROMOTION_ORDER` and `sf org list` to find their org aliases. Use those, not the examples in this skill.
2. **New repo** — follow the "New repo setup" section below.
3. **Different project** — same pipeline pattern applies; just use their project's org aliases and branch names.

The org aliases in examples (e.g. `mysdo-dev`, `mysdo-stage`, `mysdo`) are specific to `d360devops2`. Every project uses different names — always confirm with `sf org list`.

---

## New repo setup

Use this when starting a Data Cloud deployment pipeline from scratch.

### 1. Create the GitHub repo and clone it

```bash
gh repo create <your-repo-name> --private --clone
cd <your-repo-name>
```

### 2. Create the branch structure

One branch per environment, plus a branch for each in the promotion order. The last branch is production:

```bash
git checkout -b prod
git push -u origin prod

# Repeat for each environment in your pipeline
git checkout -b stage
git push -u origin stage

git checkout -b dev
git push -u origin dev
```

Set `prod` as the default branch on GitHub:
```bash
gh repo edit --default-branch prod
```

### 3. Create the directory structure

```bash
mkdir -p scripts config manifests force-app/main/default
```

Copy the pipeline scripts (`1-retrieve.sh`, `2-pr.sh`, `3-deploy.sh`) into `scripts/` and make them executable:
```bash
chmod +x scripts/1-retrieve.sh scripts/2-pr.sh scripts/3-deploy.sh
```

### 4. Configure the promotion order

Create `config/pipeline.config` and set `PROMOTION_ORDER` to list every environment from first-to-validate through to production:

```
PROMOTION_ORDER=dev,stage,prod
```

More environments:
```
PROMOTION_ORDER=dev,stage,uat,training,prod
```

Commit and push:
```bash
git add .
git commit -m "initial pipeline setup"
git push
```

### 5. Authenticate your Salesforce orgs

One `sf org login` per org in your pipeline. Choose aliases that are meaningful to you — they don't have to match the branch names exactly, but being consistent helps:

```bash
sf org login web --alias <your-dev-alias>
sf org login web --alias <your-stage-alias>
sf org login web --alias <your-prod-alias>
```

Verify: `sf org list`

### 6. Export and place your first manifest

In Salesforce, go to **Data Cloud Setup → Data Kits**, open your Data Kit, and export the manifest (`package.xml`). Place it in `manifests/`.

You're now ready to run the full promotion workflow below.

---

## First-time setup (existing repo)

If joining an existing repo for the first time:

### 1. Authenticate your orgs

```bash
sf org list   # see what's already authenticated
```

Authenticate any missing orgs — ask the repo owner for the correct aliases:
```bash
sf org login web --alias <org-alias>
```

### 2. Check your pipeline config

```bash
cat config/pipeline.config
```

This tells you the promotion order. Make sure you have a branch for each environment:
```bash
git fetch --all
git branch -a
```

### 3. Verify GitHub access

```bash
gh auth status
git remote -v
```

If not authenticated: `gh auth login`

### 4. Verify CLI tools

```bash
sf --version
gh --version
```

---

## Full promotion workflow

**Before every deployment, confirm:**
- Change is built and published in the dev org
- Manifest re-exported from Data Kit UI **today** (check file date)
- `package.xml` placed in `manifests/` on the feature branch
- After retrieve, `DataPackageKitObjects/` contains a file for every `DataPackageKitObject` member

### Step 1 — Create feature branch off prod

Prod is always the last branch in `PROMOTION_ORDER` — it's the production baseline:

```bash
git checkout prod && git pull
git checkout -b feature/your-change-name
```

Place the manifest in `manifests/`.

### Step 2 — Retrieve from dev org

```bash
./scripts/1-retrieve.sh <dev-org-alias> "describe what changed"
```

This clears stale data kit folders, retrieves metadata for each manifest, and commits + pushes to GitHub.

### Step 3 — Promote through each environment in order

`2-pr.sh` enforces `PROMOTION_ORDER` — it blocks merging to a later env until all preceding ones are merged.

`2-pr.sh` ends with an interactive merge prompt that won't work when run through Claude Code (no stdin). Always merge with `gh pr merge` after the script creates the PR.

Work through each environment **one at a time** in the order defined by `PROMOTION_ORDER`. Do not move to the next environment until the current one is fully complete — including the manual UI step.

---

**For the first environment (dev)** — PR only, no deploy needed. The dev org already has the changes you built there:
```bash
./scripts/2-pr.sh feature/your-change-name <dev-branch>
gh pr merge <PR-number> --merge
```

✅ Tell the user: "Merged to dev. Ready to promote to the next environment — \<next-env\>?"

---

**For each subsequent environment (every env except the last/prod):**

```bash
./scripts/2-pr.sh feature/your-change-name <env-branch>
gh pr merge <PR-number> --merge
git checkout <env-branch> && git pull
./scripts/3-deploy.sh <org-alias-for-env>
```

After the deploy script succeeds, **stop and ask the user**:

> "Deployment to \<org-alias\> is done. Now go to **Data Cloud Setup → Data Kits → Deploy** in that org to activate the data streams. Let me know when that's done — and also re-add any KQ assignments via **Data Cloud Setup → Data Lake Objects** if needed."

**Do not proceed to the next environment until the user confirms** the Data Kit has been deployed in the UI.

---

**For the last environment (prod):**

`3-deploy.sh` prompts for `yes` confirmation — pipe it in:
```bash
./scripts/2-pr.sh feature/your-change-name <prod-branch>
gh pr merge <PR-number> --merge
git checkout <prod-branch> && git pull
echo "yes" | ./scripts/3-deploy.sh <prod-org-alias>
```

After success, ask the user to complete the same manual steps in prod:

> "Deployment to prod is done. Go to **Data Cloud Setup → Data Kits → Deploy** in prod to activate the data streams. Let me know when that's done."

---

**Example walkthrough (PROMOTION_ORDER=dev,stage,prod, d360devops2 aliases):**

```bash
# 1. dev — PR only
./scripts/2-pr.sh feature/my-change dev
gh pr merge <PR#> --merge
# → Tell user: "Merged to dev. Ready to promote to stage?"

# 2. stage — deploy, then WAIT for user to confirm Data Kit deploy in UI
./scripts/2-pr.sh feature/my-change stage
gh pr merge <PR#> --merge
git checkout stage && git pull && ./scripts/3-deploy.sh mysdo-stage
# → Tell user: "Deployed to stage. Please go to Data Cloud Setup → Data Kits → Deploy in mysdo-stage. Let me know when done."
# → WAIT for confirmation before continuing

# 3. prod — deploy, then remind about Data Kit deploy in prod
./scripts/2-pr.sh feature/my-change prod
gh pr merge <PR#> --merge
git checkout prod && git pull
echo "yes" | ./scripts/3-deploy.sh mysdo
# → Tell user: "Deployed to prod. Please go to Data Cloud Setup → Data Kits → Deploy in mysdo. Let me know when done."
```

### Step 4 — Clean up

After the user confirms prod Data Kit deploy is done, clean up the feature branch:

```bash
git branch -d feature/your-change-name
git push origin --delete feature/your-change-name
```

---

## After every deployment — manual steps required

| Step | Where |
|------|-------|
| Trigger Data Kit deploy | Data Cloud Setup → Data Kits → **Deploy** |
| Re-add KQ assignments to DMOs | Data Cloud Setup → Data Lake Objects |

KQ_ fields are stripped by the deploy script (platform bug GUS W-19660646) and must be re-added via UI after each deploy.

---

## Known limitations

### Calculated Insights with dependencies

**`3-deploy.sh` is not affected** — both Calculated Insights can be deployed together in a single run regardless of dependency order. Salesforce handles it internally.

The dependency only matters for the **Data Kit deploy** (the manual UI step). If one Calculated Insight references another via `__cio`, the base must be deployed and published before you trigger the Data Kit deploy for the dependent one:

1. In **Data Cloud Setup → Data Kits**, deploy and publish the base Calculated Insight's kit first.
2. Once published (schema established), deploy and publish the dependent kit.

Put the two Calculated Insights in **separate Data Kits** so you can control the publish order in the UI. When guiding the user through the manual Data Kit deploy step, remind them of this order if CIs are involved.

---

## Known platform workarounds (all automated)

| Issue | Workaround |
|-------|------------|
| `ExtDataTranFieldTemplate` not supported by Metadata API | Stripped from manifests before retrieve/deploy; restored after |
| `KQ_` fields cause deploy errors | `KQ_*.field-meta.xml` deleted before deploy; members removed from manifests |
| Orphaned manifest members | Detected and removed automatically before deploy |

---

## Troubleshooting

**`2-pr.sh` interactive prompt shows "Invalid choice"** — The script's merge prompt requires stdin, which doesn't work in Claude Code. The PR was still created; merge it with `gh pr merge <PR#> --merge`.

**"not merged into \<prev-branch\> yet"** — `2-pr.sh` is enforcing `PROMOTION_ORDER`. Merge to the preceding environment first.

**Retrieve fails** — Check org is authenticated (`sf org list`). Check manifest is valid and Data Kit is published in the source org.

**Deploy fails** — Check org authentication (`sf org list`). Review component errors in the deploy output.

**Git pull fails** — Resolve conflicts before deploying.

**Manifest has no XML** — Place at least one `package.xml` in `manifests/` before running retrieve or deploy.
