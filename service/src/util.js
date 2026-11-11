// Small helpers shared by the Worker and the Durable Objects.

const enc = new TextEncoder();

export function utf8(s) {
  return enc.encode(s);
}

export function b64url(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(str) {
  if (typeof str !== "string" || !/^[A-Za-z0-9_-]*$/.test(str)) throw new Error("bad base64url");
  const s = str.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(s + "===".slice((s.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function sha256hex(data) {
  const buf = await crypto.subtle.digest("SHA-256", typeof data === "string" ? utf8(data) : data);
  return [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** A member key is a 32-byte Ed25519 public key in base64url (43 chars). */
export function isKey(k) {
  if (typeof k !== "string" || k.length !== 43) return false;
  try {
    return fromB64url(k).length === 32;
  } catch {
    return false;
  }
}

/** Verify an Ed25519 signature made by a member key. */
export async function verifySig(keyB64, sigB64, message) {
  try {
    const key = await crypto.subtle.importKey("raw", fromB64url(keyB64), { name: "Ed25519" }, false, ["verify"]);
    const sig = fromB64url(sigB64);
    if (sig.length !== 64) return false;
    return await crypto.subtle.verify("Ed25519", key, sig, typeof message === "string" ? utf8(message) : message);
  } catch {
    return false;
  }
}

export function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function error(status, code, message) {
  return json({ ok: false, error: code, message: message || code }, status);
}

/** Clean up a display or party name: trim, collapse whitespace, cap length. */
export function cleanName(s, max = 32) {
  if (typeof s !== "string") return null;
  const t = s.replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim();
  if (!t) return null;
  return t.slice(0, max);
}

// Invite codes: no 0/O/1/I/L so they are easy to read out loud.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function newInviteCode() {
  const b = crypto.getRandomValues(new Uint8Array(8));
  let s = "";
  for (let i = 0; i < 8; i++) {
    s += CODE_ALPHABET[b[i] % CODE_ALPHABET.length];
    if (i === 3) s += "-";
  }
  return s;
}

export function normaliseCode(code) {
  if (typeof code !== "string") return null;
  const c = code.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (c.length !== 8) return null;
  for (const ch of c) if (!CODE_ALPHABET.includes(ch)) return null;
  return c.slice(0, 4) + "-" + c.slice(4);
}

export const MAX_BODY = 8 * 1024;
export const CLOCK_SKEW_MS = 5 * 60 * 1000;

/**
 * Check a signed HTTP request from the app.
 * Headers: x-pp-key (member key), x-pp-time (unix ms), x-pp-sig.
 * Signature covers: METHOD \n PATH \n TIME \n sha256(body) hex.
 * Returns { key, body } or a Response with the error.
 */
export async function readSignedRequest(request) {
  const key = request.headers.get("x-pp-key");
  const time = request.headers.get("x-pp-time");
  const sig = request.headers.get("x-pp-sig");
  if (!isKey(key) || !time || !sig) return error(401, "unsigned", "Request must be signed");
  const t = Number(time);
  if (!Number.isFinite(t) || Math.abs(Date.now() - t) > CLOCK_SKEW_MS) {
    return error(401, "clock", "Request time is too far from server time");
  }
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY) return error(413, "too_large");
  const url = new URL(request.url);
  const msg = `${request.method}\n${url.pathname}\n${time}\n${await sha256hex(raw)}`;
  if (!(await verifySig(key, sig, msg))) return error(401, "bad_signature");
  let body = {};
  if (raw.byteLength) {
    try {
      body = JSON.parse(new TextDecoder().decode(raw));
    } catch {
      return error(400, "bad_json");
    }
  }
  return { key, body };
}
