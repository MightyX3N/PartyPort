# PartyPort core

The background half of PartyPort, written in Go. It holds the device identity,
keeps a live connection to every party you're in, and (in later milestones)
runs the playit agent, the gate and the LAN bridge. The LÖVE UI in `../app`
starts it and controls it over a local connection.

## Build and run

```sh
go build -o partyport-core .         # partyport-core.exe on Windows
./partyport-core                     # normally the UI starts it for you
```

Flags / environment:

| Flag | Env | Default |
|---|---|---|
| `-data` | `PARTYPORT_DATA` | `%APPDATA%\PartyPort` / `~/.config/PartyPort` |
| `-service` | `PARTYPORT_SERVICE` | `https://partyport-service.drgamingdk.workers.dev` |
| `-port` | | `0` (any free port) |

Cross-compiling: `GOOS=windows GOARCH=amd64 go build`, `GOOS=android GOARCH=arm64 go build`, etc.

## Files in the data folder

| File | What |
|---|---|
| `identity.json` | device key (Ed25519 seed) and display name — keep private |
| `parties.json` | parties you're in |
| `control.json` | port and token for the UI connection (removed on exit) |
| `core.log` | log |

## Control protocol

TCP on `127.0.0.1:<port from control.json>`, one JSON object per line.
The first message must be `{"id":1,"op":"hello","token":"<token>"}`.

Requests `{"id": n, "op": "...", ...}` get `{"id": n, "ok": true, "data": ...}`
or `{"id": n, "ok": false, "error": "..."}`.

| op | fields |
|---|---|
| `state` | |
| `setName` | `name` |
| `setOnline` | `online` (bool) |
| `createParty` | `name` |
| `previewInvite` | `code` |
| `joinParty` | `code`, `password?` |
| `leaveParty` | `party` |
| `partyOp` | `party`, `t`, `data` — any party operation from `service/README.md` (chat, invites, roles…) |
| `quit` | |

Events pushed to the UI: `{"ev":"state", ...}` (full state, after every change),
`{"ev":"chat", party, msg}` and `{"ev":"party.gone", party, name, reason}`.

## Test

```sh
go build -o partyport-core . && python3 test/core_e2e.py ./partyport-core
```

Runs two cores (two users) against the live party service: names, creating and
joining parties, invites, chat, restart persistence, going offline, kicks, leaving,
the control token and single-instance check.
