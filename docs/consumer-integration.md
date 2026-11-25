# Consumer integration

This guide applies to release `v1.21.0-bizyeet.7`, commit `2ebad6fd0146171a495fe45e30a813d3a08b87c4`. Pin the commit SHA in every consuming workflow; release tags are documentation, not a supply-chain pin.

## Security boundary

Use only the ordinary `pull_request` event. Do not use `pull_request_target`, self-hosted runners, or checkout and execute contributor code in a job that can read the DeepSeek secret.

The action reads the pull-request diff through GitHub's API itself. It does not require a checkout step. Keep repository secrets in the consuming repository only; never pass them through a workflow input, artifact, log, or reusable-workflow output. GitHub currently requires `contents: write` as well as `pull-requests: write` to resolve a review thread through GraphQL; grant that scope only to this dedicated no-checkout review job.

GitHub withholds repository secrets from external fork pull requests. This guide therefore fails those runs closed. A maintainer must not work around that boundary with `pull_request_target`. A future API-only public-fork design needs an independent security review before it is enabled.

## Private repository or same-repository pull request

Create a `DEEPSEEK_API_KEY` Actions secret, then add this workflow:

```yaml
name: DeepSeek CR

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions:
  # Required by GitHub's resolveReviewThread GraphQL mutation.
  contents: write
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
        uses: danielcg-net/deepseek-review-gate@2ebad6fd0146171a495fe45e30a813d3a08b87c4 # v1.21.0-bizyeet.7
        with:
          chat-token: ${{ secrets.DEEPSEEK_API_KEY }}
          github-token: ${{ github.token }}
```

The action requires strict JSON findings. Each actionable finding receives a stable SHA-256 fingerprint and an inline GitHub review thread. On a later clean complete run, it resolves only a stale thread authored by `github-actions[bot]` with this action's marker. It never resolves a human thread or another bot's thread.

## Immutable review evidence (opt-in)

After pinning a commit containing this interface, pass both `expected-head-sha`
and `expected-base-sha` as full lowercase commit SHAs from the triggering PR
event, and use `max-length: 0`. Existing callers that omit both inputs retain
their current behavior. Immutable mode supports open, unlocked, same-repository
PRs only and requires Git on the runner. It reads immutable objects into a fresh
temporary **bare** repository, computes the merge-base-to-head diff without
external diff/textconv helpers or rename detection, and removes that object store.
It never checks out or executes contributor files. Immutable diff generation
ignores title/body/commit-message skip directives: opt-in means perform the
selected review. Missing refs, unavailable objects, changed live identity,
provider failures, and size-limit settings fail the action without evidence.
`reconcile-only` is incompatible with these inputs.

The live PR repository, number, head and base are checked before fetching,
after fetching, before every thread creation/resolution and after the final
write. A detected change stops subsequent mutations and prevents evidence;
GitHub provides no atomic head/base precondition for resolving threads, so an
unobservable race during an individual API write cannot be eliminated. New
comments are attached to the expected immutable head, never a replacement head.

The optional `review-evidence` output is a single JSON line:

```json
{"repository":"owner/repo","pr":42,"head":"<40 hex>","base":"<40 hex>","mergeBase":"<40 hex>","version":1,"sourceDiffSha256":"<64 hex>","diffSha256":"<64 hex>","includePatterns":"","excludePatterns":"pnpm-lock.yaml,package-lock.json,*.lock","outcome":"reviewed","complete":true}
```

`sourceDiffSha256` hashes the complete immutable Git diff. `diffSha256` hashes
the exact selected diff passed to the provider. The include/exclude policy
remains unchanged; `complete` means the **entire selected projection** was
processed without a length cutoff. An empty projection emits
`outcome: "empty-selection"` after guarded reconciliation without a provider
request; a nonempty valid provider response emits `outcome: "reviewed"`,
including a clean response with no findings. Evidence contains no source text
or credentials. It is unset for legacy callers, reconcile-only runs, rejected
invocations and failures. Treat outputs from a failed step as unusable.

This output is data, not a merge authorization or cryptographic attestation.
Consumers must independently authenticate the producing workflow source,
successful exact run/attempt and selected review policy, compare immutable
candidate changes, and preserve required checks and unresolved-thread gates.
Do not infer review coverage from a PR label, a prior check name, or a hash
without its authenticated production context. This action uploads no artifacts
and grants no queue exception.

## Partitioned reviews

Thread reconciliation retrieves every review-thread page before creating or
resolving threads. A failed request, malformed page, duplicate thread, or
non-advancing cursor fails the invocation without reconciling a partial list.
Ownership is determined only by the root comment's author and fingerprint;
replies cannot confer ownership. This also applies to reconcile-only runs.

For multiple partial reviewers, set `reconcile-threads: 'false'` on every partial invocation. Collect the complete JSON array of `finding-fingerprints` outputs, then run one final invocation:

```yaml
      - name: Reconcile the complete review result
        uses: danielcg-net/deepseek-review-gate@2ebad6fd0146171a495fe45e30a813d3a08b87c4 # v1.21.0-bizyeet.7
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
