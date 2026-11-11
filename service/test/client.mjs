// Minimal PartyPort client used by the tests. It behaves like the real app:
// an Ed25519 device key, signed HTTP requests and a challenge-signed WebSocket.
import { generateKeyPairSync, sign, createHash, verify, createPublicKey } from "node:crypto";

export const b64url = (buf) => Buffer.from(buf).toString("base64url");

export class Member {
  constructor(base, name) {
    this.base = base.replace(/\/$/, "");
    this.name = name;
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    this.privateKey = privateKey;
    this.key = publicKey.export({ format: "jwk" }).x; // raw 32-byte key, base64url
  }

  sign(message) {
    return b64url(sign(null, Buffer.from(message), this.privateKey));
  }

  async request(method, path, body, { tamper } = {}) {
    const raw = body === undefined ? "" : JSON.stringify(body);
    const time = String(Date.now());
    const hash = createHash("sha256").update(raw).digest("hex");
    let sig = this.sign(`${method}\n${path}\n${time}\n${hash}`);
    if (tamper) sig = this.sign("something else");
    const res = await fetch(this.base + path, {
      method,
      headers: { "content-type": "application/json", "x-pp-key": this.key, "x-pp-time": time, "x-pp-sig": sig },
      body: raw || undefined,
    });
    return { status: res.status, data: await res.json() };
  }

  createParty(name) {
    return this.request("POST", "/parties", { name, displayName: this.name });
  }

  join(code, password) {
    return this.request("POST", `/invites/${code}/join`, { displayName: this.name, password });
  }

  connect(partyId) {
    return Conn.open(this, partyId);
  }
}

export class Conn {
  static open(member, partyId) {
    const conn = new Conn(member, partyId);
    return conn.ready.then(() => conn);
  }

  constructor(member, partyId) {
    this.member = member;
    this.partyId = partyId;
    this.events = [];
    this.waiters = [];
    this.nextId = 1;
    this.pending = new Map();
    this.closed = null;
    const wsUrl = member.base.replace(/^http/, "ws") + `/parties/${partyId}/ws?key=${member.key}`;
    this.ws = new WebSocket(wsUrl);
    this.ready = new Promise((resolve, reject) => {
      this.ws.onerror = (e) => reject(new Error("websocket error " + (e.message || "")));
      this.ws.onclose = (e) => {
        this.closed = { code: e.code, reason: e.reason };
        reject(new Error(`closed before ready: ${e.code} ${e.reason}`));
        this.push({ t: "_closed", code: e.code, reason: e.reason });
      };
      this.ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        if (msg.t === "challenge") {
          this.ws.send(JSON.stringify({ t: "auth", sig: member.sign(`pp-ws\n${msg.party}\n${msg.nonce}`), name: member.name }));
          return;
        }
        if (msg.t === "snapshot") {
          this.snapshot = msg;
          resolve();
        }
        if (msg.t === "reply" && this.pending.has(msg.id)) {
          this.pending.get(msg.id)(msg);
          this.pending.delete(msg.id);
          return;
        }
        this.push(msg);
      };
    });
  }

  push(msg) {
    this.events.push(msg);
    for (const w of [...this.waiters]) {
      if (w.pred(msg)) {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        w.resolve(msg);
      }
    }
  }

  send(t, data = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, resolve);
      this.ws.send(JSON.stringify({ t, id, ...data }));
      setTimeout(() => reject(new Error(`no reply to ${t}`)), 10000);
    });
  }

  /** Wait for an event matching pred (already received or future). */
  waitFor(pred, ms = 8000) {
    const hit = this.events.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve };
      this.waiters.push(w);
      setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i >= 0) {
          this.waiters.splice(i, 1);
          reject(new Error("timed out waiting for event"));
        }
      }, ms);
    });
  }

  close() {
    try {
      this.ws.close(1000, "bye");
    } catch {}
  }
}

/** Verify a membership pass the way a host's gate will. */
export function verifyPass(pass, servicePublicKeyB64) {
  const [p, s] = pass.split(".");
  const payloadBytes = Buffer.from(p, "base64url");
  const key = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: servicePublicKeyB64 }, format: "jwk" });
  const ok = verify(null, payloadBytes, key, Buffer.from(s, "base64url"));
  return { ok, payload: JSON.parse(payloadBytes.toString()) };
}
