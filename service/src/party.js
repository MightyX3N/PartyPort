import { DurableObject } from "cloudflare:workers";
import { b64url, utf8, isKey, verifySig, cleanName, newInviteCode, sha256hex, error } from "./util.js";

const CHAT_KEEP = 500; // messages kept per party
const CHAT_SNAPSHOT = 100; // messages sent when a client connects
const MAX_MESSAGE = 16 * 1024; // max WebSocket message size
const MAX_CHAT_TEXT = 1000;
const INACTIVE_MS = 30 * 24 * 60 * 60 * 1000; // owner hand-over after 30 days
const PASS_TTL_MS = 10 * 60 * 1000; // membership passes last 10 minutes
const DEFAULT_MAX_MEMBERS = 50;
const HARD_MAX_MEMBERS = 200;
const CHAT_RATE = { count: 10, windowMs: 10_000 };
const SWEEP_EVERY_MS = 2 * 60 * 1000; // check for dead connections
const SILENT_LIMIT_MS = 150 * 1000; // no ping or message for this long = gone
const ADDRESS_RE = /^[A-Za-z0-9.-]{1,100}:\d{1,5}$/;
const GAME_RE = /^[a-z0-9][a-z0-9._-]{0,39}$/;

// WebSocket close codes the app understands.
export const CLOSE = { LEFT: 4000, REMOVED: 4001, AUTH_FAILED: 4003, PARTY_GONE: 4004 };

/**
 * One Durable Object per party. It is the source of truth for the party's
 * members, roles, invites, hosts and recent chat, and it relays live events
 * to every connected member over WebSockets (Hibernation API).
 */
export class Party extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.rate = new Map();
    this.migrate();
    // Clients send "ping" every 25 s; Cloudflare answers "pong" without
    // waking this object, and records when it last did so.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  migrate() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
      CREATE TABLE IF NOT EXISTS members (
        key TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
        joined_at INTEGER NOT NULL, last_seen INTEGER NOT NULL, invited_by TEXT);
      CREATE TABLE IF NOT EXISTS invites (
        code TEXT PRIMARY KEY, created_by TEXT NOT NULL, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, max_uses INTEGER NOT NULL, uses INTEGER NOT NULL DEFAULT 0,
        revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS bans (key TEXT PRIMARY KEY, by_key TEXT, at INTEGER);
      CREATE TABLE IF NOT EXISTS hosts (
        key TEXT PRIMARY KEY, game TEXT NOT NULL, label TEXT NOT NULL, gate TEXT NOT NULL,
        direct TEXT, players INTEGER NOT NULL DEFAULT 0, started_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS chat (
        id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, sender TEXT,
        kind TEXT NOT NULL, body TEXT NOT NULL);
    `);
  }

  // ---------- storage helpers ----------

  meta(k) {
    const row = this.sql.exec("SELECT v FROM meta WHERE k = ?", k).toArray()[0];
    return row ? row.v : null;
  }
  setMeta(k, v) {
    if (v === null || v === undefined) this.sql.exec("DELETE FROM meta WHERE k = ?", k);
    else this.sql.exec("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, String(v));
  }
  exists() {
    return this.meta("id") !== null;
  }
  member(key) {
    return this.sql.exec("SELECT * FROM members WHERE key = ?", key).toArray()[0] || null;
  }
  members() {
    return this.sql.exec("SELECT * FROM members ORDER BY joined_at ASC").toArray();
  }
  memberCount() {
    return this.sql.exec("SELECT COUNT(*) AS n FROM members").one().n;
  }
  isBanned(key) {
    return this.sql.exec("SELECT 1 FROM bans WHERE key = ?", key).toArray().length > 0;
  }
  hosts() {
    return this.sql.exec("SELECT * FROM hosts ORDER BY started_at ASC").toArray();
  }
  partyInfo() {
    return {
      id: this.meta("id"),
      name: this.meta("name"),
      createdAt: Number(this.meta("created_at")),
      hasPassword: this.meta("password_hash") !== null,
      maxMembers: Number(this.meta("max_members") || DEFAULT_MAX_MEMBERS),
    };
  }
  directory() {
    return this.env.DIRECTORY.get(this.env.DIRECTORY.idFromName("directory"));
  }
  keys() {
    return this.env.KEYS.get(this.env.KEYS.idFromName("service"));
  }

  // ---------- presentation ----------

  memberView(m) {
    return {
      key: m.key,
      name: m.name,
      role: m.role,
      joinedAt: m.joined_at,
      lastSeen: m.last_seen,
      online: this.socketsFor(m.key).length > 0,
    };
  }
  hostView(h) {
    return {
      key: h.key,
      game: h.game,
      label: h.label,
      gate: h.gate,
      direct: h.direct || null,
      players: h.players,
      startedAt: h.started_at,
    };
  }
  inviteView(i) {
    return {
      code: i.code,
      createdBy: i.created_by,
      createdAt: i.created_at,
      expiresAt: i.expires_at,
      maxUses: i.max_uses,
      uses: i.uses,
      revoked: !!i.revoked,
      expired: i.expires_at < Date.now(),
    };
  }
  chatView(c) {
    return { id: c.id, at: c.at, sender: c.sender, kind: c.kind, ...JSON.parse(c.body) };
  }

  // ---------- chat log ----------

  addChat(sender, kind, body) {
    const at = Date.now();
    const id = this.sql
      .exec("INSERT INTO chat (at, sender, kind, body) VALUES (?, ?, ?, ?) RETURNING id", at, sender, kind, JSON.stringify(body))
      .one().id;
    this.sql.exec("DELETE FROM chat WHERE id <= ?", id - CHAT_KEEP);
    const msg = { id, at, sender, kind, ...body };
    this.broadcast({ t: "chat", msg });
    return msg;
  }
  addEvent(type, data = {}, sender = null) {
    return this.addChat(sender, "event", { type, ...data });
  }

  // ---------- sockets ----------

  authedSockets() {
    return this.ctx.getWebSockets().filter((ws) => {
      const a = ws.deserializeAttachment();
      return a && a.authed && !a.gone;
    });
  }
  socketsFor(key) {
    return this.authedSockets().filter((ws) => ws.deserializeAttachment().key === key);
  }
  send(ws, obj) {
    try {
      ws.send(JSON.stringify(obj));
    } catch {
      /* socket already gone */
    }
  }
  broadcast(obj, filter) {
    const data = JSON.stringify(obj);
    for (const ws of this.authedSockets()) {
      if (filter && !filter(ws.deserializeAttachment())) continue;
      try {
        ws.send(data);
      } catch {
        /* ignore */
      }
    }
  }
  broadcastToAdmins(obj) {
    this.broadcast(obj, (a) => {
      const m = this.member(a.key);
      return m && (m.role === "owner" || m.role === "admin");
    });
  }
  closeSocketsFor(key, code, reason) {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a && a.key === key) {
        try {
          ws.close(code, reason);
        } catch {
          /* ignore */
        }
      }
    }
  }

  // ---------- RPC called by the Worker ----------

  async create({ partyId, ownerKey, ownerName, name }) {
    if (this.exists()) throw new Error("party already exists");
    const now = Date.now();
    this.setMeta("id", partyId);
    this.setMeta("name", name);
    this.setMeta("created_at", now);
    this.setMeta("max_members", DEFAULT_MAX_MEMBERS);
    this.sql.exec(
      "INSERT INTO members (key, name, role, joined_at, last_seen, invited_by) VALUES (?, ?, 'owner', ?, ?, NULL)",
      ownerKey, ownerName, now, now
    );
    this.addEvent("party.created", { name }, ownerKey);
    return this.partyInfo();
  }

  validInvite(code) {
    const inv = this.sql.exec("SELECT * FROM invites WHERE code = ?", code).toArray()[0];
    if (!inv || inv.revoked) return { error: "invite_not_found" };
    if (inv.expires_at < Date.now()) return { error: "invite_expired" };
    if (inv.max_uses > 0 && inv.uses >= inv.max_uses) return { error: "invite_used_up" };
    return { inv };
  }

  async preview(code) {
    if (!this.exists()) return { error: "invite_not_found" };
    const v = this.validInvite(code);
    if (v.error) return { error: v.error };
    const info = this.partyInfo();
    return { name: info.name, members: this.memberCount(), hasPassword: info.hasPassword };
  }

  async join({ code, key, name, password }) {
    if (!this.exists()) return { error: "invite_not_found" };
    if (this.isBanned(key)) return { error: "banned" };
    const info = this.partyInfo();
    const existing = this.member(key);
    if (existing) return { ok: true, partyId: info.id, name: info.name, alreadyMember: true };
    const v = this.validInvite(code);
    if (v.error) return { error: v.error };
    if (info.hasPassword) {
      const salt = this.meta("password_salt");
      if (typeof password !== "string" || (await sha256hex(salt + password)) !== this.meta("password_hash")) {
        return { error: "wrong_password" };
      }
    }
    if (this.memberCount() >= info.maxMembers) return { error: "party_full" };
    const now = Date.now();
    this.sql.exec(
      "INSERT INTO members (key, name, role, joined_at, last_seen, invited_by) VALUES (?, ?, 'member', ?, ?, ?)",
      key, name, now, now, v.inv.created_by
    );
    this.sql.exec("UPDATE invites SET uses = uses + 1 WHERE code = ?", code);
    const m = this.member(key);
    this.broadcast({ t: "member.joined", member: this.memberView(m) });
    this.addEvent("member.joined", { name }, key);
    return { ok: true, partyId: info.id, name: info.name };
  }

  // ---------- WebSocket entry ----------

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") return error(426, "websocket_required");
    if (!this.exists()) return error(404, "party_not_found");
    const key = new URL(request.url).searchParams.get("key");
    if (!isKey(key)) return error(400, "bad_key");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    const nonce = b64url(crypto.getRandomValues(new Uint8Array(24)));
    server.serializeAttachment({ key, nonce, authed: false });
    server.send(JSON.stringify({ t: "challenge", nonce, party: this.meta("id") }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE) {
      return this.send(ws, { t: "error", error: "bad_message" });
    }
    let msg;
    try {
      msg = JSON.parse(message);
    } catch {
      return this.send(ws, { t: "error", error: "bad_json" });
    }
    const att = ws.deserializeAttachment();
    if (!att) return;

    if (!att.authed) return this.handleAuth(ws, att, msg);
    if (Date.now() - (att.at || 0) > 30_000) ws.serializeAttachment({ ...att, at: Date.now() });

    const me = this.member(att.key);
    if (!me) {
      ws.close(CLOSE.REMOVED, "not a member");
      return;
    }
    const reply = (ok, data) => this.send(ws, ok ? { t: "reply", id: msg.id, ok: true, data } : { t: "reply", id: msg.id, ok: false, error: data });
    try {
      const result = (await this.handle(ws, me, msg)) || {};
      const after = result.afterReply;
      delete result.afterReply;
      if (result.error) reply(false, result.error);
      else reply(true, result);
      if (after) await after();
    } catch (e) {
      reply(false, "server_error");
      console.error("party op failed", msg.t, e && e.stack);
    }
  }

  async handleAuth(ws, att, msg) {
    if (msg.t !== "auth" || typeof msg.sig !== "string") {
      this.send(ws, { t: "error", error: "auth_required" });
      return ws.close(CLOSE.AUTH_FAILED, "auth required");
    }
    const partyId = this.meta("id");
    const ok = await verifySig(att.key, msg.sig, `pp-ws\n${partyId}\n${att.nonce}`);
    const m = ok ? this.member(att.key) : null;
    if (!ok || !m || this.isBanned(att.key)) {
      this.send(ws, { t: "error", error: !ok ? "bad_signature" : "not_a_member" });
      return ws.close(CLOSE.AUTH_FAILED, "auth failed");
    }
    const wasOnline = this.socketsFor(att.key).length > 0;
    ws.serializeAttachment({ key: att.key, authed: true, at: Date.now() });

    const now = Date.now();
    const newName = cleanName(msg.name);
    if (newName && newName !== m.name) {
      this.sql.exec("UPDATE members SET name = ? WHERE key = ?", newName, att.key);
      this.broadcast({ t: "member.updated", member: this.memberView(this.member(att.key)) });
    }
    this.sql.exec("UPDATE members SET last_seen = ? WHERE key = ?", now, att.key);
    this.checkInactiveOwner(att.key);

    this.send(ws, this.snapshot(att.key));
    if (!wasOnline) this.broadcast({ t: "presence", key: att.key, online: true }, (a) => a.key !== att.key);
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + this.sweepEvery());
  }

  /** Close connections that have gone silent (crashed app, lost network). */
  async alarm() {
    const now = Date.now();
    for (const ws of this.authedSockets()) {
      const att = ws.deserializeAttachment();
      const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws);
      const last = Math.max(att.at || 0, pinged ? pinged.getTime() : 0);
      if (now - last > (Number(this.env.TEST_SILENT_MS) || SILENT_LIMIT_MS)) {
        ws.serializeAttachment({ ...att, gone: true });
        this.onSocketGone(ws, att);
        try {
          ws.close(4002, "timed out");
        } catch {
          /* already gone */
        }
      }
    }
    if (this.authedSockets().length > 0) await this.ctx.storage.setAlarm(now + this.sweepEvery());
  }

  // Timings can be shortened through env vars for tests only.
  sweepEvery() {
    return Number(this.env.TEST_SWEEP_MS) || SWEEP_EVERY_MS;
  }

  snapshot(key) {
    const me = this.member(key);
    const isAdmin = me.role === "owner" || me.role === "admin";
    const chat = this.sql
      .exec("SELECT * FROM (SELECT * FROM chat ORDER BY id DESC LIMIT ?) ORDER BY id ASC", CHAT_SNAPSHOT)
      .toArray()
      .map((c) => this.chatView(c));
    return {
      t: "snapshot",
      you: { key, role: me.role },
      party: this.partyInfo(),
      members: this.members().map((m) => this.memberView(m)),
      hosts: this.hosts().map((h) => this.hostView(h)),
      chat,
      invites: isAdmin ? this.listInvites() : undefined,
    };
  }

  listInvites() {
    return this.sql
      .exec("SELECT * FROM invites WHERE revoked = 0 ORDER BY created_at DESC")
      .toArray()
      .map((i) => this.inviteView(i));
  }

  /**
   * If the owner and every admin have been away for 30 days, hand ownership
   * to the longest-standing member who has been active in that time.
   */
  checkInactiveOwner(connectingKey) {
    // INACTIVE_MS can be shortened through an env var for tests only.
    const cutoff = Date.now() - (Number(this.env.TEST_INACTIVE_MS) || INACTIVE_MS);
    const leaders = this.sql.exec("SELECT key, last_seen FROM members WHERE role IN ('owner','admin')").toArray();
    if (leaders.some((l) => l.last_seen >= cutoff)) return;
    const candidate = this.sql
      .exec("SELECT key FROM members WHERE role = 'member' AND last_seen >= ? ORDER BY joined_at ASC LIMIT 1", cutoff)
      .toArray()[0];
    if (!candidate || candidate.key !== connectingKey) return;
    const owner = this.sql.exec("SELECT key FROM members WHERE role = 'owner'").toArray()[0];
    if (owner) this.sql.exec("UPDATE members SET role = 'admin' WHERE key = ?", owner.key);
    this.sql.exec("UPDATE members SET role = 'owner' WHERE key = ?", candidate.key);
    if (owner) this.broadcast({ t: "member.role", key: owner.key, role: "admin" });
    this.broadcast({ t: "member.role", key: candidate.key, role: "owner" });
    this.addEvent("owner.handover", { to: candidate.key, from: owner ? owner.key : null, reason: "inactive" });
  }

  async webSocketClose(ws, code, reason) {
    this.onSocketGone(ws);
    try {
      ws.close(code, reason);
    } catch {
      /* already closed */
    }
  }

  async webSocketError(ws) {
    this.onSocketGone(ws);
  }

  onSocketGone(ws, known) {
    const att = known || ws.deserializeAttachment();
    this.rate.delete(ws);
    if (!att || !att.authed) return;
    if (!known && att.gone) return; // already handled by the sweep
    if (!this.exists()) return;
    // The closing socket can still be listed while closing; exclude it.
    const others = this.socketsFor(att.key).filter((s) => s !== ws);
    if (this.member(att.key)) this.sql.exec("UPDATE members SET last_seen = ? WHERE key = ?", Date.now(), att.key);
    if (others.length === 0) {
      const hosting = this.sql.exec("SELECT 1 FROM hosts WHERE key = ?", att.key).toArray().length > 0;
      if (hosting) {
        this.sql.exec("DELETE FROM hosts WHERE key = ?", att.key);
        this.broadcast({ t: "host.stopped", key: att.key, reason: "offline" });
      }
      this.broadcast({ t: "presence", key: att.key, online: false });
    }
  }

  // ---------- operations ----------

  async handle(ws, me, msg) {
    const isOwner = me.role === "owner";
    const isAdmin = isOwner || me.role === "admin";
    switch (msg.t) {
      case "ping":
        return { pong: Date.now() };

      case "chat": {
        if (typeof msg.text !== "string") return { error: "bad_text" };
        const text = msg.text.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").trim();
        if (!text || text.length > MAX_CHAT_TEXT) return { error: "bad_text" };
        if (!this.allowChat(ws)) return { error: "slow_down" };
        const m = this.addChat(me.key, "msg", { text });
        return { id: m.id };
      }

      case "me.rename": {
        const name = cleanName(msg.name);
        if (!name) return { error: "bad_name" };
        this.sql.exec("UPDATE members SET name = ? WHERE key = ?", name, me.key);
        this.broadcast({ t: "member.updated", member: this.memberView(this.member(me.key)) });
        return {};
      }

      case "invite.create": {
        if (!isAdmin) return { error: "forbidden" };
        const hours = clampInt(msg.hours, 1, 720, 168);
        const maxUses = clampInt(msg.maxUses, 0, 1000, 0);
        const now = Date.now();
        const dir = this.directory();
        let code = null;
        for (let i = 0; i < 6 && !code; i++) {
          const c = newInviteCode();
          if (await dir.claim(c, this.meta("id"))) code = c;
        }
        if (!code) return { error: "try_again" };
        this.sql.exec(
          "INSERT INTO invites (code, created_by, created_at, expires_at, max_uses) VALUES (?, ?, ?, ?, ?)",
          code, me.key, now, now + hours * 3600_000, maxUses
        );
        const inv = this.inviteView(this.sql.exec("SELECT * FROM invites WHERE code = ?", code).one());
        this.broadcastToAdmins({ t: "invite.created", invite: inv });
        return { invite: inv };
      }

      case "invite.revoke": {
        if (!isAdmin) return { error: "forbidden" };
        const inv = this.sql.exec("SELECT * FROM invites WHERE code = ?", String(msg.code || "")).toArray()[0];
        if (!inv) return { error: "invite_not_found" };
        this.sql.exec("UPDATE invites SET revoked = 1 WHERE code = ?", inv.code);
        await this.directory().release(inv.code);
        this.broadcastToAdmins({ t: "invite.revoked", code: inv.code });
        return {};
      }

      case "invite.list":
        if (!isAdmin) return { error: "forbidden" };
        return { invites: this.listInvites() };

      case "member.kick":
      case "member.ban": {
        if (!isAdmin) return { error: "forbidden" };
        const target = this.member(String(msg.key || ""));
        if (!target) return { error: "not_found" };
        if (target.key === me.key) return { error: "cannot_target_self" };
        if (target.role === "owner") return { error: "forbidden" };
        if (target.role === "admin" && !isOwner) return { error: "forbidden" };
        const banned = msg.t === "member.ban";
        this.removeMember(target.key);
        if (banned) {
          this.sql.exec("INSERT OR REPLACE INTO bans (key, by_key, at) VALUES (?, ?, ?)", target.key, me.key, Date.now());
        }
        this.broadcast({ t: "member.removed", key: target.key, by: me.key, banned });
        this.addEvent(banned ? "member.banned" : "member.kicked", { key: target.key, name: target.name }, me.key);
        this.closeSocketsFor(target.key, CLOSE.REMOVED, banned ? "banned" : "kicked");
        return {};
      }

      case "member.unban": {
        if (!isAdmin) return { error: "forbidden" };
        this.sql.exec("DELETE FROM bans WHERE key = ?", String(msg.key || ""));
        return {};
      }

      case "member.role": {
        if (!isOwner) return { error: "forbidden" };
        const target = this.member(String(msg.key || ""));
        if (!target) return { error: "not_found" };
        if (target.role === "owner") return { error: "forbidden" };
        if (msg.role !== "admin" && msg.role !== "member") return { error: "bad_role" };
        this.sql.exec("UPDATE members SET role = ? WHERE key = ?", msg.role, target.key);
        this.broadcast({ t: "member.role", key: target.key, role: msg.role });
        this.addEvent("member.role", { key: target.key, name: target.name, role: msg.role }, me.key);
        return {};
      }

      case "owner.transfer": {
        if (!isOwner) return { error: "forbidden" };
        const target = this.member(String(msg.key || ""));
        if (!target || target.key === me.key) return { error: "not_found" };
        this.sql.exec("UPDATE members SET role = 'admin' WHERE key = ?", me.key);
        this.sql.exec("UPDATE members SET role = 'owner' WHERE key = ?", target.key);
        this.broadcast({ t: "member.role", key: me.key, role: "admin" });
        this.broadcast({ t: "member.role", key: target.key, role: "owner" });
        this.addEvent("owner.handover", { to: target.key, from: me.key, reason: "transfer" }, me.key);
        return {};
      }

      case "party.rename": {
        if (!isAdmin) return { error: "forbidden" };
        const name = cleanName(msg.name, 40);
        if (!name) return { error: "bad_name" };
        this.setMeta("name", name);
        this.broadcast({ t: "party.updated", party: this.partyInfo() });
        this.addEvent("party.renamed", { name }, me.key);
        return {};
      }

      case "party.settings": {
        if (!isAdmin) return { error: "forbidden" };
        if ("password" in msg) {
          if (msg.password === null || msg.password === "") {
            this.setMeta("password_hash", null);
            this.setMeta("password_salt", null);
          } else if (typeof msg.password === "string" && msg.password.length <= 64) {
            const salt = b64url(crypto.getRandomValues(new Uint8Array(16)));
            this.setMeta("password_salt", salt);
            this.setMeta("password_hash", await sha256hex(salt + msg.password));
          } else return { error: "bad_password" };
        }
        if ("maxMembers" in msg) {
          const n = clampInt(msg.maxMembers, 2, HARD_MAX_MEMBERS, null);
          if (n === null) return { error: "bad_max_members" };
          this.setMeta("max_members", Math.max(n, this.memberCount()));
        }
        this.broadcast({ t: "party.updated", party: this.partyInfo() });
        return { party: this.partyInfo() };
      }

      case "party.leave": {
        const others = this.sql.exec("SELECT * FROM members WHERE key != ? ORDER BY joined_at ASC", me.key).toArray();
        if (others.length === 0) {
          return { deleted: true, afterReply: () => this.deleteParty() };
        }
        if (isOwner) {
          const next = others.find((o) => o.role === "admin") || others[0];
          this.sql.exec("UPDATE members SET role = 'owner' WHERE key = ?", next.key);
          this.broadcast({ t: "member.role", key: next.key, role: "owner" });
          this.addEvent("owner.handover", { to: next.key, from: me.key, reason: "left" });
        }
        this.removeMember(me.key);
        this.broadcast({ t: "member.left", key: me.key });
        this.addEvent("member.left", { key: me.key, name: me.name }, me.key);
        // Close only after the reply has been sent.
        return { left: true, afterReply: () => this.closeSocketsFor(me.key, CLOSE.LEFT, "left") };
      }

      case "host.start": {
        const game = typeof msg.game === "string" ? msg.game.toLowerCase() : "";
        if (!GAME_RE.test(game)) return { error: "bad_game" };
        const label = cleanName(msg.label, 60) || game;
        if (typeof msg.gate !== "string" || !ADDRESS_RE.test(msg.gate)) return { error: "bad_gate" };
        let direct = null;
        if (msg.direct != null) {
          if (typeof msg.direct !== "string" || !ADDRESS_RE.test(msg.direct)) return { error: "bad_direct" };
          direct = msg.direct;
        }
        const players = clampInt(msg.players, 0, 1000, 0);
        const was = this.sql.exec("SELECT 1 FROM hosts WHERE key = ?", me.key).toArray().length > 0;
        this.sql.exec(
          `INSERT INTO hosts (key, game, label, gate, direct, players, started_at) VALUES (?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(key) DO UPDATE SET game = excluded.game, label = excluded.label, gate = excluded.gate,
             direct = excluded.direct, players = excluded.players`,
          me.key, game, label, msg.gate, direct, players, Date.now()
        );
        const host = this.hostView(this.sql.exec("SELECT * FROM hosts WHERE key = ?", me.key).one());
        this.broadcast({ t: was ? "host.updated" : "host.started", host });
        if (!was) this.addEvent("host.started", { game, label }, me.key);
        return { host };
      }

      case "host.update": {
        const row = this.sql.exec("SELECT * FROM hosts WHERE key = ?", me.key).toArray()[0];
        if (!row) return { error: "not_hosting" };
        if ("players" in msg) this.sql.exec("UPDATE hosts SET players = ? WHERE key = ?", clampInt(msg.players, 0, 1000, 0), me.key);
        if ("direct" in msg) {
          if (msg.direct !== null && (typeof msg.direct !== "string" || !ADDRESS_RE.test(msg.direct))) return { error: "bad_direct" };
          this.sql.exec("UPDATE hosts SET direct = ? WHERE key = ?", msg.direct, me.key);
        }
        const host = this.hostView(this.sql.exec("SELECT * FROM hosts WHERE key = ?", me.key).one());
        this.broadcast({ t: "host.updated", host });
        return { host };
      }

      case "host.stop": {
        const row = this.sql.exec("SELECT * FROM hosts WHERE key = ?", me.key).toArray()[0];
        if (!row) return { error: "not_hosting" };
        this.sql.exec("DELETE FROM hosts WHERE key = ?", me.key);
        this.broadcast({ t: "host.stopped", key: me.key, reason: "stopped" });
        this.addEvent("host.stopped", { game: row.game, label: row.label }, me.key);
        return {};
      }

      case "pass.request": {
        const host = this.sql.exec("SELECT * FROM hosts WHERE key = ?", String(msg.host || "")).toArray()[0];
        if (!host) return { error: "not_hosting" };
        const now = Date.now();
        const payload = { v: 1, party: this.meta("id"), member: me.key, host: host.key, iat: now, exp: now + PASS_TTL_MS };
        const bytes = utf8(JSON.stringify(payload));
        const sig = await this.keys().sign(bytes);
        return { pass: `${b64url(bytes)}.${sig}`, expiresAt: payload.exp, gate: host.gate, game: host.game };
      }

      default:
        return { error: "unknown_op" };
    }
  }

  allowChat(ws) {
    const now = Date.now();
    let r = this.rate.get(ws);
    if (!r || now - r.start > CHAT_RATE.windowMs) {
      r = { start: now, count: 0 };
      this.rate.set(ws, r);
    }
    r.count++;
    return r.count <= CHAT_RATE.count;
  }

  removeMember(key) {
    this.sql.exec("DELETE FROM members WHERE key = ?", key);
    const hosting = this.sql.exec("SELECT 1 FROM hosts WHERE key = ?", key).toArray().length > 0;
    if (hosting) {
      this.sql.exec("DELETE FROM hosts WHERE key = ?", key);
      this.broadcast({ t: "host.stopped", key, reason: "removed" });
    }
  }

  async deleteParty() {
    const id = this.meta("id");
    await this.directory().releaseParty(id);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(CLOSE.PARTY_GONE, "party deleted");
      } catch {
        /* ignore */
      }
    }
    await this.ctx.storage.deleteAll();
    this.migrate();
  }
}

function clampInt(v, min, max, dflt) {
  const n = Number(v);
  if (v === undefined || v === null || !Number.isFinite(n)) return dflt;
  return Math.min(max, Math.max(min, Math.floor(n)));
}

