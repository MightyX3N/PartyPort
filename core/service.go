package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Service talks to the party service over HTTPS. Every write request is
// signed with the device key (see service/README.md).
type Service struct {
	base string
	id   *Identity
	http *http.Client
}

// APIError is an error response from the service, e.g. "invite_expired".
type APIError struct {
	Status int
	Code   string
}

func (e *APIError) Error() string { return e.Code }

func newService(base string, id *Identity) *Service {
	return &Service{base: strings.TrimRight(base, "/"), id: id, http: &http.Client{Timeout: 20 * time.Second}}
}

func (s *Service) do(ctx context.Context, method, path string, body any, signed bool, out any) error {
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, s.base+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	if signed {
		ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
		sum := sha256.Sum256(raw)
		// The service signs over the URL path exactly as sent.
		u, _ := url.Parse(s.base + path)
		msg := fmt.Sprintf("%s\n%s\n%s\n%s", method, u.EscapedPath(), ts, hex.EncodeToString(sum[:]))
		req.Header.Set("x-pp-key", s.id.Key)
		req.Header.Set("x-pp-time", ts)
		req.Header.Set("x-pp-sig", s.id.Sign([]byte(msg)))
	}
	res, err := s.http.Do(req)
	if err != nil {
		return fmt.Errorf("can't reach the PartyPort service: %w", err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 300 {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		if e.Error == "" {
			e.Error = fmt.Sprintf("http_%d", res.StatusCode)
		}
		return &APIError{Status: res.StatusCode, Code: e.Error}
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}

type PartyInfo struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	CreatedAt   int64  `json:"createdAt"`
	HasPassword bool   `json:"hasPassword"`
	MaxMembers  int    `json:"maxMembers"`
}

func (s *Service) CreateParty(ctx context.Context, name string) (*PartyInfo, error) {
	var out struct {
		Party PartyInfo `json:"party"`
	}
	err := s.do(ctx, "POST", "/parties", map[string]string{"name": name, "displayName": s.id.GetName()}, true, &out)
	if err != nil {
		return nil, err
	}
	return &out.Party, nil
}

type InvitePreview struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Members     int    `json:"members"`
	HasPassword bool   `json:"hasPassword"`
}

func (s *Service) PreviewInvite(ctx context.Context, code string) (*InvitePreview, error) {
	var out InvitePreview
	err := s.do(ctx, "GET", "/invites/"+url.PathEscape(code), nil, false, &out)
	return &out, err
}

type JoinResult struct {
	PartyID string `json:"partyId"`
	Name    string `json:"name"`
}

func (s *Service) JoinParty(ctx context.Context, code, password string) (*JoinResult, error) {
	body := map[string]any{"displayName": s.id.GetName()}
	if password != "" {
		body["password"] = password
	}
	var out JoinResult
	err := s.do(ctx, "POST", "/invites/"+url.PathEscape(code)+"/join", body, true, &out)
	return &out, err
}

func (s *Service) wsURL(partyID string) string {
	u := s.base
	u = strings.Replace(u, "https://", "wss://", 1)
	u = strings.Replace(u, "http://", "ws://", 1)
	return fmt.Sprintf("%s/parties/%s/ws?key=%s", u, partyID, s.id.Key)
}
