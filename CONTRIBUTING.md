# Contributing

Thanks for improving DeepSeek Review Gate.

## Before opening a pull request

1. Obtain a BizYeet YouTrack issue from a maintainer.
2. Use `bizyeet-123/short-title`; PR titles start `BIZYEET-123: ` and non-merge commits start `bizyeet-123: `.
3. Run `node --test .github/scripts/public-repository-contract.test.mjs` and `just test` when Nushell tooling is available.
4. Do not include credentials, customer data, production configuration, or source from private repositories.

GitHub Issues are disabled; YouTrack is the delivery system of record. The authenticated `dependabot[bot]` account is the only exception to the delivery-identifier rule, and its changes remain subject to all checks.

## Pull-request expectations

- Keep the change small and explain its user or security impact.
- Add or update tests for changed behavior.
- Do not broaden workflow permissions, expose secrets to forks, or run contributor code in a privileged context.
- Preserve the upstream MIT license and attribution for derived code.
