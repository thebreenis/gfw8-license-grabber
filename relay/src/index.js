import { DurableObject } from 'cloudflare:workers';
const enc = new TextEncoder();
const hex = bytes => [...new Uint8Array(bytes)].map(x => x.toString(16).padStart(2, '0')).join('');
const hash = async value => hex(await crypto.subtle.digest('SHA-256', enc.encode(value)));
const validId = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
function fail(message) { throw new Error(message); }
function decode(s) { return Uint8Array.from(atob(s), c => c.charCodeAt(0)); }
function json(data, status = 200) { return Response.json(data, { status, headers: { 'Cache-Control': 'no-store' } }); }
async function body(request) {
  if (Number(request.headers.get('content-length') || 0) > 16384) fail('Request too large.');
  const reader = request.body?.getReader(); let length = 0, chunks = [];
  if (reader) while (true) { const r = await reader.read(); if (r.done) break; length += r.value.length; if (length > 16384) { await reader.cancel(); fail('Request too large.'); } chunks.push(r.value); }
  const bytes = new Uint8Array(length); let at = 0; for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
  return JSON.parse(new TextDecoder().decode(bytes));
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ service: 'GFW8LG encrypted receipt relay', protocol: 1 });
    const match = /^\/device\/([a-f0-9]{64})\/(register|challenge|connect)$/.exec(url.pathname);
    if (!match) return json({ error: 'Not found.' }, 404);
    // Every device is a separate coordination/storage object; no global hub.
    return env.DEVICES.getByName(match[1]).fetch(request);
  }
};
export class Device extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }
  get(key) { const r = this.ctx.storage.sql.exec('SELECT v FROM state WHERE k=?', key).toArray(); return r.length ? JSON.parse(r[0].v) : null; }
  put(key, value) { this.ctx.storage.sql.exec('INSERT OR REPLACE INTO state(k,v) VALUES (?,?)', key, JSON.stringify(value)); }
  del(key) { this.ctx.storage.sql.exec('DELETE FROM state WHERE k=?', key); }
  peers() { return this.ctx.storage.sql.exec("SELECT v FROM state WHERE k LIKE 'peer:%'").toArray().map(r => JSON.parse(r.v)); }
  sockets() { return this.ctx.getWebSockets().filter(s => s.readyState === 1); }
  async fetch(request) {
    try {
      const match = /\/([a-f0-9]{64})\/(register|challenge|connect)$/.exec(new URL(request.url).pathname);
      const [, id, action] = match;
      if (action === 'register' && request.method === 'POST') {
        const data = await body(request);
        if (!data.jwk || data.jwk.kty !== 'RSA' || data.jwk.e !== 'AQAB' || data.jwk.d || typeof data.jwk.n !== 'string' || data.jwk.n.length < 342 || data.jwk.n.length > 684 || await hash(data.jwk.n + '.' + data.jwk.e) !== id) fail('Invalid device key.');
        const existing = this.get('identity');
        if (existing && existing.jwk.n !== data.jwk.n) fail('Device key changed.');
        if (!existing) this.put('identity', { id, jwk: { kty: 'RSA', n: data.jwk.n, e: data.jwk.e } });
        return json({ registered: true });
      }
      const identity = this.get('identity'); if (!identity || identity.id !== id) fail('Unknown device.');
      if (action === 'challenge' && request.method === 'POST') {
        // Fully consume the bounded forwarded body before returning a response.
        await body(request);
        const now = Date.now(), rate = this.get('challengeRate') || { time: now, count: 0 };
        if (now - rate.time > 60000) { rate.time = now; rate.count = 0; }
        if (++rate.count > 30) return json({ error: 'Slow down.' }, 429);
        this.put('challengeRate', rate);
        const nonce = crypto.randomUUID(); this.put('nonce', { value: nonce, expires: now + 60000 });
        return json({ nonce });
      }
      if (action !== 'connect' || request.headers.get('upgrade')?.toLowerCase() !== 'websocket') fail('WebSocket required.');
      const nonce = this.get('nonce'), signature = request.headers.get('X-Signature');
      if (!nonce || nonce.expires < Date.now() || request.headers.get('X-Nonce') !== nonce.value || !signature || signature.length > 1024) fail('Authentication expired.');
      const key = await crypto.subtle.importKey('jwk', identity.jwk, { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['verify']);
      if (!await crypto.subtle.verify({ name: 'RSA-PSS', saltLength: 32 }, key, decode(signature), enc.encode('GFW8LG relay v1|' + id + '|' + nonce.value))) fail('Authentication failed.');
      // Synchronous consumption after verification prevents nonce reuse.
      if (this.get('nonce')?.value !== nonce.value) fail('Authentication already used.'); this.del('nonce');
      for (const old of this.sockets()) old.close(1000, 'Reconnected');
      const pair = new WebSocketPair(), client = pair[0], server = pair[1];
      this.ctx.acceptWebSocket(server); server.serializeAttachment({ id, time: Date.now(), count: 0 });
      server.send(JSON.stringify({ type: 'welcome', id }));
      this.ctx.waitUntil(this.refresh());
      return new Response(null, { status: 101, webSocket: client });
    } catch { return json({ error: 'Invalid or unauthorized request.' }, 400); }
  }
  async refresh() {
    const peers = this.peers().filter(p => p.mode === 'permanent' || p.expires > Date.now());
    const items = await Promise.all(peers.map(async p => ({ ...p, online: await this.env.DEVICES.getByName(p.peerId).online() })));
    this.send({ type: 'peers', items });
    const id = this.get('identity')?.id;
    if (id) await Promise.all(peers.map(p => this.env.DEVICES.getByName(p.peerId).notifyOnline(id, true)));
  }
  online() { return this.sockets().length > 0; }
  send(message) { const text = JSON.stringify(message); for (const ws of this.sockets()) { try { ws.send(text); } catch {} } }
  notifyOnline(id, online) { if (this.peers().some(p => p.peerId === id)) this.send({ type: 'online', peerId: id, online }); }
  control(message) { this.send(message); }
  async addPair(record) {
    if (!validId(record.peerId) || !validId(record.pairId) || this.peers().length >= 32) fail('Pair limit.');
    this.put('peer:' + record.pairId, record);
    const soonest = this.peers().filter(p => p.mode === 'temporary').map(p => p.expires).sort((a, b) => a - b)[0];
    if (soonest) await this.ctx.storage.setAlarm(soonest);
  }
  async alarm() {
    for (const p of this.peers().filter(p => p.mode === 'temporary' && p.expires <= Date.now())) {
      this.removePair(p.pairId); await this.env.DEVICES.getByName(p.peerId).removePair(p.pairId);
    }
    const next = this.peers().filter(p => p.mode === 'temporary').map(p => p.expires).sort((a, b) => a - b)[0];
    if (next) await this.ctx.storage.setAlarm(next);
  }
  removePair(pairId) { const peer = this.get('peer:' + pairId); this.del('peer:' + pairId); this.send({ type: 'removed', pairId }); return peer; }
  relay(from, pairId, packet) {
    const peer = this.get('peer:' + pairId);
    if (!peer || peer.peerId !== from || (peer.mode === 'temporary' && peer.expires < Date.now())) fail('Pair unavailable.');
    if (!this.online()) fail('Peer offline.');
    this.send({ type: 'packet', pairId, peerId: from, packet });
  }
  async webSocketMessage(ws, raw) {
    let requestId;
    try {
      if (typeof raw !== 'string' || enc.encode(raw).length > 65536) fail('Message too large.');
      const a = ws.deserializeAttachment();
      if (Date.now() - a.time > 60000) { a.time = Date.now(); a.count = 0; }
      if (++a.count > 180) fail('Rate limit.'); ws.serializeAttachment(a);
      const m = JSON.parse(raw); requestId = String(m.requestId || '').slice(0, 80);
      if (m.type === 'create') {
        if (!validId(m.lookup) || !['temporary', 'permanent'].includes(m.mode)) fail('Invalid invitation.');
        await this.env.INVITATIONS.getByName(m.lookup).create(a.id, m.mode, m.lookup);
        this.send({ type: 'created', requestId });
      } else if (m.type === 'join') {
        if (!validId(m.lookup) || JSON.stringify(m.envelope).length > 8192) fail('Invalid invitation.');
        await this.env.INVITATIONS.getByName(m.lookup).join(a.id, m.envelope);
        this.send({ type: 'joining', requestId });
      } else if (m.type === 'accept') {
        if (!validId(m.lookup) || JSON.stringify(m.envelope).length > 8192) fail('Invalid acceptance.');
        await this.env.INVITATIONS.getByName(m.lookup).accept(a.id, m.envelope);
      } else if (m.type === 'cancel') {
        if (!validId(m.lookup)) fail('Invalid invitation.');
        await this.env.INVITATIONS.getByName(m.lookup).cancel(a.id);
        this.send({ type: 'cancelled', pairId: m.lookup, requestId });
      } else if (m.type === 'packet') {
        const p = this.get('peer:' + m.pairId);
        if (!p || (p.mode === 'temporary' && p.expires < Date.now()) || typeof m.packet !== 'string' || m.packet.length > 60000) fail('Pair unavailable.');
        await this.env.DEVICES.getByName(p.peerId).relay(a.id, p.pairId, m.packet);
      } else if (m.type === 'remove') {
        const p = this.removePair(m.pairId);
        if (p) await this.env.DEVICES.getByName(p.peerId).removePair(m.pairId);
      } else if (m.type === 'refresh') await this.refresh();
      else fail('Unknown message.');
    } catch { try { ws.send(JSON.stringify({ type: 'error', requestId, message: 'Request unavailable, expired, offline, or rate-limited.' })); } catch {} }
  }
  async webSocketClose(ws) { await this.disconnected(ws); }
  async webSocketError(ws) { await this.disconnected(ws); }
  async disconnected(ws) {
    try { ws.close(); } catch {}
    if (this.online()) return;
    const id = this.get('identity')?.id;
    for (const p of this.peers()) {
      if (p.mode === 'temporary') { this.removePair(p.pairId); await this.env.DEVICES.getByName(p.peerId).removePair(p.pairId); }
      if (id) await this.env.DEVICES.getByName(p.peerId).notifyOnline(id, false);
    }
  }
}
export class Invitation extends DurableObject {
  constructor(ctx, env) { super(ctx, env); this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS invitation (id INTEGER PRIMARY KEY, value TEXT NOT NULL)'); }
  getRecord() { const rows = this.ctx.storage.sql.exec('SELECT value FROM invitation WHERE id=1').toArray(); return rows.length ? JSON.parse(rows[0].value) : null; }
  saveRecord(record) { this.ctx.storage.sql.exec('INSERT OR REPLACE INTO invitation(id,value) VALUES(1,?)', JSON.stringify(record)); }
  async create(owner, mode, lookup) {
    if (this.getRecord()) fail('Invitation already exists.');
    const record = { owner, mode, lookup, expires: Date.now() + 10 * 60000 };
    this.saveRecord(record); await this.ctx.storage.setAlarm(record.expires);
  }
  async join(joiner, envelope) {
    const r = this.getRecord();
    if (!r || r.cancelled || r.expires < Date.now() || r.owner === joiner || r.joiner) fail('Invitation unavailable.');
    // Persist first, then notify. Only possession of the invitation encryption
    // secret lets the owner validate this join; the relay never receives it.
    r.joiner = joiner; this.saveRecord(r);
    if (!await this.env.DEVICES.getByName(r.owner).online()) fail('Owner offline.');
    await this.env.DEVICES.getByName(r.owner).control({ type: 'invitation', pairId: r.lookup, peerId: joiner, mode: r.mode, envelope });
  }
  async accept(owner, envelope) {
    const r = this.getRecord();
    if (!r || r.used || r.cancelled || r.owner !== owner || !r.joiner || r.expires < Date.now()) fail('Invitation unavailable.');
    r.used = true; this.saveRecord(r);
    const expires = r.mode === 'temporary' ? Date.now() + 2 * 3600000 : 0;
    await Promise.all([
      this.env.DEVICES.getByName(owner).addPair({ pairId: r.lookup, peerId: r.joiner, mode: r.mode, expires }),
      this.env.DEVICES.getByName(r.joiner).addPair({ pairId: r.lookup, peerId: owner, mode: r.mode, expires })
    ]);
    if (this.getRecord()?.cancelled) {
      await this.removeEdges(r); return;
    }
    await this.env.DEVICES.getByName(r.joiner).control({ type: 'accepted', pairId: r.lookup, peerId: owner, mode: r.mode, envelope });
    await this.env.DEVICES.getByName(owner).control({ type: 'acceptedOwner', pairId: r.lookup, peerId: r.joiner, mode: r.mode });
    // Keep the one-use tombstone until the invitation expires.
  }
  async removeEdges(r) {
    if (r.joiner) await Promise.all([
      this.env.DEVICES.getByName(r.owner).removePair(r.lookup),
      this.env.DEVICES.getByName(r.joiner).removePair(r.lookup)
    ]);
  }
  async cancel(device) {
    const r = this.getRecord();
    if (!r || (r.owner !== device && r.joiner !== device)) return;
    r.cancelled = true; this.saveRecord(r);
    if (r.used) await this.removeEdges(r);
    await this.env.DEVICES.getByName(r.owner).control({ type: 'cancelled', pairId: r.lookup });
    if (r.joiner) await this.env.DEVICES.getByName(r.joiner).control({ type: 'cancelled', pairId: r.lookup });
  }
  async alarm() { await this.ctx.storage.deleteAll(); }
}
