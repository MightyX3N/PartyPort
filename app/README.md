# PartyPort app (UI)

The part of PartyPort you see, made with [LÖVE](https://love2d.org) 11.5.
All networking happens in the core (`../core`), which the app starts and talks
to over a local connection.

## Run from source

```sh
cd core && go build -o partyport-core . && cd ..
love app
```

The app looks for the core next to itself, then in `../core/`. To point it
somewhere else, set `PARTYPORT_CORE=/path/to/partyport-core`. To use a separate
profile (e.g. two users on one PC), set `PARTYPORT_DATA` to a different folder
for each.

## What's in this version

- First run: choose your name.
- Parties list with who's online, unread counts and the on/off power button.
- Start a party or join with an invite code (live preview of the party, password if needed).
- Party chat with event lines (joins, role changes, hosting).
- Invites: create, copy the code or a ready-made message, cancel codes.
- Members: make admin / member, hand over ownership, remove, leave or delete a party.
- Settings: name, interface size (small / normal / large).
- Ctrl+Q quits.

Hosting and joining games, more layouts and themes, the tray icon and Android
come in later milestones (see `../docs/ARCHITECTURE.md`).

## Credits

- Fonts: [Inter](https://github.com/rsms/inter) and
  [Space Grotesk](https://github.com/floriankarsten/space-grotesk), SIL Open Font License
  (licence files in `assets/fonts/`).
- [json.lua](https://github.com/rxi/json.lua) by rxi, MIT licence.
