package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"sync"
	"time"
)

// turnResult ends a session/prompt call.
type turnResult struct {
	stopReason string
	err        error
}

// turn is a prompt in flight, ended by the run it starts.
type turn struct {
	started   bool
	cancelled bool
	done      chan turnResult
}

// session forwards one Scooter conversation as an ACP session.
type session struct {
	id  string
	c   *client
	out *rpc

	mu         sync.Mutex
	tr         *translator
	held       string // checksum through the last applied event
	applied    int    // events applied, an index into /history
	synced     bool   // a live frame has chained onto held since (re)connecting
	queueEmpty bool
	turn       *turn
	pending    map[string]interrupt // unanswered permission requests, by tool call
	asked      map[string]bool      // permission requests already sent to the client
	prefix     string               // prepended to the first prompt
}

type history struct {
	Events   []json.RawMessage `json:"events"`
	Checksum string            `json:"checksum"`
}

type frame struct {
	Kind         string          `json:"kind"`
	Event        json.RawMessage `json:"event"`
	Checksum     string          `json:"checksum"`
	PrevChecksum string          `json:"prevChecksum"`
}

func newSession(id string, c *client, out *rpc) *session {
	return &session{
		id: id, c: c, out: out, tr: newTranslator(), queueEmpty: true,
		pending: map[string]interrupt{}, asked: map[string]bool{},
	}
}

func (s *session) path(suffix string) string {
	return "/conversations/" + url.PathEscape(s.id) + suffix
}

// load applies history, emitting its updates when send is set.
func (s *session) load(ctx context.Context, send bool) error {
	var h history
	if err := s.c.call(ctx, "GET", s.path("/history"), nil, &h); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applyNew(ctx, h, send)
	return nil
}

// applyNew applies the history events past s.applied. Caller holds mu.
func (s *session) applyNew(ctx context.Context, h history, send bool) {
	for _, raw := range h.Events[min(s.applied, len(h.Events)):] {
		s.applyLocked(ctx, raw, send, true)
	}
	s.applied = len(h.Events)
	s.held = h.Checksum
}

// replayPending raises permission requests left open in history.
func (s *session) replayPending(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, in := range s.pending {
		s.askLocked(ctx, in)
	}
}

// applyLocked forwards an event and drives the turn; holds mu.
func (s *session) applyLocked(ctx context.Context, raw json.RawMessage, send, replay bool) {
	var ev aguiEvent
	if err := json.Unmarshal(raw, &ev); err != nil {
		log.Printf("session %s: bad event: %v", s.id, err)
		return
	}
	updates, sig := s.tr.apply(ev)
	if send {
		for _, u := range updates {
			s.out.notify("session/update", map[string]any{"sessionId": s.id, "update": u})
		}
	}
	switch sig {
	case sigQueue:
		var items []json.RawMessage
		json.Unmarshal(ev.Items, &items)
		s.queueEmpty = len(items) == 0
	case sigResolved:
		delete(s.pending, ev.ToolCallID)
	case sigInterrupt:
		for _, in := range ev.Outcome.Interrupts {
			if len(in.Metadata.Options) == 0 {
				continue
			}
			s.pending[in.ID] = in
			if !replay {
				s.askLocked(ctx, in)
			}
		}
	case sigRunStarted:
		if s.turn != nil {
			s.turn.started = true
		}
	case sigRunEnded:
		if t := s.turn; t != nil && t.started && s.queueEmpty {
			reason := "end_turn"
			if t.cancelled || ev.Cancelled {
				reason = "cancelled"
			}
			s.finishLocked(turnResult{stopReason: reason})
		}
	case sigRunError:
		if t := s.turn; t != nil && t.started && s.queueEmpty {
			s.finishLocked(turnResult{err: errors.New(ev.Message)})
		}
	}
}

func (s *session) finishLocked(r turnResult) {
	s.turn.done <- r
	s.turn = nil
	s.tr.echoUser = true
}

// askLocked sends a permission request to the client; holds mu.
func (s *session) askLocked(ctx context.Context, in interrupt) {
	if s.asked[in.ID] {
		return
	}
	s.asked[in.ID] = true
	toolCallID := in.ToolCallID
	if toolCallID == "" {
		toolCallID = in.ID
	}
	go func() {
		var res struct {
			Outcome struct {
				Outcome  string `json:"outcome"`
				OptionID string `json:"optionId"`
			} `json:"outcome"`
		}
		err := s.out.request(ctx, "session/request_permission", map[string]any{
			"sessionId": s.id,
			"toolCall":  map[string]any{"toolCallId": toolCallID, "title": in.Message},
			"options":   in.Metadata.Options,
		}, &res)
		if err != nil || res.Outcome.Outcome != "selected" {
			return
		}
		err = s.c.call(ctx, "POST", s.path("/permission/"+url.PathEscape(in.ID)), map[string]string{"optionId": res.Outcome.OptionID}, nil)
		if err != nil {
			log.Printf("session %s: answer permission: %v", s.id, err)
		}
	}()
}

// follow tails the integrity stream, resyncing after gaps or drops.
func (s *session) follow(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		err := s.c.stream(ctx, s.path("/events.integrity"), func() {
			backoff = time.Second
			// Catch up on anything appended before the stream went live.
			if err := s.resync(ctx); err != nil {
				log.Printf("session %s: resync: %v", s.id, err)
			}
		}, func(data []byte) { s.onFrame(ctx, data) })
		if ctx.Err() != nil {
			return
		}
		log.Printf("session %s: stream ended: %v; reconnecting in %s", s.id, err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}

func (s *session) resync(ctx context.Context) error {
	var h history
	if err := s.c.call(ctx, "GET", s.path("/history"), nil, &h); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applyNew(ctx, h, true)
	s.synced = false
	return nil
}

func (s *session) onFrame(ctx context.Context, data []byte) {
	var f frame
	if json.Unmarshal(data, &f) != nil || f.Kind != "event" || f.Checksum == "" {
		// Unchecksummed frames are the stream's own replay; history covers them.
		return
	}
	s.mu.Lock()
	switch {
	case f.PrevChecksum == s.held:
		s.applyLocked(ctx, f.Event, true, false)
		s.held = f.Checksum
		s.applied++
		s.synced = true
		s.mu.Unlock()
	case !s.synced:
		// Already in the history fetched at connect.
		s.mu.Unlock()
	default:
		s.mu.Unlock()
		if err := s.resync(ctx); err != nil {
			log.Printf("session %s: resync after gap: %v", s.id, err)
		}
	}
}

// prompt sends text and waits for its turn to end.
func (s *session) prompt(ctx context.Context, text string) (string, error) {
	s.mu.Lock()
	if s.turn != nil {
		s.mu.Unlock()
		return "", fmt.Errorf("a prompt is already running in %s", s.id)
	}
	t := &turn{done: make(chan turnResult, 1)}
	s.turn = t
	s.tr.echoUser = false
	if s.prefix != "" {
		text = s.prefix + "\n\n" + text
		s.prefix = ""
	}
	s.mu.Unlock()

	if err := s.c.call(ctx, "POST", s.path("/messages"), map[string]string{"text": text}, nil); err != nil {
		s.mu.Lock()
		if s.turn == t {
			s.turn = nil
			s.tr.echoUser = true
		}
		s.mu.Unlock()
		return "", err
	}
	select {
	case r := <-t.done:
		return r.stopReason, r.err
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (s *session) cancel(ctx context.Context) {
	s.mu.Lock()
	if t := s.turn; t != nil {
		t.cancelled = true
		// No run started, so no run end will close it.
		if !t.started {
			s.finishLocked(turnResult{stopReason: "cancelled"})
		}
	}
	s.mu.Unlock()
	if err := s.c.call(ctx, "POST", s.path("/cancel"), nil, nil); err != nil {
		log.Printf("session %s: cancel: %v", s.id, err)
	}
}
