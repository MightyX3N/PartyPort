// Dead-connection sweep test. Run against: wrangler dev --var TEST_SWEEP_MS:1500 --var TEST_SILENT_MS:3000
import { Member } from "./client.mjs";
const BASE = process.env.PARTYPORT_URL || "http://127.0.0.1:8789";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
const check = (c, m) => { console.log(`${c ? "PASS" : "FAIL"} ${m}`); if (!c) fails++; };

const a = new Member(BASE, "Alive"), d = new Member(BASE, "Dead");
const pid = (await a.createParty("Sweep")).data.party.id;
const ac = await a.connect(pid);
const code = (await ac.send("invite.create", {})).data.invite.code;
await d.join(code);
const dc = await d.connect(pid);
// Alive keeps pinging like the real core; Dead goes silent.
const timer = setInterval(() => ac.ws.send("ping"), 1000);
let pongs = 0;
ac.ws.addEventListener("message", (e) => { if (e.data === "pong") pongs++; });
const off = await ac.waitFor((x) => x.t === "presence" && x.key === d.key && !x.online, 15000).catch(() => null);
check(!!off, "a silent connection is marked offline by the sweep");
check(pongs > 0, "pings get pong replies");
await sleep(4000);
check(!ac.closed, "a connection that keeps pinging stays open");
const r = await ac.send("chat", { text: "still here" });
check(r.ok, "and still works");
clearInterval(timer);
await ac.send("party.leave"); 
console.log(fails ? `${fails} FAILED` : "ALL PASSED");
process.exit(fails ? 1 : 0);
