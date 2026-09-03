# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through [GitHub Security Advisories](https://github.com/danielcg-net/deepseek-review-gate/security/advisories/new). Do not open a public issue for a vulnerability that could expose a provider token, GitHub token, workflow secret, or authorization bypass.

Include affected commits, reproduction steps, impact, and a suggested mitigation. We aim to acknowledge reports within five business days.

## Security boundaries

- Never add credentials, tokens, customer data, private BizYeet code, production configuration, or signing material.
- Public pull-request workflows run only on GitHub-hosted runners with explicit least-privilege permissions and immutable action SHAs.
- Do not use `pull_request_target`, self-hosted runners, or privileged workflows that check out or execute contributor code.
- The consumer owns its DeepSeek secret. This action never logs it.
- Report dependency and supply-chain concerns through the private channel above.

## Supported versions

Security fixes are made on `main` until the first supported release line is published.
