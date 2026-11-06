package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTheStatusPage(t *testing.T) {
	relay, _, _ := setup()
	pair(relay)
	relay.Handle([]byte("event|lock|"), addr(1))
	host(relay, "WXYZ", 3)
	page := newStatusPage(relay)

	out := httptest.NewRecorder()
	page.ServeHTTP(out, httptest.NewRequest(http.MethodGet, "/api/status", nil))
	if got := out.Body.String(); got != `{"up":true,"players":3,"races":1}`+"\n" {
		t.Fatalf("got %q", got)
	}
	if out.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("headers %v", out.Header())
	}

	post := httptest.NewRecorder()
	page.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/api/status", nil))
	if post.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST got %d", post.Code)
	}
}
