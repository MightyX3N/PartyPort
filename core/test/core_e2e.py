"""End-to-end test of two PartyPort cores (two users) against a party service.

Usage: python3 core/test/core_e2e.py <path to core binary>
Env:   PARTYPORT_SERVICE (default: the live service)
"""
import json, os, socket, subprocess, sys, tempfile, time, threading

CORE = sys.argv[1]
failures = 0


def check(cond, msg):
    global failures
    print(("PASS " if cond else "FAIL ") + msg, flush=True)
    if not cond:
        failures += 1


class Core:
    def __init__(self, name, data=None):
        self.name = name
        self.data = data or tempfile.mkdtemp(prefix=f"pp-{name}-")
        self.start()

    def start(self):
        self.proc = subprocess.Popen([CORE, "-data", self.data], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ctl = os.path.join(self.data, "control.json")
        for _ in range(100):
            if os.path.exists(ctl):
                break
            time.sleep(0.05)
        time.sleep(0.1)
        c = json.load(open(ctl))
        self.sock = socket.create_connection(("127.0.0.1", c["port"]))
        self.f = self.sock.makefile("rwb")
        self.events, self.replies, self.state = [], {}, None
        self.lock = threading.Condition()
        self.next = 1
        threading.Thread(target=self.reader, daemon=True).start()
        r = self.call("hello", token=c["token"])
        assert r["ok"], r

    def reader(self):
        for line in self.f:
            msg = json.loads(line)
            with self.lock:
                if "ev" in msg:
                    if msg["ev"] == "state":
                        self.state = msg
                    self.events.append(msg)
                else:
                    self.replies[msg["id"]] = msg
                self.lock.notify_all()

    def call(self, op, **kw):
        with self.lock:
            i = self.next
            self.next += 1
        self.f.write((json.dumps({"id": i, "op": op, **kw}) + "\n").encode())
        self.f.flush()
        with self.lock:
            self.lock.wait_for(lambda: i in self.replies, timeout=30)
            return self.replies.pop(i, {"ok": False, "error": "no reply"})

    def wait(self, pred, timeout=15):
        with self.lock:
            return self.lock.wait_for(lambda: pred(self), timeout=timeout)

    def party(self, pid):
        if not self.state:
            return None
        return next((p for p in self.state["parties"] if p["id"] == pid), None)

    def stop(self):
        try:
            self.call("quit")
        except Exception:
            pass
        self.proc.wait(timeout=5)


def main():
    a = Core("mighty")
    b = Core("jonas")

    check(a.wait(lambda c: c.state is not None), "UI gets a state right after hello")
    check(a.state["name"] == "" and len(a.state["key"]) == 43, "new install has a key and no name yet")
    r = a.call("createParty", name="Friday Gaming")
    check(not r["ok"] and r["error"] == "set_name_first", "can't create a party before choosing a name")

    check(a.call("setName", name="  Mighty  ")["data"]["name"] == "Mighty", "name is saved (trimmed)")
    b.call("setName", name="Jonas")

    r = a.call("createParty", name="Friday Gaming")
    check(r["ok"], "Mighty starts a party")
    pid = r["data"]["id"]
    check(a.wait(lambda c: (c.party(pid) or {}).get("status") == "online"), "core connects to the new party")
    check(a.party(pid)["role"] == "owner", "Mighty is owner")

    inv = a.call("partyOp", party=pid, t="invite.create", data={"hours": 24})
    check(inv["ok"], "Mighty creates an invite through the core")
    code = inv["data"]["invite"]["code"]

    pv = b.call("previewInvite", code=code)
    check(pv["ok"] and pv["data"]["name"] == "Friday Gaming", "Jonas previews the invite")
    bad = b.call("joinParty", code="ZZZZ-ZZZZ")
    check(not bad["ok"] and bad["error"] == "invite_not_found", "a wrong code gives a clear error")
    j = b.call("joinParty", code=code)
    check(j["ok"] and j["data"]["partyId"] == pid, "Jonas joins with the invite")
    check(b.wait(lambda c: (c.party(pid) or {}).get("status") == "online"), "Jonas's core connects")
    check(a.wait(lambda c: any(m["name"] == "Jonas" and m["online"] for m in (c.party(pid) or {}).get("members", []))),
          "Mighty sees Jonas online")

    check(b.call("partyOp", party=pid, t="chat", data={"text": "hey!"})["ok"], "Jonas sends a message")
    check(a.wait(lambda c: any(e.get("ev") == "chat" and e["msg"].get("text") == "hey!" for e in c.events)),
          "Mighty's UI gets a chat event")
    check(a.wait(lambda c: any(m.get("text") == "hey!" for m in c.party(pid)["chat"])), "message is in Mighty's party state")

    # Core restart keeps identity and parties
    key_before = a.state["key"]
    a.stop()
    check(b.wait(lambda c: any(m["name"] == "Mighty" and not m["online"] for m in c.party(pid)["members"])),
          "Jonas sees Mighty go offline when Mighty's core stops")
    a = Core("mighty", data=a.data)
    check(a.wait(lambda c: c.state is not None and c.state["key"] == key_before), "same key after restart")
    check(a.wait(lambda c: (c.party(pid) or {}).get("status") == "online"), "party reconnects after restart")
    check(any(m.get("text") == "hey!" for m in a.party(pid)["chat"]), "chat history is back after restart")

    # Going offline and back
    a.call("setOnline", online=False)
    check(a.wait(lambda c: c.party(pid)["status"] == "offline" and not c.state["online"]), "power button: offline")
    a.call("setOnline", online=True)
    check(a.wait(lambda c: c.party(pid)["status"] == "online"), "power button: back online")

    # Renaming shows up for others
    a.call("setName", name="MightyX")
    check(b.wait(lambda c: any(m["name"] == "MightyX" for m in c.party(pid)["members"])), "rename reaches other members")

    # Kicked: party disappears from the kicked user's list with a reason
    check(a.call("partyOp", party=pid, t="member.kick", data={"key": b.state["key"]})["ok"], "Mighty kicks Jonas")
    check(b.wait(lambda c: any(e.get("ev") == "party.gone" and e["reason"] == "removed" for e in c.events)),
          "Jonas's UI is told he was removed")
    check(b.wait(lambda c: c.party(pid) is None), "party is gone from Jonas's list")
    check(not os.path.exists(os.path.join(b.data, "parties.json")) or pid not in open(os.path.join(b.data, "parties.json")).read(),
          "and from Jonas's saved parties")

    # Leaving (last member) deletes the party
    lv = a.call("leaveParty", party=pid)
    check(lv["ok"] and a.wait(lambda c: c.party(pid) is None), "Mighty leaves; party removed from the list")

    # Wrong token is refused
    c = json.load(open(os.path.join(a.data, "control.json")))
    s = socket.create_connection(("127.0.0.1", c["port"]))
    s.sendall(b'{"id":1,"op":"hello","token":"nope"}\n')
    resp = json.loads(s.makefile().readline())
    check(not resp["ok"] and resp["error"] == "bad_token", "control port refuses a wrong token")

    # Second core in the same folder refuses to start
    p2 = subprocess.run([CORE, "-data", a.data], capture_output=True, timeout=10)
    check(p2.returncode == 0 and b"already running" in p2.stderr, "a second core in the same folder exits")

    a.stop()
    b.stop()
    print("\nALL PASSED" if not failures else f"\n{failures} FAILED")
    sys.exit(1 if failures else 0)


main()
