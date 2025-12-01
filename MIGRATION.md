# Migration Guide: Single Job → Parallelized Workflow

## Overview

This guide will help you migrate from the single-job workflow (which times out at 30+ minutes) to the new parallelized two-stage workflow (which completes in ~5-6 minutes).

## What Changed

### Architecture

**Before**: Single monolithic job
```
Job: delete-stale-branches
├── Checkout repo
├── Fetch ALL branches (20+ minutes) ⚠️
├── Fetch open PRs
└── Process all branches sequentially
```

**After**: Two-stage parallelized jobs
```
Job 1: discover (30 seconds)
├── List all branches via git ls-remote
└── Split into batches → output matrix

Job 2: process (runs 10 in parallel, ~5 minutes each)
├── Checkout repo
├── Fetch ONLY assigned branches (2 minutes)
├── Fetch open PRs (cached)
└── Process assigned branches
```

## Step-by-Step Migration

### Step 1: Update Your Action Version

Update to the latest version that includes parallelization support:

```yaml
uses: betterup/delete-old-branches-action@v0.0.16  # or later
```

The discovery action is in a subdirectory:

```yaml
uses: betterup/delete-old-branches-action/discovery@v0.0.16
```

### Step 2: Replace Your Workflow File

**Old workflow** (`.github/workflows/delete-stale-branches.yml`):

```yaml
name: Delete Stale Branches
on:
  schedule:
    - cron: '30 2 * * *'

jobs:
  delete-stale-branches:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: betterup/delete-old-branches-action@v0.0.15
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          date: "60 days ago"
          dry_run: false
          exclude_open_pr_branches: true
          extra_protected_branch_regex: "^(main|staging|production|gov-|gh-pages|release/.*)$"
```

**New workflow** (parallelized):

```yaml
name: Delete Stale Branches (Parallelized)
on:
  workflow_dispatch:
  schedule:
    - cron: '30 2 * * *'

# Prevent concurrent runs
concurrency:
  group: delete-stale-branches
  cancel-in-progress: false

jobs:
  # Stage 1: Discovery
  discover:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.discover.outputs.matrix }}
    steps:
      - name: Discover and batch branches
        id: discover
        uses: betterup/delete-old-branches-action/discovery@v0.0.16
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          batch_size: "100"
          # Optional: Filter branches during discovery to reduce processing
          default_branches: "main,master"
          exclude_open_pr_branches: "true"
          extra_protected_branch_regex: "^(main|staging|production|gov-|gh-pages|release/.*)$"

  # Stage 2: Process in parallel
  process:
    needs: discover
    runs-on: ubuntu-latest
    strategy:
      max-parallel: 10
      fail-fast: false
      matrix: ${{ fromJson(needs.discover.outputs.matrix) }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Delete stale branches (Batch ${{ matrix.batch }})
        id: delete
        uses: betterup/delete-old-branches-action@v0.0.16
        with:
          repo_token: ${{ secrets.GITHUB_TOKEN }}
          date: "60 days ago"
          dry_run: false
          exclude_open_pr_branches: true
          extra_protected_branch_regex: "^(main|staging|production|gov-|gh-pages|release/.*)$"
          branch_list: ${{ matrix.branches }}

      - name: Report results
        if: always()
        run: |
          echo "✅ Batch ${{ matrix.batch }}: Processed ${{ matrix.count }} branches"
          echo "Deleted branches (${{ steps.delete.outputs.deleted_count }}): ${{ steps.delete.outputs.deleted_branches }}"
          echo "Branches with errors (${{ steps.delete.outputs.error_count }}): ${{ steps.delete.outputs.error_branches }}"
```

### Understanding Action Outputs

The delete action provides outputs that you can use in subsequent steps:

| Output | Description | Example |
|--------|-------------|---------|
| `deleted_branches` | Space-separated list of deleted branch names | `feat/old-feature fix/bug-123` |
| `deleted_count` | Number of branches successfully deleted | `2` |
| `error_branches` | Space-separated list of branches with errors | `broken:no_sha` |
| `error_count` | Number of branches that had errors | `1` |
| `was_dry_run` | Whether the action ran in dry-run mode | `true` or `false` |

**Example usage:**
```yaml
- name: Delete stale branches
  id: delete
  uses: betterup/delete-old-branches-action@v0.0.16
  with:
    repo_token: ${{ secrets.GITHUB_TOKEN }}
    date: "60 days ago"
    branch_list: ${{ matrix.branches }}

- name: Report results
  if: always()
  run: |
    echo "Deleted (${{ steps.delete.outputs.deleted_count }}): ${{ steps.delete.outputs.deleted_branches }}"
    echo "Errors (${{ steps.delete.outputs.error_count }}): ${{ steps.delete.outputs.error_branches }}"
```

**Note:** You must add an `id` to the action step (e.g., `id: delete`) to reference its outputs using `steps.delete.outputs.*`.

### Step 3: Test in Dry-Run Mode First

1. Set `dry_run: true` in the new workflow
2. Trigger manually via `workflow_dispatch` (not via schedule)
3. Review the Actions logs to ensure:
   - Discovery job completes quickly (~30s)
   - Worker jobs run in parallel
   - No branches are accidentally deleted
4. Once confident, set `dry_run: false`

### Step 4: Monitor the First Real Run

Watch the first real run closely:
- Check that all batches complete successfully
- Verify deleted branches are actually stale
- Confirm total runtime is under 10 minutes

## Configuration Tuning

### Discovery Stage Filtering (Recommended)

The discovery stage can now filter out protected branches **before** creating batches. This dramatically reduces API calls and processing time:

```yaml
# In the discover step:
with:
  repo_token: ${{ secrets.GITHUB_TOKEN }}
  batch_size: "100"
  # Filter branches during discovery
  default_branches: "main,master"              # Default branches to exclude
  exclude_open_pr_branches: "true"              # Exclude branches with open PRs
  extra_protected_branch_regex: "^(main|staging|production|gov-|gh-pages|release/.*)$"
```

**Benefits**:
- ✅ Reduces branches sent to process stage by 30-50%
- ✅ Fewer API calls to GitHub
- ✅ Faster overall execution
- ✅ Process stage still has defensive checks as safety net

**Example**: If you have 1000 branches:
- Without filtering: All 1000 branches sent to process stage
- With filtering: ~650 branches after removing protected/PR branches
- **Result**: 35% fewer API calls, faster execution

### Adjusting Batch Size

**Small batches** (50-75 branches):
- ✅ More granular parallelism
- ✅ Faster individual jobs
- ❌ More parallel jobs (may hit GitHub rate limits)

**Large batches** (150-200 branches):
- ✅ Fewer parallel jobs
- ✅ Less GitHub Actions overhead
- ❌ Longer individual jobs
- ❌ Less parallelism benefit

**Recommended**: Start with 100, adjust based on your needs.

```yaml
batch_size: "100"  # Default, good for most repos
```

### Adjusting Parallelism

Control how many worker jobs run simultaneously:

```yaml
strategy:
  max-parallel: 10  # Default
```

**Lower values** (5-8):
- Less API pressure on GitHub
- Longer total runtime but more reliable

**Higher values** (15-20):
- Fastest total runtime
- May hit GitHub API rate limits
- Use only if you have GitHub Enterprise or high rate limits

## Rollback Plan

If the parallelized workflow causes issues:

1. Revert to the old workflow file
2. Use the old action version: `@v0.0.15`
3. Accept the 30-minute runtime or split branches manually

## Common Issues

### Issue: Discovery job fails with "authentication failed"

**Solution**: Ensure `repo_token` input is set correctly:

```yaml
uses: betterup/delete-old-branches-action/discovery@v0.0.16
with:
  repo_token: ${{ secrets.GITHUB_TOKEN }}
```

### Issue: Worker jobs fail with "branch not found"

**Cause**: Branch was deleted between discovery and processing stages.

**Solution**: This is expected and handled gracefully. The script will log a warning and continue.

### Issue: Still timing out

**Possible causes**:
- Batch size too large → reduce to 50-75
- Too many branches → increase `max-parallel` to 15-20
- Network issues → retry the workflow

## Performance Expectations

Based on testing with betterup-monolith (26,578 files, 1000+ branches):

| Metric | Old (Single Job) | New (Parallelized) |
|--------|------------------|-------------------|
| Total Runtime | 30+ min ⚠️ | 5-6 min ✅ |
| Git Fetch Time | 20+ min | ~2 min per batch |
| Success Rate | ❌ Timeout | ✅ Completes |
| Debuggability | Hard (monolithic) | Easy (per-batch logs) |

## Support

If you encounter issues during migration:

1. Check logs for each batch individually
2. Test with `dry_run: true` first
3. Start with conservative settings (batch_size=100, max-parallel=10)
4. Open an issue with the full workflow logs

## Next Steps

1. ✅ Update to latest action version
2. ✅ Replace workflow file with parallelized version
3. ✅ Test with dry_run=true
4. ✅ Monitor first real run
5. ✅ Tune configuration if needed
