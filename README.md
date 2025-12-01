# Delete Old Branches Action

![Linting](https://github.com/beatlabs/delete-old-branches-action/workflows/Linting/badge.svg)

## Introduction

This simple GitHub Action will delete branches and optionally tags that haven't received a commit recently. The time since last commit is configurable.

The default behaviour is to exclude the default branch (main or master) and the Github protected branches. Default branch(es) can be overriden using the `default_branches` variable (e.g. `default_branches: develop` or for multiple default branches `default_branches: main,develop,my-default-branch`).

Additional branches can be excluded using the `extra_protected_branch_regex` variable (see example below).
Similarly, certain tags can be excluded using the `extra_protected_tag_regex` variable.
Also, branches with open pull requests are being ignored by default (see example below).  

## Disclaimer

**Always** run the GitHub action in dry-run mode to ensure that it will do the right thing before you actually let it do it. Also make sure that you have a full copy of the repository (`git clone --mirror ...`) in case something goes bad

## Example usage

```yaml
name: Cleanup old branches
on:
  push:
    branches:
      - master
      - develop
jobs:
  housekeeping:
    name: Cleanup old branches
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Run delete-old-branches-action
        uses: beatlabs/delete-old-branches-action@v0.0.10
        with:
          repo_token: ${{ github.token }}
          date: '3 months ago'
          dry_run: true
          delete_tags: true
          minimum_tags: 5
          extra_protected_branch_regex: ^(foo|bar)$
          extra_protected_tag_regex: '^v.*'
          exclude_open_pr_branches: true
```

Once you are happy switch, `dry_run` to `false` so the action actually does the job

## Parallelized Workflow for Large Repositories

For repositories with many branches (1000+) that are hitting the 30-minute GitHub Actions timeout, you can use the **parallelized two-stage workflow** approach:

### How It Works

1. **Discovery Stage**: A fast job that lists all branches using `git ls-remote` (no fetch needed) and splits them into batches
2. **Processing Stage**: Multiple parallel jobs that each process a batch of branches

This approach dramatically reduces execution time by:
- Avoiding the massive git fetch of all branches in a single job
- Each worker job only fetches the specific branches it needs to process
- Processing branches in parallel (up to 10 jobs by default)

### Example Parallelized Workflow

```yaml
name: Delete Stale Branches (Parallelized)

on:
  workflow_dispatch:
  schedule:
    - cron: '30 2 * * *'

concurrency:
  group: delete-stale-branches
  cancel-in-progress: false

jobs:
  # Stage 1: Discover branches and create batches
  discover:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.discover.outputs.matrix }}
    steps:
      - name: Discover branches
        id: discover
        uses: betterup/delete-old-branches-action/discovery@v0.0.16
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          batch_size: "100"

  # Stage 2: Process branches in parallel
  process:
    needs: discover
    runs-on: ubuntu-latest
    strategy:
      max-parallel: 10          # Number of parallel jobs
      fail-fast: false          # Continue even if one batch fails
      matrix: ${{ fromJson(needs.discover.outputs.matrix) }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Delete stale branches (Batch ${{ matrix.batch }})
        uses: betterup/delete-old-branches-action@v0.0.16
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          date: "60 days ago"
          dry_run: false
          exclude_open_pr_branches: true
          extra_protected_branch_regex: "^(main|staging|production|release/.*)$"
          branch_list: ${{ matrix.branches }}  # Process only this batch
```

### Configuration Options

- **`batch_size`**: Number of branches per batch (default: 100). Larger batches = fewer parallel jobs but longer per job.
- **`max-parallel`**: Maximum number of parallel worker jobs (default: 10). Higher values = faster but more resource usage.
- **`branch_list`**: Space-separated list of branches to process in batch mode. Automatically set by the discovery job.

### Performance Comparison

**Before (Single Job)**:
- Fetch all branches: ~20 minutes
- Process branches: ~10 minutes
- **Total: 30+ minutes** ⚠️ Timeout

**After (Parallelized with 10 workers)**:
- Discovery: ~30 seconds
- Each worker fetches ~100 branches: ~2 minutes
- Each worker processes ~100 branches: ~3 minutes
- **Total: ~5-6 minutes** ✅ 5x faster

### When to Use Parallelization

- ✅ Repository has 1000+ branches
- ✅ Single-job workflow times out (>30 minutes)
- ✅ git fetch operations are slow
- ❌ Repository has <500 branches (overhead not worth it)
- ❌ You need strict ordering of branch deletions

Happy cleaning!
