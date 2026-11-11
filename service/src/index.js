// PartyPort party service: HTTP + WebSocket entry point.
//
//   GET  /                         service info
//   GET  /service-key              public key that signs membership passes
//   POST /parties                  create a party            (signed)
//   GET  /invites/:code            preview an invite
//   POST /invites/:code/join       join a party with an invite (signed)
//   GET  /parties/:id/ws?key=...   live connection (WebSocket, challenge-signed)
//
// See ../README.md for the full protocol.

import { Party } from "./party.js";
import { Directory } from "./directory.js";
import { Keys } from "./keys.js";
import { json, error, readSignedRequest, cleanName, normaliseCode } from "./util.js";

export { Party, Directory, Keys };

const VERSION = "0.1.0";
const PARTY_ID_RE = /^[0-9a-f]{64}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const parts = path.split("/").filter(Boolean);

    try {
      if (request.method === "GET" && path === "/") {
        return json({ service: "partyport", version: VERSION });
      }

      if (request.method === "GET" && path === "/service-key") {
        const key = await env.KEYS.get(env.KEYS.idFromName("service")).publicKey();
        return json({ key, alg: "Ed25519" }, 200, { "cache-control": "public, max-age=3600" });
      }

      if (request.method === "POST" && path === "/parties") {
        const r = await readSignedRequest(request);
        if (r instanceof Response) return r;
        const name = cleanName(r.body.name, 40);
        const ownerName = cleanName(r.body.displayName);
        if (!name) return error(400, "bad_name", "Party name is required");
        if (!ownerName) return error(400, "bad_display_name", "Display name is required");
        const id = env.PARTY.newUniqueId();
        const party = await env.PARTY.get(id).create({ partyId: id.toString(), ownerKey: r.key, ownerName, name });
        return json({ ok: true, party }, 201);
      }

      if (parts[0] === "invites" && parts.length >= 2) {
        const code = normaliseCode(decodeURIComponent(parts[1]));
        if (!code) return error(404, "invite_not_found");
        const partyId = await env.DIRECTORY.get(env.DIRECTORY.idFromName("directory")).lookup(code);
        if (!partyId) return error(404, "invite_not_found");
        const stub = env.PARTY.get(env.PARTY.idFromString(partyId));

        if (request.method === "GET" && parts.length === 2) {
          const p = await stub.preview(code);
          if (p.error) return error(404, p.error);
          return json({ ok: true, code, ...p });
        }

        if (request.method === "POST" && parts.length === 3 && parts[2] === "join") {
          const r = await readSignedRequest(request);
          if (r instanceof Response) return r;
          const displayName = cleanName(r.body.displayName);
          if (!displayName) return error(400, "bad_display_name", "Display name is required");
          const res = await stub.join({ code, key: r.key, name: displayName, password: r.body.password });
          if (res.error) {
            const status = { banned: 403, wrong_password: 403, party_full: 409 }[res.error] || 404;
            return error(status, res.error);
          }
          return json(res);
        }
      }

      if (parts[0] === "parties" && parts.length === 3 && parts[2] === "ws" && request.method === "GET") {
        if (!PARTY_ID_RE.test(parts[1])) return error(404, "party_not_found");
        let id;
        try {
          id = env.PARTY.idFromString(parts[1]);
        } catch {
          return error(404, "party_not_found");
        }
        return env.PARTY.get(id).fetch(request);
      }

      return error(404, "not_found");
    } catch (e) {
      console.error("request failed", path, e && e.stack);
      return error(500, "server_error");
    }
  },
};
