// PartyPort core: the background part of PartyPort that holds the device
// identity, keeps live connections to the party service and (later) runs the
// gate, the LAN bridge and the playit agent. The LÖVE UI controls it over a
// local connection; see control.go.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const version = "0.1.0"

const defaultService = "https://partyport-service.drgamingdk.workers.dev"

type controlFile struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	PID     int    `json:"pid"`
	Version string `json:"version"`
}

func defaultDataDir() string {
	if d := os.Getenv("PARTYPORT_DATA"); d != "" {
		return d
	}
	base, err := os.UserConfigDir()
	if err != nil {
		base = "."
	}
	return filepath.Join(base, "PartyPort")
}

func main() {
	dataDir := flag.String("data", defaultDataDir(), "folder for identity, parties and logs")
	service := flag.String("service", envOr("PARTYPORT_SERVICE", defaultService), "party service URL")
	port := flag.Int("port", 0, "control port on 127.0.0.1 (0 = pick a free one)")
	flag.Parse()

	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "can't create data folder:", err)
		os.Exit(1)
	}
	logFile, err := os.OpenFile(filepath.Join(*dataDir, "core.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		log.SetOutput(io.MultiWriter(os.Stderr, logFile))
	}

	ctlPath := filepath.Join(*dataDir, "control.json")
	if alreadyRunning(ctlPath) {
		log.Println("core is already running; exiting")
		return
	}

	id, err := loadIdentity(*dataDir)
	if err != nil {
		log.Fatalln("identity:", err)
	}
	svc := newService(*service, id)
	m := newManager(*dataDir, id, svc)

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		log.Fatalln("control port:", err)
	}
	tok := make([]byte, 24)
	_, _ = rand.Read(tok)
	ctl := controlFile{Port: ln.Addr().(*net.TCPAddr).Port, Token: b64.EncodeToString(tok), PID: os.Getpid(), Version: version}
	data, _ := json.MarshalIndent(ctl, "", "  ")
	if err := writeFileAtomic(ctlPath, data, 0o600); err != nil {
		log.Fatalln("control.json:", err)
	}

	done := make(chan struct{})
	quit := func() {
		select {
		case <-done:
		default:
			close(done)
		}
	}
	srv := &controlServer{m: m, token: ctl.Token, quit: quit}
	go srv.serve(ln)
	m.startAll()
	log.Printf("PartyPort core %s ready on 127.0.0.1:%d (data %s, service %s)", version, ctl.Port, *dataDir, *service)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case <-sig:
	case <-done:
	}
	ln.Close()
	m.SetOnline(false) // closes party connections cleanly
	time.Sleep(1500 * time.Millisecond)
	// Only remove control.json if it is still ours.
	if cur, err := readControl(ctlPath); err == nil && cur.PID == os.Getpid() {
		os.Remove(ctlPath)
	}
	log.Println("core stopped")
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func readControl(path string) (*controlFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c controlFile
	return &c, json.Unmarshal(data, &c)
}

// alreadyRunning reports whether another core answers on the port in control.json.
func alreadyRunning(path string) bool {
	c, err := readControl(path)
	if err != nil || c.Port == 0 {
		return false
	}
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", c.Port), 500*time.Millisecond)
	if err != nil {
		return false
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	hello, _ := json.Marshal(map[string]any{"op": "hello", "token": c.Token, "id": 0})
	conn.Write(append(hello, '\n'))
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return false
	}
	var r struct {
		OK bool `json:"ok"`
	}
	_ = json.Unmarshal(line, &r)
	return r.OK
}
