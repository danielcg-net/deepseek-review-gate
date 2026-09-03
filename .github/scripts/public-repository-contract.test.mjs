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
});

test('public workflows are least privilege and avoid privileged fork execution', async () => {
  const workflowNames = await readdir(new URL('.github/workflows/', root));
  const workflows = await Promise.all(workflowNames.map((name) => read(`.github/workflows/${name}`)));
  const workflowText = workflows.join('\n');
  assert.doesNotMatch(workflowText, /pull_request_target/);
  assert.doesNotMatch(workflowText, /self-hosted/);
  assert.match(workflowText, /persist-credentials: false/);
  assert.match(workflowText, /@[0-9a-f]{40}/);
  assert.match(workflowText, /name: YouTrack delivery policy/);
});

test('consumer documentation prohibits privileged fork workflows and mutable action references', async () => {
  const readme = await read('README.md');
  assert.match(readme, /Do \*\*not\*\* use `pull_request_target`/);
  assert.match(readme, /@<RELEASE_COMMIT_SHA>/);
  assert.doesNotMatch(readme, /uses: hustcer\/deepseek-review@/);
});
