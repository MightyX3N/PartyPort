package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net"
	"time"
)

// The UI talks to the core over a local TCP connection using one JSON object
// per line. The first line must be {"op":"hello","token":...} with the token
// from control.json, so other programs on the machine can't drive the core.
//
// Requests:  {"id": 1, "op": "...", ...}
// Replies:   {"id": 1, "ok": true, "data": ...} or {"id": 1, "ok": false, "error": "..."}
// Events:    {"ev": "state" | "chat" | "party.gone", ...}

type client struct {
	out  chan []byte
	conn net.Conn
}

func (c *client) send(data []byte) {
	select {
	case c.out <- data:
	default:
		// UI isn't reading; drop it rather than block the core.
		c.conn.Close()
	}
}

type controlServer struct {
	m     *Manager
	token string
	quit  func()
}

func (s *controlServer) serve(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

func (s *controlServer) handle(conn net.Conn) {
	c := &client{out: make(chan []byte, 256), conn: conn}
	written := make(chan struct{})
	go func() {
		defer close(written)
		w := bufio.NewWriter(conn)
		for data := range c.out {
			w.Write(data)
			w.WriteByte('\n')
			if len(c.out) == 0 {
				if w.Flush() != nil {
					return
				}
			}
		}
		w.Flush()
	}()
	// On exit: stop accepting output, let pending lines go out, then close.
	defer func() {
		close(c.out)
		select {
		case <-written:
		case <-time.After(2 * time.Second):
		}
		conn.Close()
	}()

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	authed := false
	for sc.Scan() {
		var req map[string]any
		if json.Unmarshal(sc.Bytes(), &req) != nil {
			continue
		}
		op, _ := req["op"].(string)
		id := req["id"]
		reply := func(data any, err error) {
			var msg map[string]any
			if err != nil {
				msg = map[string]any{"id": id, "ok": false, "error": err.Error()}
			} else {
				msg = map[string]any{"id": id, "ok": true, "data": data}
			}
			b, _ := json.Marshal(msg)
			c.send(b)
		}
		if !authed {
			tok, _ := req["token"].(string)
			if op != "hello" || subtle.ConstantTimeCompare([]byte(tok), []byte(s.token)) != 1 {
				reply(nil, errors.New("bad_token"))
				return
			}
			authed = true
			s.m.clientsMu.Lock()
			s.m.clients[c] = true
			s.m.clientsMu.Unlock()
			defer func() {
				s.m.clientsMu.Lock()
				delete(s.m.clients, c)
				s.m.clientsMu.Unlock()
			}()
			reply(map[string]any{"version": version, "key": s.m.id.Key}, nil)
			st, _ := json.Marshal(s.m.State())
			c.send(st)
			continue
		}
		go func() {
			data, err := s.do(op, req)
			reply(data, err)
		}()
	}
}

func str(req map[string]any, k string) string {
	v, _ := req[k].(string)
	return v
}

func (s *controlServer) do(op string, req map[string]any) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	m := s.m
	switch op {
	case "state":
		return m.State(), nil

	case "setName":
		name := cleanName(str(req, "name"), 32)
		if name == "" {
			return nil, errors.New("bad_name")
		}
		if err := m.id.SetName(name); err != nil {
			return nil, err
		}
		m.mu.Lock()
		conns := []*PartyConn{}
		for _, p := range m.parties {
			conns = append(conns, p)
		}
		m.mu.Unlock()
		for _, p := range conns {
			_, _ = p.Request(ctx, "me.rename", map[string]any{"name": name})
		}
		m.changed()
		return map[string]any{"name": name}, nil

	case "setOnline":
		on, _ := req["online"].(bool)
		m.SetOnline(on)
		return map[string]any{"online": on}, nil

	case "createParty":
		if m.id.GetName() == "" {
			return nil, errors.New("set_name_first")
		}
		name := cleanName(str(req, "name"), 40)
		if name == "" {
			return nil, errors.New("bad_name")
		}
		info, err := m.svc.CreateParty(ctx, name)
		if err != nil {
			return nil, err
		}
		m.addParty(info.ID, info.Name)
		return info, nil

	case "previewInvite":
		return m.svc.PreviewInvite(ctx, str(req, "code"))

	case "joinParty":
		if m.id.GetName() == "" {
			return nil, errors.New("set_name_first")
		}
		res, err := m.svc.JoinParty(ctx, str(req, "code"), str(req, "password"))
		if err != nil {
			return nil, err
		}
		m.addParty(res.PartyID, res.Name)
		return res, nil

	case "leaveParty":
		pid := str(req, "party")
		p := m.party(pid)
		if p == nil {
			return nil, errors.New("not_found")
		}
		if _, err := p.Request(ctx, "party.leave", nil); err != nil && err.Error() != "not_connected" {
			return nil, err
		}
		m.removeParty(pid)
		return map[string]any{"left": true}, nil

	case "partyOp":
		p := m.party(str(req, "party"))
		if p == nil {
			return nil, errors.New("not_found")
		}
		fields, _ := req["data"].(map[string]any)
		raw, err := p.Request(ctx, str(req, "t"), fields)
		if err != nil {
			return nil, err
		}
		var out any
		_ = json.Unmarshal(raw, &out)
		return out, nil

	case "quit":
		log.Println("quit requested by UI")
		go func() {
			time.Sleep(100 * time.Millisecond)
			s.quit()
		}()
		return map[string]any{"bye": true}, nil
	}
	return nil, errors.New("unknown_op")
}
