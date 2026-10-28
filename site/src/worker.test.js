import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.js';

const env = { ASSETS: { async fetch(request) {
  return new Response(request.method === 'HEAD' ? null : new URL(request.url).pathname,
    { headers: { 'Content-Type': 'text/html' } });
} } };
const request = (path, method = 'GET') => new Request(`https://muhammadsqlan.com${path}`, { method });

test('base paths and query strings serve the landing page without path redirects', async () => {
  for (const path of ['/redz', '/redz/', '/redz?source=test']) {
    const result = await worker.fetch(request(path), env);
    assert.equal(result.status, 200);
    assert.equal(await result.text(), '/index.html');
    assert.match(result.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  }
});
test('downloads have a fixed versioned public destination', async () => {
  const result = await worker.fetch(request('/redz/download?url=https://example.com'), env);
  assert.equal(result.status, 302);
  assert.equal(result.headers.get('Location'), 'https://github.com/muhammadsqlan/redz/releases/download/v0.3.2/ReDZ-0.3.2-arm64.dmg');
});
test('HEAD works and unsupported methods and unknown files are rejected', async () => {
  const head = await worker.fetch(request('/redz', 'HEAD'), env);
  assert.equal(await head.text(), '');
  assert.equal((await worker.fetch(request('/redz/download', 'POST'), env)).status, 405);
  assert.equal((await worker.fetch(request('/redz/.env'), env)).status, 404);
  assert.equal((await worker.fetch(request('/redz/unknown.html'), env)).status, 404);
});
test('paths outside ReDZ preserve the existing domain origin', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (incoming) => new Response(`origin:${new URL(incoming.url).pathname}`);
  try {
    for (const path of ['/redzone', '/redz-other', '/']) {
      assert.equal(await (await worker.fetch(request(path), env)).text(), `origin:${path}`);
    }
  } finally { globalThis.fetch = original; }
});
