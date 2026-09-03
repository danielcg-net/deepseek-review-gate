# Consumer integration

This guide applies to release `v1.21.0-bizyeet.2`, commit `9347235fe47109d65860b076eb84835c062dcbcb`. Pin the commit SHA in every consuming workflow; release tags are documentation, not a supply-chain pin.

## Security boundary

Use only the ordinary `pull_request` event. Do not use `pull_request_target`, self-hosted runners, or checkout and execute contributor code in a job that can read the DeepSeek secret.

The action reads the pull-request diff through GitHub's API itself. It does not require a checkout step. Keep repository secrets in the consuming repository only; never pass them through a workflow input, artifact, log, or reusable-workflow output.

GitHub withholds repository secrets from external fork pull requests. This guide therefore fails those runs closed. A maintainer must not work around that boundary with `pull_request_target`. A future API-only public-fork design needs an independent security review before it is enabled.

## Private repository or same-repository pull request

Create a `DEEPSEEK_API_KEY` Actions secret, then add this workflow:

```yaml
name: DeepSeek CR

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: deepseek-cr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    name: DeepSeek CR
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - name: Reject external repository pull requests without secrets
        if: github.event.pull_request.head.repo.full_name != github.repository
        run: |
          echo "DeepSeek review cannot safely access repository secrets for an external fork pull request."
          exit 1
      - name: Create and reconcile machine review threads
        if: ${{ github.event.pull_request.head.repo.full_name == github.repository }}
        uses: danielcg-net/deepseek-review-gate@9347235fe47109d65860b076eb84835c062dcbcb
        with:
          chat-token: ${{ secrets.DEEPSEEK_API_KEY }}
          github-token: ${{ github.token }}
```

The action requires strict JSON findings. Each actionable finding receives a stable SHA-256 fingerprint and an inline GitHub review thread. On a later clean complete run, it resolves only a stale thread authored by `github-actions[bot]` with this action's marker. It never resolves a human thread or another bot's thread.

## Partitioned reviews

For multiple partial reviewers, set `reconcile-threads: 'false'` on every partial invocation. Collect the complete JSON array of `finding-fingerprints` outputs, then run one final invocation:

```yaml
      - name: Reconcile the complete review result
        uses: danielcg-net/deepseek-review-gate@9347235fe47109d65860b076eb84835c062dcbcb
        with:
          chat-token: ${{ secrets.DEEPSEEK_API_KEY }}
          github-token: ${{ github.token }}
          reconcile-only: 'true'
          active-fingerprints: ${{ needs.collect-findings.outputs.finding_fingerprints }}
```

The final `active-fingerprints` value must be a JSON array assembled from every completed partition. Do not reconcile from one partial result: doing so could resolve a valid finding produced by a different partition.

## Required protection

Protect `main` with:

- the fail-closed aggregate `DeepSeek CR` check;
- required conversation resolution;
- zero required human approvals, if machine-only review is the intended policy;
- auto-merge disabled unless a separate delivery policy explicitly enables it.

Do not require an individual matrix/partition job, because a changed review partition changes job names. Require the stable aggregate only.

## Migration and rollback

1. Add the workflow without making it required; validate a same-repository PR produces and reconciles a machine thread.
2. Require `DeepSeek CR` and conversation resolution after that observed validation.
3. To roll back, remove the required check first, replace the pinned SHA with the last verified release commit, and re-run the PR workflow. Do not use a mutable tag as a rollback target.
4. If provider or GitHub API access fails, the action fails closed. Restore a previously verified SHA rather than disabling review silently.
