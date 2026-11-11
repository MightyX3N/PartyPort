package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const chatKeep = 200 // messages kept in memory per party for the UI

type Member struct {
	Key      string `json:"key"`
	Name     string `json:"name"`
	Role     string `json:"role"`
	JoinedAt int64  `json:"joinedAt"`
	LastSeen int64  `json:"lastSeen"`
	Online   bool   `json:"online"`
}

type Host struct {
	Key       string  `json:"key"`
	Game      string  `json:"game"`
	Label     string  `json:"label"`
	Gate      string  `json:"gate"`
	Direct    *string `json:"direct"`
	Players   int     `json:"players"`
	StartedAt int64   `json:"startedAt"`
}

// PartyState is everything the UI needs to draw one party.
type PartyState struct {
	ID      string           `json:"id"`
	Name    string           `json:"name"`
	Status  string           `json:"status"` // connecting, online, offline, error
	Error   string           `json:"error,omitempty"`
	Role    string           `json:"role"`
	Info    *PartyInfo       `json:"info,omitempty"`
	Members []Member         `json:"members"`
	Hosts   []Host           `json:"hosts"`
	Chat    []map[string]any `json:"chat"`
	Invites []map[string]any `json:"invites,omitempty"`
}

type wsReply struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error string          `json:"error"`
}

// PartyConn keeps one live connection to one party and mirrors its state.
type PartyConn struct {
	m      *Manager
	id     string
	mu     sync.Mutex
	st     PartyState
	ws     *websocket.Conn
	nextID int
	wait   map[int]chan wsReply
	cancel context.CancelFunc
}

func newPartyConn(m *Manager, id, name string) *PartyConn {
	return &PartyConn{
		m:    m,
		id:   id,
		wait: map[int]chan wsReply{},
		st:   PartyState{ID: id, Name: name, Status: "offline", Members: []Member{}, Hosts: []Host{}, Chat: []map[string]any{}},
	}
}

func (p *PartyConn) snapshot() PartyState {
	p.mu.Lock()
	defer p.mu.Unlock()
	s := p.st
	s.Members = append([]Member(nil), p.st.Members...)
	s.Hosts = append([]Host(nil), p.st.Hosts...)
	s.Chat = append([]map[string]any(nil), p.st.Chat...)
	s.Invites = append([]map[string]any(nil), p.st.Invites...)
	return s
}

func (p *PartyConn) setStatus(status, errMsg string) {
	p.mu.Lock()
	p.st.Status = status
	p.st.Error = errMsg
	if status == "offline" || status == "error" {
		// Disconnected: we no longer know who is online.
		for i := range p.st.Members {
			p.st.Members[i].Online = false
		}
	}
	p.mu.Unlock()
	p.m.changed()
}

// start connects and keeps reconnecting until stop is called.
func (p *PartyConn) start() {
	ctx, cancel := context.WithCancel(context.Background())
	p.mu.Lock()
	if p.cancel != nil {
		p.mu.Unlock()
		cancel()
		return
	}
	p.cancel = cancel
	p.mu.Unlock()
	go p.loop(ctx)
}

func (p *PartyConn) stop() {
	p.mu.Lock()
	cancel := p.cancel
	p.cancel = nil
	p.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	p.setStatus("offline", "")
}

func (p *PartyConn) loop(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		p.setStatus("connecting", "")
		started := time.Now()
		closeCode, err := p.session(ctx)
		if ctx.Err() != nil {
			return
		}
		switch closeCode {
		case 4000, 4001, 4003, 4004:
			// Left, removed, no longer a member, or party deleted: stop for good.
			reason := map[websocket.StatusCode]string{4000: "left", 4001: "removed", 4003: "not_a_member", 4004: "deleted"}[closeCode]
			p.m.partyGone(p.id, reason)
			return
		}
		msg := "connection lost"
		if err != nil {
			msg = err.Error()
		}
		p.setStatus("error", msg)
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// session runs one WebSocket connection until it closes.
func (p *PartyConn) session(ctx context.Context) (websocket.StatusCode, error) {
	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	ws, res, err := websocket.Dial(dialCtx, p.m.svc.wsURL(p.id), nil)
	cancel()
	if err != nil {
		if res != nil && res.StatusCode == 404 {
			return 4004, errors.New("party not found")
		}
		return 0, fmt.Errorf("can't connect: %w", err)
	}
	ws.SetReadLimit(1 << 20)
	defer ws.CloseNow()
	// When we're told to stop (quit, go offline, leave), say goodbye properly
	// so others see us go offline right away. Reads use their own context:
	// cancelling a read context would drop the connection without a goodbye.
	sessionDone := make(chan struct{})
	defer close(sessionDone)
	go func() {
		select {
		case <-ctx.Done():
			ws.Close(websocket.StatusNormalClosure, "bye")
		case <-sessionDone:
		}
	}()
	readCtx := context.Background()

	// Keep-alive so the service can tell a live connection from a dead one.
	pingCtx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-pingCtx.Done():
				return
			case <-t.C:
				wctx, cancel := context.WithTimeout(pingCtx, 10*time.Second)
				_ = ws.Write(wctx, websocket.MessageText, []byte("ping"))
				cancel()
			}
		}
	}()

	for {
		_, data, err := ws.Read(readCtx)
		if err != nil {
			code := websocket.CloseStatus(err)
			p.mu.Lock()
			p.ws = nil
			for id, ch := range p.wait {
				close(ch)
				delete(p.wait, id)
			}
			p.mu.Unlock()
			return code, err
		}
		var msg map[string]json.RawMessage
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		var t string
		_ = json.Unmarshal(msg["t"], &t)
		switch t {
		case "challenge":
			var c struct{ Nonce, Party string }
			_ = json.Unmarshal(data, &c)
			auth, _ := json.Marshal(map[string]string{
				"t":    "auth",
				"sig":  p.m.id.Sign([]byte("pp-ws\n" + c.Party + "\n" + c.Nonce)),
				"name": p.m.id.GetName(),
			})
			if err := ws.Write(ctx, websocket.MessageText, auth); err != nil {
				return 0, err
			}
		case "snapshot":
			p.applySnapshot(data)
			p.mu.Lock()
			p.ws = ws
			p.mu.Unlock()
		case "reply":
			var r struct {
				ID int `json:"id"`
				wsReply
			}
			_ = json.Unmarshal(data, &r)
			p.mu.Lock()
			ch := p.wait[r.ID]
			delete(p.wait, r.ID)
			p.mu.Unlock()
			if ch != nil {
				ch <- r.wsReply
			}
		default:
			p.applyEvent(t, data)
		}
	}
}

func (p *PartyConn) applySnapshot(data []byte) {
	var s struct {
		You     struct{ Key, Role string }
		Party   PartyInfo
		Members []Member
		Hosts   []Host
		Chat    []map[string]any
		Invites []map[string]any
	}
	if err := json.Unmarshal(data, &s); err != nil {
		log.Println("bad snapshot:", err)
		return
	}
	p.mu.Lock()
	p.st.Status = "online"
	p.st.Error = ""
	p.st.Role = s.You.Role
	p.st.Info = &s.Party
	p.st.Name = s.Party.Name
	p.st.Members = nonNil(s.Members)
	p.st.Hosts = nonNil(s.Hosts)
	p.st.Chat = nonNil(s.Chat)
	p.st.Invites = s.Invites
	p.mu.Unlock()
	p.m.renameStored(p.id, s.Party.Name)
	p.m.changed()
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func (p *PartyConn) applyEvent(t string, data []byte) {
	var e struct {
		Key     string         `json:"key"`
		Online  bool           `json:"online"`
		Role    string         `json:"role"`
		Member  Member         `json:"member"`
		Host    Host           `json:"host"`
		Party   PartyInfo      `json:"party"`
		Msg     map[string]any `json:"msg"`
		Invite  map[string]any `json:"invite"`
		Code    string         `json:"code"`
	}
	if json.Unmarshal(data, &e) != nil {
		return
	}
	p.mu.Lock()
	switch t {
	case "presence":
		for i := range p.st.Members {
			if p.st.Members[i].Key == e.Key {
				p.st.Members[i].Online = e.Online
				p.st.Members[i].LastSeen = time.Now().UnixMilli()
			}
		}
	case "member.joined":
		p.st.Members = append(removeMember(p.st.Members, e.Member.Key), e.Member)
	case "member.updated":
		for i := range p.st.Members {
			if p.st.Members[i].Key == e.Member.Key {
				p.st.Members[i] = e.Member
			}
		}
	case "member.left", "member.removed":
		p.st.Members = removeMember(p.st.Members, e.Key)
	case "member.role":
		for i := range p.st.Members {
			if p.st.Members[i].Key == e.Key {
				p.st.Members[i].Role = e.Role
			}
		}
		if e.Key == p.m.id.Key {
			p.st.Role = e.Role
		}
	case "party.updated":
		info := e.Party
		p.st.Info = &info
		p.st.Name = info.Name
	case "host.started", "host.updated":
		p.st.Hosts = append(removeHost(p.st.Hosts, e.Host.Key), e.Host)
	case "host.stopped":
		p.st.Hosts = removeHost(p.st.Hosts, e.Key)
	case "invite.created":
		p.st.Invites = append([]map[string]any{e.Invite}, p.st.Invites...)
	case "invite.revoked":
		out := p.st.Invites[:0]
		for _, inv := range p.st.Invites {
			if inv["code"] != e.Code {
				out = append(out, inv)
			}
		}
		p.st.Invites = out
	case "chat":
		p.st.Chat = append(p.st.Chat, e.Msg)
		if len(p.st.Chat) > chatKeep {
			p.st.Chat = p.st.Chat[len(p.st.Chat)-chatKeep:]
		}
	}
	name := p.st.Name
	p.mu.Unlock()
	if t == "party.updated" {
		p.m.renameStored(p.id, name)
	}
	if t == "chat" {
		p.m.emit(map[string]any{"ev": "chat", "party": p.id, "msg": e.Msg})
	}
	p.m.changed()
}

func removeMember(ms []Member, key string) []Member {
	out := make([]Member, 0, len(ms))
	for _, m := range ms {
		if m.Key != key {
			out = append(out, m)
		}
	}
	return out
}

func removeHost(hs []Host, key string) []Host {
	out := make([]Host, 0, len(hs))
	for _, h := range hs {
		if h.Key != key {
			out = append(out, h)
		}
	}
	return out
}

// Request sends an operation to the party and waits for its reply.
func (p *PartyConn) Request(ctx context.Context, t string, fields map[string]any) (json.RawMessage, error) {
	p.mu.Lock()
	ws := p.ws
	if ws == nil {
		p.mu.Unlock()
		return nil, errors.New("not_connected")
	}
	p.nextID++
	id := p.nextID
	ch := make(chan wsReply, 1)
	p.wait[id] = ch
	p.mu.Unlock()

	msg := map[string]any{}
	for k, v := range fields {
		msg[k] = v
	}
	msg["t"] = t
	msg["id"] = id
	data, _ := json.Marshal(msg)
	if err := ws.Write(ctx, websocket.MessageText, data); err != nil {
		return nil, errors.New("not_connected")
	}
	select {
	case r, ok := <-ch:
		if !ok {
			return nil, errors.New("not_connected")
		}
		if !r.OK {
			return nil, errors.New(r.Error)
		}
		return r.Data, nil
	case <-time.After(15 * time.Second):
		p.mu.Lock()
		delete(p.wait, id)
		p.mu.Unlock()
		return nil, errors.New("timeout")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
