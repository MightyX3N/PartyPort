# PartyPort party service

Cloudflare Worker that stores parties and relays live party events.
One Durable Object (SQLite) per party, plus a `Directory` object for invite
codes and a `Keys` object that holds the service signing key.

Design background: [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) section 4.

## Run and test locally

```sh
npm install
npx wrangler dev          # http://127.0.0.1:8787
npm test                  # end-to-end test against the local service
PARTYPORT_URL=https://<deployed-url> npm test   # same test against a deployment
```

Deploys happen from GitHub Actions (`.github/workflows/service.yml`) when
anything in `service/` changes on `main`. Needs the repo secrets
`CLOUDFLARE_API_TOKE` (sic) and `CLOUDFLARE_ACCOUNT_ID`.

## Identity

Every device has an Ed25519 key pair. A member key is the 32-byte public key
in base64url (43 characters). There are no accounts or passwords.

## HTTP API

Signed requests carry three headers:

| Header | Value |
|---|---|
| `x-pp-key` | member key |
| `x-pp-time` | current time, unix milliseconds (must be within 5 minutes) |
| `x-pp-sig` | base64url Ed25519 signature of `METHOD\nPATH\nTIME\nSHA256(body) hex` |

| Method & path | Signed | Body | Result |
|---|---|---|---|
| `GET /` | no | | `{service, version}` |
| `GET /service-key` | no | | `{key, alg: "Ed25519"}` — verifies membership passes |
| `POST /parties` | yes | `{name, displayName}` | `201 {ok, party}` — caller becomes owner |
| `GET /invites/:code` | no | | `{ok, code, name, members, hasPassword}` |
| `POST /invites/:code/join` | yes | `{displayName, password?}` | `{ok, partyId, name}` |
| `GET /parties/:id/ws?key=<member key>` | challenge | | WebSocket |

Invite codes look like `K7QM-3XWP`; case and the dash don't matter.
Join errors: `invite_not_found`, `invite_expired`, `invite_used_up` (404),
`wrong_password`, `banned` (403), `party_full` (409).

## WebSocket

1. Server sends `{t: "challenge", nonce, party}`.
2. Client sends `{t: "auth", sig, name?}` where `sig` signs `pp-ws\n<party>\n<nonce>`.
3. Server sends a `snapshot`: `{you, party, members, hosts, chat (last 100), invites (admins only)}`.

Requests are `{t, id, ...}`; every request gets `{t: "reply", id, ok, data | error}`.

| `t` | Who | Fields |
|---|---|---|
| `ping` | anyone | |
| `chat` | anyone | `text` (≤ 1000 chars, max 10 per 10 s) |
| `me.rename` | anyone | `name` |
| `host.start` | anyone | `game`, `label`, `gate` (`host:port`), `direct?`, `players?` |
| `host.update` | host | `players?`, `direct?` |
| `host.stop` | host | |
| `pass.request` | anyone | `host` (member key) → `{pass, expiresAt, gate, game}` |
| `party.leave` | anyone | last member leaving deletes the party |
| `invite.create` | admin | `hours` (1–720, default 168), `maxUses` (0 = unlimited) |
| `invite.revoke` | admin | `code` |
| `invite.list` | admin | |
| `member.kick` / `member.ban` | admin (owner for admins) | `key` |
| `member.unban` | admin | `key` |
| `party.rename` | admin | `name` |
| `party.settings` | admin | `password?` (null clears), `maxMembers?` |
| `member.role` | owner | `key`, `role` (`admin` / `member`) |
| `owner.transfer` | owner | `key` |

Live events from the server: `presence`, `member.joined`, `member.updated`,
`member.left`, `member.removed`, `member.role`, `party.updated`,
`host.started`, `host.updated`, `host.stopped`, `invite.created`,
`invite.revoked` (admins), and `chat` (messages and event lines).

Close codes: `4000` left, `4001` kicked/banned, `4003` auth failed, `4004` party deleted.

## Membership passes

`pass = base64url(payload) + "." + base64url(signature)`, where payload is JSON
`{v: 1, party, member, host, iat, exp}` signed with the service key. A host's gate
accepts a player when the signature verifies with `/service-key`, `host` is
its own key, `party` matches and `exp` is in the future. Passes last 10 minutes.

## Rules

- Chat keeps the last 500 messages per party.
- If the owner and all admins have been inactive for 30 days, the
  longest-standing member who has been active in that time becomes owner
  when they next connect; the old owner becomes an admin.
- A host that goes offline (no open connection) is removed from the hosts list.
