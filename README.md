# D360 Deploy CLI Pipeline

A Git-based deployment pipeline for Salesforce Data Cloud metadata using the Salesforce CLI. Promotes changes through environments (dev → stage → prod) using three shell scripts and a branch-per-environment structure.

## What's in this repo

```
├── scripts/
│   ├── 1-retrieve.sh       # retrieve metadata from dev org, commit, push
│   ├── 2-pr.sh             # create PR, enforce promotion order
│   ├── 3-deploy.sh         # preprocess metadata, deploy to target org
│   ├── 4-compare.sh        # detect drift between orgs or branches
│   └── diff_report.py      # generates HTML drift report (called by 4-compare.sh)
├── config/
│   └── pipeline.config     # defines your promotion order and org→branch map
├── manifests/              # drop your package.xml here before each deployment
├── force-app/              # metadata retrieved from your orgs lives here (gitignored)
├── .claude/
│   └── skills/
│       ├── d360-deploy.md      # Claude skill: deployment and pipeline workflow
│       └── d360-org-diff.md    # Claude skill: drift detection between orgs/branches
└── D360_CLI_DEPLOYMENT_GUIDE.md
```

## Getting started

See **[D360_CLI_DEPLOYMENT_GUIDE.md](./D360_CLI_DEPLOYMENT_GUIDE.md)** for the full guide, including:
- Comparison of deployment options (Change Set vs CLI vs third-party tools)
- Step-by-step process overview with prerequisites
- Git and repo basics with diagrams
- CLI command reference
- Known limitations and workarounds

## Quick setup

1. Clone this repo and create one branch per environment:
   ```bash
   gh repo clone <org>/d360-deploy-cli-pipeline
   cd d360-deploy-cli-pipeline
   git checkout -b prod && git push -u origin prod
   git checkout -b stage && git push -u origin stage
   git checkout -b dev && git push -u origin dev
   gh repo edit --default-branch prod
   ```

2. Update `config/pipeline.config` with your environments:
   ```
   PROMOTION_ORDER=dev,stage,prod
   ORG_BRANCH_MAP="<dev-alias>:dev,<stage-alias>:stage,<prod-alias>:prod"
   ```

3. Authenticate your Salesforce orgs:
   ```bash
   sf org login web --alias <dev-alias>
   sf org login web --alias <stage-alias>
   sf org login web --alias <prod-alias>
   ```

4. Export a manifest from **Data Cloud Setup → Data Kits**, place it in `manifests/`, then run:
   ```bash
   git checkout -b feature/your-change
   ./scripts/1-retrieve.sh <dev-alias> "describe your change"
   ```

## Basic deployment flow

```
1-retrieve.sh   →   2-pr.sh + merge (dev)   →   2-pr.sh + merge + 3-deploy.sh (stage)   →   2-pr.sh + merge + 3-deploy.sh (prod)
```

After each deploy, go to **Data Cloud Setup → Data Kits → Deploy** in the target org to activate data streams.

## Drift detection

`4-compare.sh` compares metadata between orgs or branches to detect drift and backlogs. Three modes:

```bash
# Did anyone change the org directly, bypassing the pipeline?
./scripts/4-compare.sh org-vs-branch <org-alias>

# What's deployed in one org but not promoted to the next yet?
./scripts/4-compare.sh org-vs-org <org-a> <org-b>

# What's merged to one branch but not the other yet?
./scripts/4-compare.sh branch-vs-branch <branch-a> <branch-b>
```

Each run produces a terminal summary and an HTML report saved to `reports/` (gitignored). Add your org→branch mapping to `config/pipeline.config`:

```
ORG_BRANCH_MAP="<dev-alias>:dev,<stage-alias>:stage,<prod-alias>:prod"
```

## Claude skills

The `.claude/skills/` directory contains two skills for use with [Claude Code](https://claude.ai/code):

| Skill | Trigger |
|---|---|
| `d360-deploy.md` | Deploying, retrieving, promoting changes, setting up a new pipeline |
| `d360-org-diff.md` | Comparing orgs or branches, investigating drift |

Claude Code automatically loads skills from `.claude/skills/` when you open the repo. No installation needed.

## Requirements

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- [GitHub CLI](https://cli.github.com) (`gh`)
- Git
- Python 3
