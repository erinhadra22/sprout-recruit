const assert = require('node:assert/strict');
const { generateKeyPairSync, randomUUID, sign } = require('node:crypto');
const { mkdtemp, readdir, readFile, rm, stat } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { Readable } = require('node:stream');
const { test } = require('node:test');
const { makeServer } = require('./telnyx_webhook.cjs');

test('authenticates Telnyx events and durably deduplicates deliveries', async t => {
  const spool = await mkdtemp(join(tmpdir(), 'sprout-telnyx-test-'));
  t.after(() => rm(spool, { recursive: true, force: true }));
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const publicKeyBase64 = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');

  let server = await makeServer({ publicKeyBase64, spool });
  function post({ headers, body }) {
    const request = Readable.from([Buffer.from(body)]);
    Object.assign(request, { headers, method: 'POST', url: '/webhooks/telnyx' });
    return new Promise(resolve => {
      server.emit('request', request, {
        writeHead(status) {
          return { end: () => resolve(status) };
        },
      });
    });
  }

  function delivery(body, offset = 0) {
    const timestamp = String(Math.floor(Date.now() / 1000) + offset);
    const message = Buffer.concat([Buffer.from(timestamp + '|'), Buffer.from(body)]);
    return {
      method: 'POST',
      body,
      headers: {
        'telnyx-timestamp': timestamp,
        'telnyx-signature-ed25519': sign(null, message, privateKey).toString('base64'),
      },
    };
  }

  const id = randomUUID();
  const data = {
    id,
    event_type: 'message.received',
    occurred_at: '2026-11-09T20:00:00.000Z',
    payload: { id: randomUUID(), text: 'Thursday at two — Central.' },
  };
  const body = JSON.stringify({ data, meta: { attempt: 1 } }, null, 2);

  const modified = delivery(body);
  modified.body = body.replace('Thursday', 'Friday');
  assert.equal(await post(modified), 401);
  assert.equal(await post(delivery(body, -301)), 401);
  assert.equal(await post(delivery(body, 301)), 401);
  assert.equal(await post(delivery('[')), 400);
  assert.equal(await post(delivery(JSON.stringify({ data: { ...data, id: '../bad' } }))), 400);
  assert.equal(await post(delivery(JSON.stringify({ data: { ...data, event_type: 'fax.received' } }))), 204);
  assert.equal(await post(delivery('x'.repeat(256 * 1024 + 1))), 413);
  assert.deepEqual(await readdir(spool), []);

  const posts = await Promise.all(Array.from({ length: 4 }, () => post(delivery(body))));
  assert.deepEqual(posts, [204, 204, 204, 204]);
  const filename = id + '.json';
  assert.deepEqual(await readdir(spool), [filename]);
  assert.equal(await readFile(join(spool, filename), 'utf8'), body);
  assert.equal((await stat(join(spool, filename))).mode & 0o777, 0o600);

  server = await makeServer({ publicKeyBase64, spool });
  const retry = JSON.stringify({ data, meta: { attempt: 2 } });
  assert.equal(await post(delivery(retry)), 204);
  assert.deepEqual(await readdir(spool), [filename]);
  assert.equal(await readFile(join(spool, filename), 'utf8'), body);
});
