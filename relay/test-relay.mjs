// Black-box integration against Wrangler/workerd or the deployed relay.
// Synthetic keys and opaque strings only; never loads app receipts or credentials.
import { generateKeyPairSync, createHash, sign, constants, randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
const base = process.argv[2] || 'http://127.0.0.1:8799';
let checks = 0;
function check(ok, name) { assert.ok(ok, name); console.log('PASS', name); checks++; }
const clients = [];
class Device {
  constructor() {
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048 }); this.privateKey = keys.privateKey;
    this.jwk = keys.publicKey.export({ format: 'jwk' }); this.id = createHash('sha256').update(this.jwk.n + '.' + this.jwk.e).digest('hex');
    this.queue = [];
  }
  async post(action, data = {}) { return fetch(`${base}/device/${this.id}/${action}`, { method: 'POST', body: JSON.stringify(data) }); }
  async connect() {
    assert.equal((await this.post('register', { jwk: this.jwk })).status, 200);
    const { nonce } = await (await this.post('challenge')).json();
    this.headers = { 'X-Nonce': nonce, 'X-Signature': sign('sha256', Buffer.from(`GFW8LG relay v1|${this.id}|${nonce}`), { key: this.privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64') };
    this.ws = new WebSocket(`${base.replace(/^http/, 'ws')}/device/${this.id}/connect`, { headers: this.headers });
    this.ws.on('message', data => this.queue.push(JSON.parse(data.toString())));
    await new Promise((resolve, reject) => { this.ws.once('open', resolve); this.ws.once('error', reject); });
    await this.next(m => m.type === 'welcome');
    return this;
  }
  send(m) { this.ws.send(JSON.stringify(m)); }
  async next(predicate) {
    for (let i = 0; i < 100; i++) { const index = this.queue.findIndex(predicate); if (index >= 0) return this.queue.splice(index, 1)[0]; await new Promise(r => setTimeout(r, 50)); }
    throw new Error('Message timeout. Queued types: ' + this.queue.map(m => m.type).join(','));
  }
  async close() { if (!this.ws || this.ws.readyState === 3) return; await new Promise(resolve => { this.ws.once('close', resolve); this.ws.close(); }); }
}
async function rejectedSocket(id, headers = {}) {
  const ws = new WebSocket(`${base.replace(/^http/, 'ws')}/device/${id}/connect`, { headers });
  return new Promise((resolve, reject) => { ws.on('unexpected-response', (_, response) => { response.resume(); ws.terminate(); resolve(response.statusCode !== 101); }); ws.on('error', () => resolve(true)); ws.on('open', () => { ws.close(); reject(new Error('Unauthorized socket accepted')); }); });
}
async function pair(a, b, mode) {
  const lookup = randomBytes(32).toString('hex'); a.send({ type: 'create', lookup, mode }); await a.next(m => m.type === 'created');
  b.send({ type: 'join', lookup, envelope: { opaque: 'fixture' } }); await a.next(m => m.type === 'invitation' && m.pairId === lookup);
  a.send({ type: 'accept', lookup, envelope: { opaque: 'fixture-ack' } }); await a.next(m => m.type === 'acceptedOwner' && m.pairId === lookup); await b.next(m => m.type === 'accepted' && m.pairId === lookup); return lookup;
}
try {
  check((await fetch(base + '/health')).status === 200, 'health endpoint');
  check((await fetch(base + '/unknown')).status === 404, 'no public control or storage endpoints');
  const a = new Device(), b = new Device(), c = new Device(); clients.push(a, b, c);
  check((await fetch(`${base}/device/${'0'.repeat(64)}/register`, { method: 'POST', body: JSON.stringify({ jwk: a.jwk }) })).status === 400, 'key must match device identifier');
  await a.connect(); await b.connect(); await c.connect();
  check(await rejectedSocket(a.id), 'unauthenticated socket rejected');
  check(await rejectedSocket(a.id, a.headers), 'authentication nonce cannot be reused');
  a.send({ type: 'packet', pairId: 'f'.repeat(64), packet: 'opaque' }); check((await a.next(m => m.type === 'error')).type === 'error', 'unpaired traffic rejected');
  const lookup = randomBytes(32).toString('hex'); a.send({ type: 'create', lookup, mode: 'permanent' }); await a.next(m => m.type === 'created');
  b.send({ type: 'join', lookup, envelope: { opaque: 'B' } }); c.send({ type: 'join', lookup, envelope: { opaque: 'C' } });
  const invitation = await a.next(m => m.type === 'invitation' && m.pairId === lookup); const winner = invitation.peerId === b.id ? b : c, loser = winner === b ? c : b;
  check((await loser.next(m => m.type === 'error')).type === 'error', 'one invitation has only one joiner');
  a.send({ type: 'accept', lookup, envelope: { opaque: 'ack' } }); await a.next(m => m.type === 'acceptedOwner'); await winner.next(m => m.type === 'accepted');
  loser.send({ type: 'packet', pairId: lookup, packet: 'attacker' }); check((await loser.next(m => m.type === 'error')).type === 'error', 'third device cannot route through someone else\'s pair');
  const opaque = 'SYNTHETIC-OPAQUE-CIPHERTEXT'; a.send({ type: 'packet', pairId: lookup, packet: opaque }); check((await winner.next(m => m.type === 'packet')).packet === opaque, 'relay preserves opaque encrypted packet');
  a.send({ type: 'accept', lookup, envelope: { opaque: 'replay' } }); check((await a.next(m => m.type === 'error')).type === 'error', 'pair acceptance is one use');
  await a.close(); check((await winner.next(m => m.type === 'online' && m.peerId === a.id && !m.online)).online === false, 'permanent peer goes offline');
  await a.connect(); a.send({ type: 'refresh' }); check((await a.next(m => m.type === 'peers' && m.items.some(p => p.pairId === lookup))).items.length === 1, 'permanent edge survives reconnect');
  a.send({ type: 'remove', pairId: lookup }); await winner.next(m => m.type === 'removed' && m.pairId === lookup);
  winner.send({ type: 'packet', pairId: lookup, packet: opaque }); check((await winner.next(m => m.type === 'error')).type === 'error', 'unpair immediately revokes forwarding');
  const cancelled = randomBytes(32).toString('hex'); a.send({ type: 'create', lookup: cancelled, mode: 'temporary' }); await a.next(m => m.type === 'created');
  a.send({ type: 'join', lookup: cancelled, envelope: { opaque: 'self' } }); check((await a.next(m => m.type === 'error')).type === 'error', 'relay also rejects self pairing');
  winner.send({ type: 'join', lookup: cancelled, envelope: { opaque: 'cancel-fixture' } }); await a.next(m => m.type === 'invitation' && m.pairId === cancelled);
  winner.send({ type: 'cancel', lookup: cancelled }); await a.next(m => m.type === 'cancelled' && m.pairId === cancelled);
  a.send({ type: 'accept', lookup: cancelled, envelope: { opaque: 'late-ack' } }); check((await a.next(m => m.type === 'error')).type === 'error', 'cancelled invitation cannot be accepted later');
  const temporary = await pair(a, winner, 'temporary'); await a.close(); check((await winner.next(m => m.type === 'removed' && m.pairId === temporary)).pairId === temporary, 'temporary edge removed on disconnect');
  console.log(`Completed ${checks} relay checks.`);
} finally { await Promise.all(clients.map(c => c.close())); }
