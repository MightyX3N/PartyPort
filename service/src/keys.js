import { DurableObject } from "cloudflare:workers";
import { b64url } from "./util.js";

/**
 * Holds the service signing key (Ed25519). It is generated the first time it
 * is needed and never leaves this Durable Object: others ask it to sign.
 * Hosts verify membership passes with the public key.
 */
export class Keys extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS keys (id TEXT PRIMARY KEY, pkcs8 BLOB, pub BLOB, created_at INTEGER)");
    this.cached = null;
  }

  async load() {
    if (this.cached) return this.cached;
    let row = this.sql.exec("SELECT pkcs8, pub FROM keys WHERE id = 'service'").toArray()[0];
    if (!row) {
      const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
      const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
      const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
      this.sql.exec("INSERT INTO keys (id, pkcs8, pub, created_at) VALUES ('service', ?, ?, ?)", pkcs8, pub, Date.now());
      row = { pkcs8, pub };
    }
    const priv = await crypto.subtle.importKey("pkcs8", new Uint8Array(row.pkcs8), { name: "Ed25519" }, false, ["sign"]);
    this.cached = { priv, pub: b64url(new Uint8Array(row.pub)) };
    return this.cached;
  }

  async publicKey() {
    return (await this.load()).pub;
  }

  /** Sign bytes with the service key; returns base64url signature. */
  async sign(bytes) {
    const { priv } = await this.load();
    return b64url(new Uint8Array(await crypto.subtle.sign("Ed25519", priv, bytes)));
  }
}
