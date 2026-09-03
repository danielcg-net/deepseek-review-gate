import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);

const read = (path) => readFile(new URL(path, root), 'utf8');

test('public repository governance and security documents are present', async () => {
  const required = ['LICENSE', 'NOTICE', 'SECURITY.md', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'GOVERNANCE.md', 'SUPPORT.md'];
  await Promise.all(required.map(async (path) => {
    const content = await read(path);
    assert.ok(content.trim(), `${path} must not be empty`);
  }));
});

test('action uses an immutable setup action SHA', async () => {
  const action = await read('action.yaml');
  assert.match(action, /uses: hustcer\/setup-nu@[0-9a-f]{40} # v3\.27/);
  assert.doesNotMatch(action, /chat-token.*print/i);
  assert.match(action, /finding-fingerprints:/);
  assert.match(action, /reconcile-only:/);
  assert.match(action, /\(\n            deepseek-review \$env\.CHAT_TOKEN_INPUT/);
  assert.match(action, /--comment \$env\.COMMENT_BODY_INPUT\n          \)/);
  const reviewThreads = await read('nu/review-threads.nu');
  assert.match(reviewThreads, /export def parse-graphql-response/);
  assert.match(reviewThreads, /let body = \$response\.body\? \| default \$response/);
  assert.match(reviewThreads, /export def serialize-active-fingerprints/);
  assert.match(reviewThreads, /\$fingerprints \| to json --raw/);
  assert.match(reviewThreads, /export def machine-reviewer-matches/);
  assert.match(reviewThreads, /github-actions\[bot\]/);
  assert.match(action, /reconcile-machine-review-threads[\s\S]*\['finding-fingerprints=' \(serialize-active-fingerprints \$active\)\] \| str join '' \| save --append \$env\.GITHUB_OUTPUT[\s\S]*exit 0/);
  assert.doesNotMatch(action, /\$'finding-fingerprints=.*\$active/);
});

test('public workflows are least privilege and avoid privileged fork execution', async () => {
  const workflowNames = await readdir(new URL('.github/workflows/', root));
  const workflows = await Promise.all(workflowNames.map((name) => read(`.github/workflows/${name}`)));
  const workflowText = workflows.join('\n');
  assert.doesNotMatch(workflowText, /pull_request_target/);
  assert.doesNotMatch(workflowText, /self-hosted/);
  assert.match(workflowText, /persist-credentials: false/);
  assert.match(workflowText, /@[0-9a-f]{40}/);
  for (const workflowName of ['ci.yml', 'release-verify.yml']) {
    const workflow = await read(`.github/workflows/${workflowName}`);
    assert.match(workflow, /ref: c46af12bc6e3819b95d69f54f35526ca3e5810d6/, `${workflowName} must pin NuTest by commit SHA`);
    assert.match(workflow, /run-tests --path \$\{\{ github\.workspace \}\}\/tests/, `${workflowName} must run only this repository's tests`);
  }
  assert.match(workflowText, /name: YouTrack delivery policy/);
});

test('consumer documentation prohibits privileged fork workflows and mutable action references', async () => {
  const readme = await read('README.md');
  const projectTests = await read('tests/test-project.nu');
  const integration = await read('docs/consumer-integration.md');
  const action = await read('action.yaml');
  assert.match(readme, /Do \*\*not\*\* use `pull_request_target`/);
  assert.match(readme, /@2ebad6fd0146171a495fe45e30a813d3a08b87c4/);
  assert.match(projectTests, /@2ebad6fd0146171a495fe45e30a813d3a08b87c4/);
  assert.doesNotMatch(readme, /uses: hustcer\/deepseek-review@/);
  assert.match(integration, /pull_request_target/);
  assert.match(integration, /@2ebad6fd0146171a495fe45e30a813d3a08b87c4/);
  assert.match(integration, /reconcile-only: 'true'/);
  assert.match(integration, /Reject external repository pull requests without secrets/);
  assert.match(integration, /github\.event\.pull_request\.head\.repo\.full_name != github\.repository/);
  assert.match(integration, /contents: write/);
  assert.match(integration, /pull-requests: write/);
  assert.match(integration, /dedicated no-checkout review job/);
  assert.match(readme, /contents: write/);
  assert.match(action, /Requires contents: write and pull-requests: write/);
});
