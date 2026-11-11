package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

type storedParty struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	AddedAt int64  `json:"addedAt"`
}

// Manager owns the identity, the list of parties and their connections,
// and pushes state changes to every connected UI.
type Manager struct {
	dir string
	id  *Identity
	svc *Service

	mu      sync.Mutex
	online  bool
	stored  map[string]storedParty
	parties map[string]*PartyConn

	clientsMu sync.Mutex
	clients   map[*client]bool

	dirty chan struct{}
}

func newManager(dir string, id *Identity, svc *Service) *Manager {
	m := &Manager{
		dir:     dir,
		id:      id,
		svc:     svc,
		online:  true,
		stored:  map[string]storedParty{},
		parties: map[string]*PartyConn{},
		clients: map[*client]bool{},
		dirty:   make(chan struct{}, 1),
	}
	m.loadStore()
	go m.pump()
	return m
}

func (m *Manager) storePath() string { return filepath.Join(m.dir, "parties.json") }

func (m *Manager) loadStore() {
	data, err := os.ReadFile(m.storePath())
	if err != nil {
		return
	}
	var list []storedParty
	if json.Unmarshal(data, &list) != nil {
		return
	}
	for _, p := range list {
		m.stored[p.ID] = p
		m.parties[p.ID] = newPartyConn(m, p.ID, p.Name)
	}
}

// saveStore must be called with m.mu held.
func (m *Manager) saveStore() {
	list := make([]storedParty, 0, len(m.stored))
	for _, p := range m.stored {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].AddedAt < list[j].AddedAt })
	data, _ := json.MarshalIndent(list, "", "  ")
	_ = writeFileAtomic(m.storePath(), data, 0o600)
}

func (m *Manager) startAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.online {
		return
	}
	for _, p := range m.parties {
		p.start()
	}
}

func (m *Manager) SetOnline(on bool) {
	m.mu.Lock()
	m.online = on
	conns := make([]*PartyConn, 0, len(m.parties))
	for _, p := range m.parties {
		conns = append(conns, p)
	}
	m.mu.Unlock()
	for _, p := range conns {
		if on {
			p.start()
		} else {
			p.stop()
		}
	}
	m.changed()
}

func (m *Manager) Online() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.online
}

func (m *Manager) addParty(id, name string) *PartyConn {
	m.mu.Lock()
	p, ok := m.parties[id]
	if !ok {
		p = newPartyConn(m, id, name)
		m.parties[id] = p
		m.stored[id] = storedParty{ID: id, Name: name, AddedAt: time.Now().UnixMilli()}
		m.saveStore()
	}
	online := m.online
	m.mu.Unlock()
	if online {
		p.start()
	}
	m.changed()
	return p
}

func (m *Manager) party(id string) *PartyConn {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.parties[id]
}

func (m *Manager) removeParty(id string) (storedParty, bool) {
	m.mu.Lock()
	p := m.parties[id]
	sp, ok := m.stored[id]
	delete(m.parties, id)
	delete(m.stored, id)
	m.saveStore()
	m.mu.Unlock()
	if p != nil {
		p.stop()
	}
	m.changed()
	return sp, ok
}

// partyGone is called when the service says we are no longer in a party.
func (m *Manager) partyGone(id, reason string) {
	sp, ok := m.removeParty(id)
	if ok {
		m.emit(map[string]any{"ev": "party.gone", "party": id, "name": sp.Name, "reason": reason})
	}
}

func (m *Manager) renameStored(id, name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if sp, ok := m.stored[id]; ok && sp.Name != name && name != "" {
		sp.Name = name
		m.stored[id] = sp
		m.saveStore()
	}
}

type fullState struct {
	Ev       string       `json:"ev"`
	Key      string       `json:"key"`
	Name     string       `json:"name"`
	Online   bool         `json:"online"`
	Service  string       `json:"service"`
	Parties  []PartyState `json:"parties"`
}

func (m *Manager) State() fullState {
	m.mu.Lock()
	ids := make([]storedParty, 0, len(m.stored))
	for _, sp := range m.stored {
		ids = append(ids, sp)
	}
	conns := m.parties
	online := m.online
	sort.Slice(ids, func(i, j int) bool { return ids[i].AddedAt < ids[j].AddedAt })
	list := make([]*PartyConn, 0, len(ids))
	for _, sp := range ids {
		if c := conns[sp.ID]; c != nil {
			list = append(list, c)
		}
	}
	m.mu.Unlock()
	st := fullState{Ev: "state", Key: m.id.Key, Name: m.id.GetName(), Online: online, Service: m.svc.base, Parties: []PartyState{}}
	for _, c := range list {
		st.Parties = append(st.Parties, c.snapshot())
	}
	return st
}

// changed schedules a state push to the UI (coalesced).
func (m *Manager) changed() {
	select {
	case m.dirty <- struct{}{}:
	default:
	}
}

func (m *Manager) pump() {
	for range m.dirty {
		time.Sleep(30 * time.Millisecond)
		m.emit(m.State())
	}
}

func (m *Manager) emit(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	m.clientsMu.Lock()
	defer m.clientsMu.Unlock()
	for c := range m.clients {
		c.send(data)
	}
}
