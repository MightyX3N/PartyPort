# PartyPort

**Play LAN games with friends, from anywhere.**

PartyPort is a Hamachi-style app built on [playit.gg](https://playit.gg).
Join a party, and your friends' game servers show up in your game's LAN list
as if everyone were on the same Wi-Fi. No port forwarding, no IP addresses to share.

> Status: early development. Parties, invites and chat work; hosting and
> joining games come next. Nothing to download yet — see
> [app/README.md](app/README.md) to run it from source.

## How it will work

1. **Join a party** with an invite code. See who's online and what they're hosting.
2. **Someone hosts.** PartyPort opens a playit.gg tunnel for their game.
   Only the host needs a playit.gg account.
3. **It shows up in your game.** Click Join and the server appears under LAN
   (where the game has a LAN list), or connect to `127.0.0.1`.

Planned features: party-members-only servers (with an option to open them to
anyone), party chat, Windows / Linux / Android (phone and tablet) from one app,
and themes including a classic Hamachi-style look.

## Docs

- [Architecture plan](docs/ARCHITECTURE.md)
- [App (UI)](app/README.md) · [Core](core/README.md) · [Party service](service/README.md)

## Repository layout

```
app/        UI (LÖVE / Lua)
core/       background core (Go): networking, identity, later the gate and LAN bridge
service/    Cloudflare Worker for parties, invites and chat
website/    download site (partyport.dovecross.site)
docs/       design documents
```

PartyPort is an independent project and is not affiliated with playit.gg.
