const { createPublicKey, randomUUID, verify } = require('node:crypto');
const { link, lstat, mkdir, open, unlink } = require('node:fs/promises');
const { createServer } = require('node:http');
const { isAbsolute, join } = require('node:path');

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const MAX_BYTES = 256 * 1024;
const MAX_SIGNATURE_AGE = 300;
const EVENT_TYPES = new Set([
  'call.initiated',
  'call.answered',
  'call.bridged',
  'call.hangup',
  'call.recording.saved',
  'call.recording.error',
  'call.recording.transcription.saved',
  'message.received',
  'message.sent',
  'message.finalized',
]);

class RequestError extends Error {
  constructor(statusCode) {
    super('Webhook rejected');
    this.statusCode = statusCode;
  }
}

function decodeBase64(value, size) {
  if (typeof value !== 'string') return null;
  const bytes = Buffer.from(value, 'base64');
  return bytes.length === size && bytes.toString('base64') === value ? bytes : null;
}

function makePublicKey(value) {
  const bytes = decodeBase64(value, 32);
  if (!bytes) throw new Error('Set TELNYX_PUBLIC_KEY to the base64 public key from Telnyx.');
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, bytes]),
    type: 'spki',
    format: 'der',
  });
}

function validateEvent(headers, rawBody, publicKey, now = Date.now()) {
  const timestamp = headers['telnyx-timestamp'];
  const signature = decodeBase64(headers['telnyx-signature-ed25519'], 64);
  if (!signature || typeof timestamp !== 'string' || !/^\d{10}$/.test(timestamp)) {
    throw new RequestError(401);
  }
  const age = Math.floor(now / 1000) - Number(timestamp);
  if (Math.abs(age) > MAX_SIGNATURE_AGE) throw new RequestError(401);

  // Telnyx signs the timestamp, a pipe, and the original request bytes.
  const signed = Buffer.concat([Buffer.from(timestamp + '|'), rawBody]);
  if (!verify(null, signed, publicKey, signature)) throw new RequestError(401);

  let event;
  try {
    const envelope = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(rawBody));
    event = envelope?.data;
  } catch {
    throw new RequestError(400);
  }
  if (typeof event?.id !== 'string' ||
      !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(event.id) ||
      typeof event.event_type !== 'string' ||
      typeof event.occurred_at !== 'string' ||
      !Number.isFinite(Date.parse(event.occurred_at)) ||
      !event.payload || typeof event.payload !== 'object' || Array.isArray(event.payload)) {
    throw new RequestError(400);
  }
  return event;
}

async function spoolEvent(spool, eventId, rawBody) {
  const temporary = join(spool, '.' + randomUUID() + '.tmp');
  const destination = join(spool, eventId.toLowerCase() + '.json');
  const output = await open(temporary, 'wx', 0o600);
  try {
    try {
      await output.writeFile(rawBody);
      await output.sync();
    } finally {
      await output.close();
    }
    try {
      // Publish a fully written file without replacing a concurrent or previous delivery.
      await link(temporary, destination);
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    const directory = await open(spool, 'r');
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  } finally {
    await unlink(temporary);
  }
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > MAX_BYTES) throw new RequestError(413);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

async function makeServer({ publicKeyBase64, spool }) {
  const publicKey = makePublicKey(publicKeyBase64);
  if (!spool || !isAbsolute(spool)) throw new Error('Set SPROUT_TELNYX_SPOOL to an absolute directory.');
  try {
    await mkdir(spool, { mode: 0o700 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  const directory = await lstat(spool);
  if (!directory.isDirectory() || (directory.mode & 0o077) !== 0 || directory.uid !== process.getuid()) {
    throw new Error('Use a private Telnyx spool directory owned by this user.');
  }

  return createServer({ requestTimeout: 5000, headersTimeout: 3000 }, async (request, response) => {
    if (request.method !== 'POST' || request.url !== '/webhooks/telnyx') {
      response.writeHead(404, { Connection: 'close' }).end();
      return;
    }
    try {
      const rawBody = await readBody(request);
      const event = validateEvent(request.headers, rawBody, publicKey);
      if (EVENT_TYPES.has(event.event_type)) await spoolEvent(spool, event.id, rawBody);
      response.writeHead(204).end();
    } catch (error) {
      // Avoid printing request bodies, provider identifiers, or signed media URLs.
      if (!(error instanceof RequestError)) console.error('Telnyx webhook could not be saved.');
      response.writeHead(error instanceof RequestError ? error.statusCode : 503, { Connection: 'close' }).end();
    }
  });
}

async function main() {
  const port = Number(process.env.SPROUT_TELNYX_PORT ?? 8788);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Use a valid SPROUT_TELNYX_PORT.');
  const server = await makeServer({
    publicKeyBase64: process.env.TELNYX_PUBLIC_KEY,
    spool: process.env.SPROUT_TELNYX_SPOOL,
  });
  server.on('error', () => {
    console.error('Telnyx webhook receiver could not bind to its local port.');
    process.exitCode = 1;
  });
  server.listen(port, '127.0.0.1', () => console.log('Telnyx webhook receiver listening on loopback port ' + port));
}

if (require.main === module) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

module.exports = { makeServer };
