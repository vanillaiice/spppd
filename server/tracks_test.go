package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func readFixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// The limits here are the game's. If one changes in the Lua, this says so.
func TestTrackLimitsMatchTheGame(t *testing.T) {
	read := func(path string) string {
		data, err := os.ReadFile("../" + path)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	wire, share, config := read("src/tracks/wire.lua"), read("src/tracks/share.lua"), read("src/config.lua")
	find := func(text, pattern string) []float64 {
		t.Helper()
		m := regexp.MustCompile(pattern).FindStringSubmatch(text)
		if m == nil {
			t.Fatalf("%q not found", pattern)
		}
		var out []float64
		for _, s := range m[1:] {
			v, err := strconv.ParseFloat(s, 64)
			if err != nil {
				t.Fatal(err)
			}
			out = append(out, v)
		}
		return out
	}
	checks := []struct {
		text, pattern string
		want          []float64
	}{
		{wire, `wire\.MAX_BYTES = (\d+)`, []float64{trackMaxBytes}},
		{share, `share\.MAX_CODE = (\d+)`, []float64{trackMaxCode}},
		{wire, `local MAX_NODES = (\d+)`, []float64{trackMaxNodes}},
		{wire, `local MAX_SEGMENTS = (\d+)`, []float64{trackMaxSegments}},
		{wire, `local MAX_CURVE_POINTS = (\d+)`, []float64{trackMaxCurve}},
		{wire, `local MAX_POINTS = (\d+)`, []float64{trackMaxPoints}},
		{wire, `local MAX_COORD = (\d+)`, []float64{trackMaxCoord}},
		{wire, `local MAX_LAP_METRES = (\d+)`, []float64{trackMaxLapMetres}},
		{wire, `local MIN_WIDTH, MAX_WIDTH = (\d+), (\d+)`, []float64{trackMinWidth, trackMaxWidth}},
		{wire, `local MIN_SCALE, MAX_SCALE = (\d+), (\d+)`, []float64{trackMinScale, trackMaxScale}},
		{wire, `local MIN_RUNOFF, MAX_RUNOFF = (\d+), (\d+)`, []float64{trackMinRunoff, trackMaxRunoff}},
		{wire, `local MAX_TITLE = (\d+)`, []float64{trackMaxTitle}},
		{config, `METER = ([\d.]+),`, []float64{trackMeter}},
		{config, `TRACK_SCALE = ([\d.]+),`, []float64{trackScale}},
	}
	for _, c := range checks {
		got := find(c.text, c.pattern)
		if fmt.Sprint(got) != fmt.Sprint(c.want) {
			t.Errorf("%s: the game has %v, the relay %v", c.pattern, got, c.want)
		}
	}
	if !strings.Contains(wire, `local HEADER = "`+trackHeader+`"`) || !strings.Contains(share, `share.PREFIX = "`+trackPrefix+`"`) {
		t.Error("the header or the code prefix changed in the game")
	}
	if !strings.Contains(wire, `local THEMES = { meadow = true, desert = true, marina = true }`) {
		t.Error("the game's themes changed")
	}
}

func TestTracksTheGameMadeAreTaken(t *testing.T) {
	for _, name := range []string{"oasis.spppd", "boat.spppd"} {
		text := readFixture(t, name)
		track, err := CheckTrack(text)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if track.Text != text {
			t.Errorf("%s: the text changed on the way in", name)
		}
		if len(track.Outline) < 10 || len(track.Outline) > outlinePoints+1 {
			t.Errorf("%s: %d outline points", name, len(track.Outline))
		}
		for _, p := range track.Outline {
			if p[0] < 0 || p[0] > 100 || p[1] < 0 || p[1] > 100 {
				t.Fatalf("%s: outline point %v outside the box", name, p)
			}
		}
		if track.Metres < 500 || track.Metres > 10000 {
			t.Errorf("%s: %.0f m", name, track.Metres)
		}
	}
	oasis, _ := CheckTrack(readFixture(t, "oasis.spppd"))
	if oasis.Title != "OASIS" || oasis.Theme != "desert" {
		t.Errorf("got %q %q", oasis.Title, oasis.Theme)
	}
}

func nodeTrack(nodes int, extra ...string) string {
	lines := []string{trackHeader, "title TEST"}
	lines = append(lines, extra...)
	for i := 0; i < nodes; i++ {
		lines = append(lines, fmt.Sprintf("node %d.00 %d.00 20.00 20.00", (i%40)*10, (i/40)*10))
	}
	return strings.Join(lines, "\n") + "\n"
}

func TestTracksTheGameWouldRefuseAreRefused(t *testing.T) {
	bad := map[string]string{
		"wrong header":    strings.Replace(nodeTrack(5), trackHeader, "spppd-track 2", 1),
		"NaN":             nodeTrack(5, "node nan 1 20 20"),
		"infinity":        nodeTrack(5, "node 1e400 1 20 20"),
		"far away":        nodeTrack(5, "node 100001 1 20 20"),
		"too many nodes":  nodeTrack(trackMaxNodes + 1),
		"too few nodes":   nodeTrack(3),
		"narrow":          nodeTrack(5, "node 1 1 0.5 20"),
		"node fields":     nodeTrack(5, "node 1 1 20"),
		"bad scale":       nodeTrack(5, "scale 9"),
		"bad runoff":      nodeTrack(5, "runoff 1"),
		"bad start":       nodeTrack(5, "start 1 2"),
		"bad side":        nodeTrack(5, "seg middle line 1 1 2 2"),
		"bad kind":        nodeTrack(5, "seg left spline 1 1 2 2"),
		"odd coordinates": nodeTrack(5, "seg left line 1 1 2"),
		"too long":        strings.Join([]string{trackHeader, "node 0 0 20 20", "node 100000 0 20 20", "node 0 1 20 20", "node 100000 1 20 20"}, "\n"),
		"no road":         trackHeader + "\ntitle EMPTY\n",
		"one side":        trackHeader + "\nseg left line 0 0 100 0 100 100\n",
		"too big":         trackHeader + "\n" + strings.Repeat("x", trackMaxBytes),
	}
	curve := []string{"seg left curve"}
	for i := 0; i <= trackMaxCurve; i++ {
		curve = append(curve, "1 1")
	}
	bad["complex curve"] = nodeTrack(5, strings.Join(curve, " "))
	for why, text := range bad {
		if _, err := CheckTrack(text); err == nil {
			t.Errorf("%s: taken", why)
		}
	}
}

func TestOnlyLinesTheGameReadsAreKept(t *testing.T) {
	text := nodeTrack(5, "theme space", "advert visit my site", "  node 1 1 1 1", "author FAKE") + "title  Hé <b>WOW</b>\n"
	track, err := CheckTrack(text)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(track.Text, "advert") || strings.Contains(track.Text, "  node") || strings.Contains(track.Text, "FAKE") {
		t.Errorf("kept lines the game ignores:\n%s", track.Text)
	}
	if track.Title != "H bWOWb" || track.Theme != "meadow" {
		t.Errorf("title %q theme %q", track.Title, track.Theme)
	}
	if !strings.HasPrefix(track.Text, trackHeader+"\ntitle H bWOWb\ntheme meadow\nnode ") {
		t.Errorf("text starts %q", track.Text[:60])
	}
	if again, err := CheckTrack(track.Text); err != nil || again.Text != track.Text {
		t.Errorf("the kept text doesn't check the same: %v", err)
	}
}

func TestCodesGoBothWays(t *testing.T) {
	text := readFixture(t, "oasis.spppd")
	code := TrackCode(text)
	if !strings.HasPrefix(code, trackPrefix) || len(code) > trackMaxCode {
		t.Fatalf("code %d bytes", len(code))
	}
	back, err := DecodeUpload("  " + strings.ToLower(trackPrefix) + code[len(trackPrefix):len(trackPrefix)+20] + "\n " + code[len(trackPrefix)+20:] + "\n")
	if err != nil {
		t.Fatal(err)
	}
	// COPY CODE packs the text without its last newline, as the game does.
	if back+"\n" != text {
		t.Fatal("the code didn't come back as the same track")
	}
	if plain, _ := DecodeUpload(strings.ReplaceAll(text, "\n", "\r\n")); plain != strings.TrimSpace(text) {
		t.Fatal("a file with Windows line endings didn't read")
	}
}

func TestBadTrackCodesAreRefused(t *testing.T) {
	var bomb bytes.Buffer
	w := zlib.NewWriter(&bomb)
	_, _ = w.Write([]byte(trackHeader + "\n" + strings.Repeat("a", 10<<20)))
	_ = w.Close()
	for why, code := range map[string]string{
		"empty":    "   ",
		"not b64":  trackPrefix + "!!!!",
		"not zlib": trackPrefix + base64.StdEncoding.EncodeToString([]byte("hello there")),
		"cut off":  TrackCode(readFixture(t, "oasis.spppd"))[:200],
		"bomb":     trackPrefix + base64.StdEncoding.EncodeToString(bomb.Bytes()),
		"too long": trackPrefix + strings.Repeat("A", trackMaxCode),
	} {
		text, err := DecodeUpload(code)
		if err == nil {
			_, err = CheckTrack(text)
		}
		if err == nil {
			t.Errorf("%s: taken", why)
		}
	}
}

func trackServer(t *testing.T) (*TrackServer, http.Handler, *Relay, *time.Time) {
	t.Helper()
	store, err := OpenStore("")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	relay, _, clock := setup()
	ts := NewTrackServer(store, relay.Note)
	ts.now = func() time.Time { return *clock }
	return ts, newStatusPage(relay, ts), relay, clock
}

func upload(h http.Handler, from, track, author string, contact ...string) *httptest.ResponseRecorder {
	req := uploadRequest{Track: track, Author: author}
	if len(contact) > 0 {
		req.Contact = contact[0]
	}
	return send(h, from, req)
}

func send(h http.Handler, from string, upload uploadRequest) *httptest.ResponseRecorder {
	body, _ := json.Marshal(upload)
	req := httptest.NewRequest(http.MethodPost, "/api/tracks", bytes.NewReader(body))
	req.RemoteAddr = "172.18.0.5:41000" // Caddy, on the kamal network
	if from != "" {
		req.Header.Set("X-Real-IP", from)
	}
	out := httptest.NewRecorder()
	h.ServeHTTP(out, req)
	return out
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	out := httptest.NewRecorder()
	h.ServeHTTP(out, httptest.NewRequest(http.MethodGet, path, nil))
	return out
}

func TestASentTrackShowsOnceApproved(t *testing.T) {
	ts, page, relay, _ := trackServer(t)
	code := TrackCode(readFixture(t, "oasis.spppd"))
	out := upload(page, "203.0.113.9", code, "xoroz", " maker@example.org ")
	if out.Code != http.StatusAccepted {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
	var answer struct{ ID int }
	_ = json.Unmarshal(out.Body.Bytes(), &answer)

	if list := get(page, "/api/tracks"); list.Body.String() != `{"tracks":[]}` {
		t.Fatalf("a waiting track is public: %s", list.Body)
	}
	if got := get(page, fmt.Sprintf("/api/tracks/%d.spppd", answer.ID)).Code; got != http.StatusNotFound {
		t.Fatalf("a waiting track's file: %d", got)
	}
	pending, _ := ts.store.Tracks(trackPending)
	if len(pending) != 1 || pending[0].Author != "XOROZ" || pending[0].Title != "OASIS" || pending[0].Contact != "maker@example.org" {
		t.Fatalf("pending %+v", pending)
	}

	if !ts.Review(answer.ID, "approve", "admin") {
		t.Fatal("not approved")
	}
	var list struct {
		Tracks []publicTrack `json:"tracks"`
	}
	if err := json.Unmarshal(get(page, "/api/tracks").Body.Bytes(), &list); err != nil || len(list.Tracks) != 1 {
		t.Fatalf("list %+v %v", list, err)
	}
	// The code and the file credit the sender, on the line after the title.
	credited := strings.Replace(readFixture(t, "oasis.spppd"), "title OASIS\n", "title OASIS\nauthor XOROZ\n", 1)
	if got := list.Tracks[0]; got.Code != TrackCode(credited) || got.Author != "XOROZ" || len(got.Outline) == 0 {
		t.Fatalf("listed %+v", got)
	}
	if strings.Contains(get(page, "/api/tracks").Body.String(), "example.org") {
		t.Fatal("the contact is public")
	}
	file := get(page, fmt.Sprintf("/api/tracks/%d.spppd", answer.ID))
	if file.Code != http.StatusOK || file.Body.String() != credited ||
		file.Header().Get("Content-Disposition") != `attachment; filename="oasis.spppd"` {
		t.Fatalf("file %d %v", file.Code, file.Header())
	}

	ts.Review(answer.ID, "hide", "admin")
	if list := get(page, "/api/tracks"); list.Body.String() != `{"tracks":[]}` {
		t.Fatalf("a hidden track is public: %s", list.Body)
	}
	events := relay.Snapshot().Events
	if len(events) < 3 || !strings.Contains(events[0].Text, `"OASIS" hidden by admin`) {
		t.Fatalf("events %+v", events)
	}
}

func TestUploadsAreLimited(t *testing.T) {
	ts, page, _, clock := trackServer(t)
	track := func(i int) string { return nodeTrack(5, fmt.Sprintf("title TRACK %d", i)) }

	if out := upload(page, "203.0.113.9", track(0), ""); out.Code != http.StatusAccepted {
		t.Fatalf("status %d: %s", out.Code, out.Body)
	}
	if out := upload(page, "203.0.113.9", track(0), ""); out.Code != http.StatusConflict {
		t.Fatalf("the same track twice: %d", out.Code)
	}
	// An author line in the text is the sender's claim, not the server's: it's
	// dropped, so the same track under another name is still the same track.
	if out := upload(page, "203.0.113.9", strings.Replace(track(0), "title", "author SOMEONE\ntitle", 1), "BOB"); out.Code != http.StatusConflict {
		t.Fatalf("the same track with an author line: %d", out.Code)
	}
	for i := 1; i < uploadsPerHour; i++ {
		upload(page, "203.0.113.9", track(i), "")
	}
	if out := upload(page, "203.0.113.9", track(99), ""); out.Code != http.StatusTooManyRequests {
		t.Fatalf("past the hourly limit: %d", out.Code)
	}
	if out := upload(page, "203.0.113.10", track(99), ""); out.Code != http.StatusAccepted {
		t.Fatalf("someone else: %d", out.Code)
	}
	*clock = clock.Add(time.Hour)
	if out := upload(page, "203.0.113.9", track(100), ""); out.Code != http.StatusAccepted {
		t.Fatalf("an hour later: %d", out.Code)
	}
	// A bad track doesn't use up a try.
	if out := upload(page, "203.0.113.11", "hello", ""); out.Code != http.StatusBadRequest {
		t.Fatalf("not a track: %d", out.Code)
	}
	if out := upload(page, "203.0.113.11", track(200), "ADMIN"); out.Code != http.StatusBadRequest {
		t.Fatalf("a kept name: %d", out.Code)
	}

	// The queue has an end, whoever sends.
	for i := 0; ; i++ {
		ip := fmt.Sprintf("198.51.100.%d", i)
		out := upload(page, ip, track(1000+i), "")
		if out.Code == http.StatusConflict {
			break
		}
		if i > maxPending {
			t.Fatal("the queue never filled")
		}
	}
	if pending, _ := ts.store.Tracks(trackPending); len(pending) != maxPending {
		t.Fatalf("%d waiting", len(pending))
	}
}

func TestOnlyAProxyNearbyNamesTheSender(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/tracks", nil)
	req.Header.Set("X-Real-IP", "203.0.113.9")
	req.RemoteAddr = "198.51.100.1:5000"
	if got := uploaderIP(req); got != "198.51.100.1" {
		t.Fatalf("a stranger named themselves: %s", got)
	}
	req.RemoteAddr = "127.0.0.1:5000"
	if got := uploaderIP(req); got != "203.0.113.9" {
		t.Fatalf("from Caddy: %s", got)
	}
}

func TestOversizedUploadsAreRefused(t *testing.T) {
	_, page, _, _ := trackServer(t)
	if out := upload(page, "203.0.113.9", strings.Repeat("a", maxUploadBytes), ""); out.Code != http.StatusBadRequest {
		t.Fatalf("status %d", out.Code)
	}
	if got := get(page, "/api/tracks/x.spppd").Code; got != http.StatusNotFound {
		t.Fatalf("a made-up file: %d", got)
	}
	out := httptest.NewRecorder()
	page.ServeHTTP(out, httptest.NewRequest(http.MethodDelete, "/api/tracks", nil))
	if out.Code != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE: %d", out.Code)
	}
}

func TestTheDashboardReviewsTracks(t *testing.T) {
	relay, _, _ := setup()
	h, store := dash(t, relay)
	track, _ := CheckTrack(readFixture(t, "oasis.spppd"))
	id, err := store.AddTrack(track, time.Now())
	if err != nil {
		t.Fatal(err)
	}

	page := request(h, http.MethodGet, "/", nil, nil)
	if !strings.Contains(page.Body.String(), "Tracks waiting for review") || !strings.Contains(page.Body.String(), "OASIS") {
		t.Fatalf("no tracks section: %d", page.Code)
	}
	post := func(action string) *httptest.ResponseRecorder {
		return request(h, http.MethodPost, "/tracks/review", url.Values{"id": {strconv.Itoa(id)}, "action": {action}}, nil)
	}
	if out := post("approve"); out.Code != http.StatusOK || !strings.Contains(out.Body.String(), "Tracks on the website") {
		t.Fatalf("approve: %d %s", out.Code, out.Body)
	}
	if live, _ := store.Tracks(trackLive); len(live) != 1 || live[0].ReviewedBy != "localhost" {
		t.Fatalf("live %+v", live)
	}
	if out := post("delete"); out.Code != http.StatusOK {
		t.Fatalf("delete: %d", out.Code)
	}
	if out := post("delete"); !strings.Contains(out.Body.String(), "be changed. Try again") {
		t.Fatalf("deleting twice said nothing")
	}
	if got := request(h, http.MethodGet, "/tracks/review?id=1&action=approve", nil, nil).Code; got != http.StatusMethodNotAllowed {
		t.Fatalf("GET review: %d", got)
	}
	if got := request(h, http.MethodPost, "/tracks/review", url.Values{"id": {"1"}, "action": {"approve"}}, remote()).Code; got == http.StatusOK {
		t.Fatal("a stranger reviewed a track")
	}
}

func TestTheDashboardRenamesTracks(t *testing.T) {
	relay, _, _ := setup()
	h, store := dash(t, relay)
	oasis, _ := CheckTrack(readFixture(t, "oasis.spppd"))
	oasis.Author = "XOROZ"
	id, err := store.AddTrack(oasis, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	rename := func(title string, headers map[string]string) *httptest.ResponseRecorder {
		if headers == nil {
			headers = map[string]string{}
		}
		headers["HX-Prompt"] = title
		return request(h, http.MethodPost, "/tracks/rename", url.Values{"id": {strconv.Itoa(id)}}, headers)
	}

	// Before it's approved, as the browser's prompt sends it: cleaned and upper case.
	if out := rename("  sand Dunes!  ", nil); out.Code != http.StatusOK || !strings.Contains(out.Body.String(), "SAND DUNES") {
		t.Fatalf("rename: %d %s", out.Code, out.Body)
	}
	got, _ := store.Track(id)
	if got.Title != "SAND DUNES" || !strings.HasPrefix(got.Text, trackHeader+"\ntitle SAND DUNES\n") {
		t.Fatalf("renamed track: %q %q", got.Title, got.Text[:40])
	}
	if !strings.Contains(got.Wire(), "title SAND DUNES\nauthor XOROZ\n") {
		t.Fatalf("the file the game gets: %q", got.Wire()[:60])
	}
	// The rest of the track is untouched, and the game still opens it.
	if again, err := CheckTrack(got.Text); err != nil || again.Title != "SAND DUNES" || again.Metres != oasis.Metres {
		t.Fatalf("renamed text: %v %+v", err, again)
	}
	// Sent in again under the new name, it's still the same track.
	if _, err := store.AddTrack(got, time.Now()); err != errDuplicateTrack {
		t.Fatalf("resend after rename: %v", err)
	}
	// The original text is free again.
	other, err := store.AddTrack(oasis, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	// Two tracks can't end up as the same text.
	if out := request(h, http.MethodPost, "/tracks/rename", url.Values{"id": {strconv.Itoa(other)}, "title": {"sand dunes"}}, nil); !strings.Contains(out.Body.String(), "already here") {
		t.Fatalf("rename onto another track: %s", out.Body)
	}
	if out := rename("   ", nil); !strings.Contains(out.Body.String(), "Give the track a name") {
		t.Fatalf("empty name: %s", out.Body)
	}
	if got := request(h, http.MethodGet, "/tracks/rename?id=1&title=x", nil, nil).Code; got != http.StatusMethodNotAllowed {
		t.Fatalf("GET rename: %d", got)
	}
	if out := rename("STRANGER", remote()); out.Code == http.StatusOK {
		t.Fatal("a stranger renamed a track")
	}
	if got, _ := store.Track(id); got.Title != "SAND DUNES" {
		t.Fatalf("title now %q", got.Title)
	}

	// Once live, the list the game reads shows the new name.
	ts := NewTrackServer(store, relay.Note)
	if err := ts.Review(id, "approve", "test"); !err {
		t.Fatal("approve")
	}
	if err := ts.Rename(id, "Dune Run", "test"); err != nil {
		t.Fatal(err)
	}
	list, _ := ts.publicList()
	if !strings.Contains(string(list), `"title":"DUNE RUN"`) {
		t.Fatalf("list: %s", list)
	}
}

// testdata/oasis.code is a code this relay made, which tests/test_editor.lua
// imports in the game. Rewrite it with SPPPD_WRITE_CODE=1 go test -run TestTheGame.
func TestTheGameReadsTheRelaysCodes(t *testing.T) {
	text := readFixture(t, "oasis.spppd")
	if os.Getenv("SPPPD_WRITE_CODE") != "" {
		if err := os.WriteFile("testdata/oasis.code", []byte(TrackCode(text)+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	back, err := DecodeUpload(readFixture(t, "oasis.code"))
	if err != nil || back+"\n" != text {
		t.Fatalf("the kept code isn't oasis any more: %v", err)
	}
}

// Without -tracks there's no track server: nothing at /api/tracks, and no Tracks
// section on the dashboard.
func TestTracksAreOffUnlessAskedFor(t *testing.T) {
	relay, _, _ := setup()
	page := newStatusPage(relay, nil)
	if got := get(page, "/api/tracks").Code; got != http.StatusNotFound {
		t.Fatalf("list: %d", got)
	}
	if got := upload(page, "203.0.113.9", readFixture(t, "oasis.spppd"), "").Code; got != http.StatusNotFound {
		t.Fatalf("upload: %d", got)
	}
	if got := get(page, "/api/status").Code; got != http.StatusOK {
		t.Fatalf("status: %d", got)
	}

	store := memoryStore(t)
	if err := relay.AttachStore(store); err != nil {
		t.Fatal(err)
	}
	h := newDashboard(relay, store, 30, nil)
	if body := request(h, http.MethodGet, "/", nil, nil).Body.String(); strings.Contains(body, "Tracks waiting") {
		t.Fatal("the dashboard shows tracks")
	}
	if got := request(h, http.MethodPost, "/tracks/review", url.Values{"id": {"1"}, "action": {"approve"}}, nil).Code; got != http.StatusNotFound {
		t.Fatalf("review: %d", got)
	}
}

func TestContactsAreEmailsOrNothing(t *testing.T) {
	for _, good := range []string{"", "  ", "a@b.co", "first.last+tag@example.org"} {
		if _, err := cleanContact(good); err != nil {
			t.Errorf("%q refused: %v", good, err)
		}
	}
	for _, bad := range []string{"nope", "Bob <bob@example.org>", "a@b.co?subject=hi", `"x"@b.co`,
		"a@b.co, c@d.co", strings.Repeat("a", 250) + "@b.co"} {
		if _, err := cleanContact(bad); err == nil {
			t.Errorf("%q taken", bad)
		}
	}
	_, page, _, _ := trackServer(t)
	if out := upload(page, "203.0.113.9", readFixture(t, "oasis.spppd"), "", "not an email"); out.Code != http.StatusBadRequest {
		t.Fatalf("status %d", out.Code)
	}
}
