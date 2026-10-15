// Local synthetic provider; persist only safe request booleans, never request data.
import { createServer } from 'node:http';
import { writeFileSync, renameSync } from 'node:fs';
const [mode, observation] = process.argv.slice(2);
const secret = 'PRIVATE_PROVIDER_BODY_SENTINEL';
let count = 0;
const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const p = JSON.parse(Buffer.concat(chunks));
  const observed = { count: ++count, auth: req.headers.authorization === 'Bearer sk-mock-token', model: p.model === 'deepseek-v4-pro', stream: p.stream === false, temperature: p.temperature === 0, thinking: p.thinking?.type === 'disabled', responseBytesWritten: 0, advertisedResponseBytes: null, responseClosed: false };
  const persist = () => {
    // Readers must never observe the truncation window of a close-time update.
    const temporary = `${observation}.tmp`;
    writeFileSync(temporary, JSON.stringify(observed));
    renameSync(temporary, observation);
  };
  persist();
  res.once('close', () => { observed.responseClosed = true; persist(); });
  if (mode === 'hang') return;
  let status = 200;
  let body = { choices: [{ message: { content: '{"findings":[]}', reasoning_content: 'SYNTHETIC_REASONING' } }], usage: { total_tokens: 12 } };
  const headers = { 'content-type': 'application/json', 'x-request-id': 'safe_Ref-123', 'set-cookie': secret };
  if (/^http\d+$/.test(mode)) { status = Number(mode.slice(4)); body = { error: { message: secret, type: secret, code: secret } }; }
  if (mode === 'http503-completion') status = 503;
  if (mode === 'provider-error') body = { error: { message: secret } };
  if (mode === 'empty-choices') body = { choices: [] };
  if (mode === 'null-content') body = { choices: [{ message: { content: null } }] };
  if (mode === 'empty-content') body = { choices: [{ message: { content: ' ' } }] };
  if (mode === 'malformed-choices') body = { choices: secret };
  if (mode === 'malformed-content') body = { choices: [{ message: { content: { private: secret } } }] };
  if (mode === 'malformed-reasoning') body.choices[0].message.reasoning_content = { private: secret };
  if (mode === 'fallback') body = { message: { content: '{"findings":[]}' } };
  if (mode === 'malformed-review') body = { choices: [{ message: { content: secret } }] };
  if (mode === 'unsafe-ref') headers['x-request-id'] = secret + ' unsafe value';
  if (mode === 'duplicate-ref') headers['x-request-id'] = ['first-ref', 'second-ref'];
  if (mode === 'dual-ref') headers['request-id'] = 'second-ref';
  if (mode === 'oversize-ref') headers['x-request-id'] = 'a'.repeat(129);
  if (mode === 'no-ref') delete headers['x-request-id'];
  if (mode === 'text') { body = secret; headers['content-type'] = 'text/plain'; }
  if (mode === 'malformed-json') body = `{"private":"${secret}"`;
  let bytes = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  if (mode === 'zero200' || mode === 'zero204') { status = mode === 'zero204' ? 204 : 200; bytes = Buffer.alloc(0); }
  if (mode === 'invalid-utf8') bytes = Buffer.from([0xff, 0xfe, 0x7b]);
  if (mode === 'keepalive') bytes = Buffer.concat([Buffer.from('\n \n'), bytes]);
  if (mode === 'truncated') { res.writeHead(200, { ...headers, 'content-length': bytes.length + 99 }); res.end(bytes); return; }
  if (mode === 'midbody-hang') { res.writeHead(200, { ...headers, 'content-length': 10000 }); res.write('{'); return; }
  if (mode === 'oversize' || mode === 'slow-oversize') {
    observed.advertisedResponseBytes = 12 * 1024 * 1024;
    res.writeHead(200, { ...headers, 'content-length': observed.advertisedResponseBytes });
    let sent = 0;
    const timer = setInterval(() => {
      if (res.destroyed || sent >= 12 * 1024 * 1024) { clearInterval(timer); res.end(); return; }
      res.write(Buffer.alloc(65536, 32)); sent += 65536; observed.responseBytesWritten = sent;
    }, mode === 'slow-oversize' ? 2 : 0);
    res.once('close', () => clearInterval(timer)); return;
  }
  res.writeHead(status, { ...headers, 'content-length': bytes.length }); res.end(bytes);
});
server.listen(0, '127.0.0.1', () => console.log(`PORT=${server.address().port}`));
setTimeout(() => { server.closeAllConnections(); server.close(); }, 15000).unref();
