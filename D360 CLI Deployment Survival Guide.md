# D360 CLI Deployment Survival Guide

---

## 1. Deployment Options

Salesforce Data Cloud metadata can be deployed using three approaches. Each builds on a Data Kit as the packaging mechanism, but differs in tooling and supported capabilities.


| Feature                          | Data Kit + Change Set | Data Kit + CLI          | Data Kit + Third-Party Tools (Copado, Gearset) |
| -------------------------------- | --------------------- | ----------------------- | ---------------------------------------------- |
| Dependency management            | ✅                     | ✅                       | ✅                                              |
| Version control                  | —                     | ✅ (when Git is enabled) | ✅                                              |
| Conflict management & resolution | —                     | —                       | ✅                                              |
| Traceability                     | —                     | —                       | ✅                                              |


> **This guide covers Data Kit + CLI.**

---

## 2. Process Overview

### Prerequisites

Before running any pipeline commands, make sure the following are installed and configured on your machine:

**Tools:**

**Salesforce CLI (`sf`)** — the command-line tool for connecting to Salesforce orgs, retrieving metadata, and deploying changes. This is what does the actual work of pulling components out of dev and pushing them into stage and prod.

```bash
npm install -g @salesforce/cli
sf --version
```

**GitHub CLI (`gh`)** — lets you interact with GitHub from the terminal: create pull requests, merge them, and manage branches without opening a browser.

```bash
brew install gh      # macOS
gh --version
```

**Git** — tracks every change to your metadata files and manages branches. Comes pre-installed on macOS.

```bash
git --version
```

**Python 3** — used by the pipeline scripts to preprocess manifests before retrieve and deploy (stripping unsupported metadata types, removing KQ_ fields, etc.). Comes pre-installed on macOS.

```bash
python3 --version
```

**Authentication:**

```bash
# Authenticate GitHub
gh auth login

# Authenticate each Salesforce org (one command per org)
sf org login web --alias <dev-org-alias>
sf org login web --alias <stage-org-alias>
sf org login web --alias <prod-org-alias>

# Verify all orgs are connected
sf org list
```

**Repo setup (first time only):**

```bash
# Clone the repo and move into it
gh repo clone <org>/<repo-name>
cd <repo-name>

# Fetch all environment branches
git fetch --all
git branch -a     # confirm dev, stage, prod branches are visible
```

---

### Development

1. **Build changes in the dev sandbox** — create or modify Data Cloud objects, data streams, mappings, or other components directly in the dev org UI.
2. **Create a DevOps Data Kit** — in the dev org, go to **Data Cloud Setup → Data Kits** and create a Data Kit that groups the components you want to promote. This is what the pipeline uses as the unit of deployment.
3. **Download the manifest** — export the `package.xml` from the Data Kit UI and place it in the `manifests/` folder of your local repo. The manifest tells the CLI exactly which components to retrieve and deploy.

### Version Control

1. **Create a feature branch off `prod`** — `prod` is the production baseline, so all feature branches start there. Branching off `dev` or `stage` would pull in metadata from other in-progress features that haven't reached production yet, contaminating your change with unrelated work:
  ```bash
   git checkout prod && git pull
   git checkout -b feature/your-change-name
  ```
2. **Pull metadata from the dev sandbox** — retrieve the components listed in your manifest from the dev org and commit them to the feature branch (This is equivalent to pulling dependencies during Change Set creation):
  ```bash
   ./scripts/1-retrieve.sh <dev-org-alias> "describe what changed"
  ```

### Promotion

1. **Create a PR to `dev` and merge** — the feature branch is promoted to `dev` first. No deployment is needed here because the dev sandbox already has the changes you built in step 1. This step just syncs the Git history.
  ```bash
   ./scripts/2-pr.sh feature/your-change-name dev
   gh pr merge <PR#> --merge
  ```
2. **Create a PR to `stage`, merge, and deploy** — once merged to `dev`, promote to `stage` and run the deploy script to push metadata into the stage org:
  ```bash
   ./scripts/2-pr.sh feature/your-change-name stage
   gh pr merge <PR#> --merge
   git checkout stage && git pull
   ./scripts/3-deploy.sh <stage-org-alias>
  ```
3. **Trigger the Data Kit deploy in the stage org** — after the CLI deploy, go to **Data Cloud Setup → Data Kits → Deploy** in the stage org. This step activates data streams and other runtime components that the Metadata API alone does not activate. The expectation is that the Data Kit and all its dependencies are installed in stage after this step.
  > **Note:** This manual UI step is a current limitation. Programmatic triggering of the Data Kit deploy is on the roadmap and will eventually be available via API.
4. **Create a PR to `prod`, merge, and deploy** — once validated in stage, promote to prod:
  ```bash
   ./scripts/2-pr.sh feature/your-change-name prod
   gh pr merge <PR#> --merge
   git checkout prod && git pull
   echo "yes" | ./scripts/3-deploy.sh <prod-org-alias>
  ```
5. **Trigger the Data Kit deploy in the prod org** — same as step 8, in the prod org.
6. **Clean up the feature branch**:
  ```bash
    git branch -d feature/your-change-name
    git push origin --delete feature/your-change-name
  ```

---

## 3. Repo Basics

### The Three Places Your Work Lives

Working with this pipeline means keeping three things in sync: your **local machine**, **GitHub**, and your **Salesforce orgs**. These are completely separate systems and changes in one don't automatically appear in the others.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SALESFORCE ORGS                              │
│                                                                     │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│   │   dev org   │     │  stage org  │     │  prod org   │           │
│   │             │     │             │     │             │           │
│   │  where you  │     │  validation │     │  live       │           │
│   │  build &    │     │  environment│     │  environment│           │
│   │  test       │     │             │     │             │           │
│   └──────┬──────┘     └──────▲──────┘     └──────▲──────┘           │
│          │                   │                   │                  │
│     sf project          sf project           sf project             │
│     retrieve start      deploy start         deploy start           │
└──────────┼───────────────────┼───────────────────┼──────────────────┘
           │                   │                   │
           ▼                   │                   │
┌─────────────────────────────────────────────────────────────────────┐
│                     YOUR LOCAL MACHINE                              │
│                                                                     │
│   ┌──────────────────────────────────────────────────────┐          │
│   │  Local Git Repository  (the folder on your laptop)   │          │
│   │                                                      │          │
│   │   feature/xyz  ◄── you work here                     │          │
│   │   dev                                                │          │
│   │   stage                                              │          │
│   │   prod                ◄── production baseline        │          │
│   └────────────────┬──────────────────────────────────-──┘          │
└────────────────────┼────────────────────────────────────────────────┘
                     │
                git push / git pull
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          GITHUB                                     │
│                                                                     │
│   ┌──────────────────────────────────────────────────────┐          │
│   │  Remote Git Repository  (the cloud copy)             │          │
│   │                                                      │          │
│   │   feature/xyz                                        │          │
│   │   dev                                                │          │
│   │   stage                                              │          │
│   │   prod                                               │          │
│   │                                                      │          │
│   │   Pull Requests live here                            │          │
│   └──────────────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────┘
```

**Key mental model:**

- A **Salesforce org** is a live environment — it has running data streams, UI configuration, and active users. You deploy *to* it.
- **GitHub** is the source of truth for your metadata. It stores the history of every change. Pull Requests are reviewed and merged here.
- Your **local machine** is where you run CLI commands. It's a working copy — you pull from GitHub to get the latest, and push to GitHub to share your changes.

A Salesforce org and a GitHub branch correspond to each other, but they are not automatically kept in sync. Running `3-deploy.sh` is what bridges them.

---

### Branch Structure

Each Salesforce environment has a corresponding Git branch. Changes flow in one direction only: dev → stage → prod.

```
GitHub branches                     Salesforce orgs

feature/your-change ─┐
                      ▼
                    dev ─────────────────────────► dev org (sandbox)
                      │
                      ▼
                   stage ────────────────────────► stage org (sandbox)
                      │
                      ▼
                    prod ─────────────────────────► prod org (production)
```

Feature branches always start from `prod` (the production baseline) and are merged into each environment in order before being deleted.

---

### Essential Git Commands

**See the current state of your local repo:**

```bash
git status          # what files have changed, what branch you're on
git log --oneline   # recent commit history
git branch -a       # all local and remote branches
```

**Get the latest code from GitHub:**

```bash
git pull            # download + merge remote changes into your current branch
git fetch --all     # download remote changes without merging (safe, read-only)
```

**Switch between branches:**

```bash
git checkout prod            # switch to an existing branch
git checkout -b feature/xyz  # create a new branch and switch to it
```

**Save and share your changes:**

```bash
git add -A                        # stage all changed files
git commit -m "describe change"   # save a snapshot locally
git push                          # upload to GitHub
```

**Undo / inspect:**

```bash
git diff                     # see uncommitted changes line by line
git log --oneline -10        # last 10 commits
git checkout -- <file>       # discard local changes to a file (destructive)
```

---

### How a Typical Deployment Connects the Three Systems

```
1. Build in dev org (UI)
        │
        │  export manifest → place in manifests/
        ▼
2. Local: git checkout -b feature/xyz
        │
        │  ./scripts/1-retrieve.sh mysdo-dev "..."
        │     → sf project retrieve start   (org → local files)
        │     → git push                    (local → GitHub)
        ▼
3. GitHub: open PR feature/xyz → dev, merge
4. GitHub: open PR feature/xyz → stage, merge
        │
        │  ./scripts/3-deploy.sh mysdo-stage
        │     → git pull                    (GitHub → local)
        │     → sf project deploy start     (local files → stage org)
        ▼
5. Stage org: Data Cloud Setup → Data Kits → Deploy  (manual)
        │
        │  (validate in stage)
        ▼
6. GitHub: open PR feature/xyz → prod, merge
        │
        │  ./scripts/3-deploy.sh mysdo
        │     → git pull                    (GitHub → local)
        │     → sf project deploy start     (local files → prod org)
        ▼
7. Prod org: Data Cloud Setup → Data Kits → Deploy   (manual)
```

---

### Repo Directory Structure

```
<repo-name>/
├── config/
│   └── pipeline.config          # defines PROMOTION_ORDER (e.g. dev,stage,prod)
├── force-app/
│   └── main/
│       └── default/             # all retrieved metadata lives here
│           ├── objects/         # custom fields, Data Lake Object definitions
│           ├── DataPackageKitObjects/
│           ├── dataPackageKitDefinitions/
│           ├── dataStreams/
│           └── ...              # other Data Cloud component types
├── manifests/
│   └── package.xml              # exported from Data Kit UI; tells CLI what to retrieve/deploy
└── scripts/
    ├── 1-retrieve.sh            # retrieve from dev org, commit, push
    ├── 2-pr.sh                  # create PR, enforce promotion order
    └── 3-deploy.sh              # preprocess metadata, deploy to target org
```

- `manifests/` — drop your exported `package.xml` here before every deployment
- `force-app/` — never edit files here manually; always let `1-retrieve.sh` populate it
- `scripts/` — the three pipeline scripts; copy these into any new repo using this pattern
- `config/pipeline.config` — the only file you configure when setting up a new repo

---

## 4. CLI Basics

### Salesforce CLI (`sf`)

Authenticate an org:

```bash
sf org login web --alias <alias>
```

List all authenticated orgs:

```bash
sf org list
```

Retrieve metadata from an org using a manifest:

```bash
sf project retrieve start --manifest manifests/package.xml --target-org <alias> --wait 30
```

Deploy metadata to an org using a manifest:

```bash
sf project deploy start --manifest manifests/package.xml --target-org <alias> --wait 30
```

Validate a deploy without making changes (dry run):

```bash
sf project deploy start --manifest manifests/package.xml --target-org <alias> --dry-run --wait 30
```

### GitHub CLI (`gh`)

Authenticate:

```bash
gh auth login
```

Check auth status:

```bash
gh auth status
```

Create a pull request:

```bash
gh pr create --base <target-branch> --head <source-branch> --title "<title>" --body ""
```

Merge a pull request:

```bash
gh pr merge <PR#> --merge
```

### Pipeline Scripts

The three pipeline scripts wrap the raw CLI commands with safety checks, preprocessing, and Git operations:


| Script                                               | Usage    | What it does                                                                                                                                                                                                                                                  |
| ---------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./scripts/1-retrieve.sh <org-alias> "<commit-msg>"` | Retrieve | Clears stale data kit folders, strips unsupported metadata types from the manifest, retrieves all components from the target org, commits and pushes to GitHub                                                                                                |
| `./scripts/2-pr.sh <source-branch> <target-branch>`  | Promote  | Enforces `PROMOTION_ORDER` from `pipeline.config` (blocks merging to a later environment if a preceding one is not yet merged), then creates the GitHub PR                                                                                                    |
| `./scripts/3-deploy.sh <org-alias> [--dry-run]`      | Deploy   | Pulls latest from GitHub, strips unsupported types, removes KQ_ fields, checks for orphaned manifest members, syncs CustomField members, then deploys. Prompts for `yes` confirmation when deploying to prod. Pass `--dry-run` to validate without deploying. |


### Pipeline Configuration

`config/pipeline.config` defines the required promotion order:

```
PROMOTION_ORDER=dev,stage,prod
```

`2-pr.sh` reads this file at runtime and enforces it — you cannot merge a feature branch to `stage` until it has been merged to `dev`, and you cannot merge to `prod` until it has been merged to `stage`.

---

## 5. Known Limitations

### KQ_ Fields Must Be Excluded and Reapplied Manually

KQ_ fields (Knowledge Quality fields) cannot be included in a metadata deployment — the Salesforce platform rejects them during deploy with an error (tracked as GUS W-19660646). As a workaround:

- `3-deploy.sh` automatically removes all `KQ_*.field-meta.xml` files and strips the corresponding `<members>` entries from the manifest before deploying.
- After every deployment (stage and prod), KQ_ assignments must be **manually re-added** via **Data Cloud Setup → Data Lake Objects**.

This limitation affects all three deployment options (Change Set, CLI, and third-party tools) — there is no automated path to deploy KQ_ fields regardless of tooling.

### Data Kit Deploy Step Is Manual

After every CLI deploy, the Data Kit must be manually activated via the UI (**Data Cloud Setup → Data Kits → Deploy**). The `sf project deploy start` command deploys the metadata components, but does not trigger the Data Kit runtime activation (data stream ingestion, dependency wiring, etc.). Programmatic activation is on the product roadmap.

### ExtDataTranFieldTemplate Not Supported by the Metadata API

`ExtDataTranFieldTemplate` components appear in Data Kit manifests but are not supported by `sf project retrieve start` or `sf project deploy start`. The pipeline scripts automatically strip these entries from the manifest before retrieve and deploy, then restore the original manifest afterward. No manual action is needed, but the components are not version-controlled.

### CustomField Members Must Be Kept in Sync with Retrieved Files

The Metadata API requires that every `CustomField` listed in the manifest has a corresponding `.field-meta.xml` file on disk. If fields were deleted or renamed in the org since the last retrieve, the manifest can become out of sync and cause deploy failures. `3-deploy.sh` automatically reconciles `CustomField` manifest members against the files actually present before deploying.

### Orphaned Manifest Members Cause Deploy Failures

If a component listed in the manifest no longer exists in the org (e.g. a `DataPackageKitObject` that was deleted), the deploy fails. `3-deploy.sh` detects and removes orphaned members automatically before deploying.