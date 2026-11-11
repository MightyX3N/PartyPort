// End-to-end test for the party service, run against a live URL:
//   node test/e2e.mjs                      -> http://127.0.0.1:8787 (wrangler dev)
//   PARTYPORT_URL=https://... node test/e2e.mjs
import { Member, verifyPass } from "./client.mjs";

const BASE = process.env.PARTYPORT_URL || "http://127.0.0.1:8787";
let failures = 0;
const check = (cond, msg) => {
  console.log(`${cond ? "PASS" : "FAIL"} ${msg}`);
  if (!cond) failures++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const closedWith = (conn, code) => conn.waitFor((e) => e.t === "_closed").then((e) => e.code === code);

async function connectFails(member, partyId) {
  try {
    const c = await member.connect(partyId);
    c.close();
    return null;
  } catch (e) {
    return e.message;
  }
}

async function main() {
  console.log("Testing", BASE);

  // --- service basics ---
  const info = await (await fetch(BASE + "/")).json();
  check(info.service === "partyport", "service answers on /");
  const sk1 = (await (await fetch(BASE + "/service-key")).json()).key;
  const sk2 = (await (await fetch(BASE + "/service-key")).json()).key;
  check(typeof sk1 === "string" && sk1.length === 43 && sk1 === sk2, "service key is stable");

  const mighty = new Member(BASE, "Mighty");
  const jonas = new Member(BASE, "Jonas");
  const emil = new Member(BASE, "Emil");
  const sara = new Member(BASE, "Sara");
  const oliver = new Member(BASE, "Oliver");

  // --- creating a party ---
  const unsigned = await fetch(BASE + "/parties", { method: "POST", body: "{}" });
  check(unsigned.status === 401, "unsigned create is rejected");
  const tampered = await mighty.request("POST", "/parties", { name: "X", displayName: "Mighty" }, { tamper: true });
  check(tampered.status === 401 && tampered.data.error === "bad_signature", "bad signature is rejected");
  const noName = await mighty.request("POST", "/parties", { displayName: "Mighty" });
  check(noName.status === 400, "party name required");

  const created = await mighty.createParty("Friday Gaming");
  check(created.status === 201 && /^[0-9a-f]{64}$/.test(created.data.party.id), "owner creates a party");
  const partyId = created.data.party.id;

  let m1 = await mighty.connect(partyId);
  check(m1.snapshot.you.role === "owner", "creator is owner");
  check(m1.snapshot.chat.some((c) => c.type === "party.created"), "chat starts with a party.created event");
  check(Array.isArray(m1.snapshot.invites), "owner sees invites");

  const inv = await m1.send("invite.create", { hours: 24 });
  const code = inv.data.invite.code;
  check(inv.ok && /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(code), `invite created (${code})`);

  // --- owner goes offline; people still join ---
  m1.close();
  await sleep(300);
  const preview = await (await fetch(`${BASE}/invites/${code.toLowerCase().replace("-", "")}`)).json();
  check(preview.ok && preview.name === "Friday Gaming" && preview.members === 1, "invite preview works (any case, no dash)");

  const j = await jonas.join(code);
  check(j.status === 200 && j.data.partyId === partyId, "Jonas joins while the owner is offline");
  const e = await emil.join(code);
  check(e.status === 200, "Emil joins while the owner is offline");
  const again = await emil.join(code);
  check(again.status === 200 && again.data.alreadyMember, "joining twice is harmless");

  const jc = await jonas.connect(partyId);
  check(jc.snapshot.members.length === 3, "Jonas sees 3 members");
  check(jc.snapshot.you.role === "member" && jc.snapshot.invites === undefined, "members don't see invite list");
  const ec = await emil.connect(partyId);
  check(!!(await jc.waitFor((x) => x.t === "presence" && x.key === emil.key && x.online)), "Jonas sees Emil come online");

  // --- chat ---
  const sent = await jc.send("chat", { text: "starting the server, give me a sec" });
  check(sent.ok, "Jonas sends a chat message");
  const got = await ec.waitFor((x) => x.t === "chat" && x.msg.kind === "msg");
  check(got.msg.text === "starting the server, give me a sec" && got.msg.sender === jonas.key, "Emil receives it live");
  check(!(await jc.send("chat", { text: "   " })).ok, "empty chat is rejected");
  check(!(await jc.send("invite.create", {})).ok, "members can't create invites");

  // --- owner comes back ---
  m1 = await mighty.connect(partyId);
  check(m1.snapshot.chat.some((c) => c.kind === "msg" && c.sender === jonas.key), "owner sees chat that happened while away");
  check(m1.snapshot.chat.filter((c) => c.type === "member.joined").length === 2, "owner sees the join events");
  check((await m1.send("member.role", { key: jonas.key, role: "admin" })).ok, "owner makes Jonas admin");
  check(!!(await ec.waitFor((x) => x.t === "member.role" && x.key === jonas.key && x.role === "admin")), "Emil sees the role change");

  // --- hosting and passes ---
  const badHost = await jc.send("host.start", { game: "minecraft-java", gate: "not an address" });
  check(!badHost.ok, "bad gate address rejected");
  const host = await jc.send("host.start", { game: "minecraft-java", label: "Jonas's world", gate: "abc-def.gl.joinmc.link:12345" });
  check(host.ok, "Jonas starts hosting");
  const started = await ec.waitFor((x) => x.t === "host.started");
  check(started.host.key === jonas.key && started.host.game === "minecraft-java", "Emil sees host.started");
  check(!!(await ec.waitFor((x) => x.t === "chat" && x.msg.type === "host.started")), "a host.started chat event is posted");

  const passReply = await ec.send("pass.request", { host: jonas.key });
  check(passReply.ok && passReply.data.gate === "abc-def.gl.joinmc.link:12345", "Emil gets a pass for Jonas's server");
  const v = verifyPass(passReply.data.pass, sk1);
  check(v.ok && v.payload.member === emil.key && v.payload.host === jonas.key && v.payload.party === partyId, "pass verifies with the service key");
  check(v.payload.exp > Date.now() && v.payload.exp - Date.now() <= 10 * 60 * 1000, "pass expires within 10 minutes");
  const [p, s] = passReply.data.pass.split(".");
  const forged = Buffer.from(JSON.stringify({ ...v.payload, member: sara.key })).toString("base64url") + "." + s;
  check(!verifyPass(forged, sk1).ok, "a tampered pass does not verify");
  check(!(await ec.send("pass.request", { host: emil.key })).ok, "no pass for someone who isn't hosting");

  // --- outsiders ---
  const outsider = await connectFails(sara, partyId);
  check(outsider && outsider.includes("4003"), "non-member can't connect");
  const badInvite = await sara.join("ZZZZ-ZZZZ");
  check(badInvite.status === 404, "unknown invite code is rejected");

  // --- invite limits, revoking and passwords ---
  const once = await m1.send("invite.create", { hours: 1, maxUses: 1 });
  check((await sara.join(once.data.invite.code)).status === 200, "Sara joins with a one-use invite");
  const used = await oliver.join(once.data.invite.code);
  check(used.status === 404 && used.data.error === "invite_used_up", "one-use invite can't be used twice");
  check((await m1.send("invite.revoke", { code })).ok, "owner revokes the first invite");
  const revoked = await oliver.join(code);
  check(revoked.status === 404, "revoked invite no longer works");

  check((await m1.send("party.settings", { password: "hunter2" })).ok, "owner sets a party password");
  const pwInv = await m1.send("invite.create", { hours: 1 });
  const noPw = await oliver.join(pwInv.data.invite.code);
  check(noPw.status === 403 && noPw.data.error === "wrong_password", "joining without the password fails");
  const withPw = await oliver.join(pwInv.data.invite.code, "hunter2");
  check(withPw.status === 200, "joining with the password works");

  // --- kicking and banning ---
  const sc = await sara.connect(partyId);
  const oc = await oliver.connect(partyId);
  check(!(await ec.send("member.kick", { key: oliver.key })).ok, "members can't kick");
  check(!(await jc.send("member.kick", { key: mighty.key })).ok, "admins can't kick the owner");
  const saraClosed = closedWith(sc, 4001);
  check((await jc.send("member.kick", { key: sara.key })).ok, "admin Jonas kicks Sara");
  check(await saraClosed, "Sara's connection is closed with 'removed'");
  check(!!(await ec.waitFor((x) => x.t === "member.removed" && x.key === sara.key)), "others see Sara removed");
  check((await connectFails(sara, partyId))?.includes("4003"), "Sara can't reconnect after kick");

  const oliverClosed = closedWith(oc, 4001);
  check((await m1.send("member.ban", { key: oliver.key })).ok, "owner bans Oliver");
  check(await oliverClosed, "Oliver is disconnected");
  const inv3 = await m1.send("invite.create", { hours: 1 });
  const banned = await oliver.join(inv3.data.invite.code, "hunter2");
  check(banned.status === 403 && banned.data.error === "banned", "banned member can't rejoin with a new invite");

  // --- rate limit ---
  const replies = await Promise.all(Array.from({ length: 12 }, (_, i) => ec.send("chat", { text: `spam ${i}` })));
  check(replies.filter((r) => !r.ok && r.error === "slow_down").length >= 1, "chat flooding is slowed down");

  // --- host goes offline ---
  jc.close();
  check(!!(await ec.waitFor((x) => x.t === "host.stopped" && x.key === jonas.key && x.reason === "offline")), "host going offline removes the hosted game");
  check(!!(await ec.waitFor((x) => x.t === "presence" && x.key === jonas.key && !x.online)), "Jonas shows as offline");

  // --- ownership ---
  check((await m1.send("owner.transfer", { key: emil.key })).ok, "owner hands ownership to Emil");
  check(!!(await ec.waitFor((x) => x.t === "member.role" && x.key === emil.key && x.role === "owner")), "Emil becomes owner");
  const mClosed = closedWith(m1, 4000);
  check((await m1.send("party.leave")).ok, "Mighty leaves the party");
  check(await mClosed, "Mighty's connection closes after leaving");
  check(!!(await ec.waitFor((x) => x.t === "member.left" && x.key === mighty.key)), "Emil sees Mighty leave");

  // --- last members leave: party is deleted ---
  const jc2 = await jonas.connect(partyId);
  check((await jc2.send("party.leave")).ok, "Jonas leaves");
  const del = await ec.send("party.leave");
  check(del.ok && del.data.deleted, "last member leaving deletes the party");
  await sleep(300);
  const gone = await fetch(`${BASE}/invites/${inv3.data.invite.code}`);
  check(gone.status === 404, "invites of a deleted party stop working");
  check((await connectFails(emil, partyId)) !== null, "a deleted party can't be connected to");

  for (const c of [ec, oc, sc]) c.close();
  console.log(failures ? `\n${failures} FAILED` : "\nALL PASSED");
  process.exit(failures ? 1 : 0);
}

main().catch((err) => {
  console.error("CRASH", err);
  process.exit(1);
});
