package main

// The track server: tracks players send in from spppd.xyz/tracks, which wait for a
// dashboard user to approve them, then show on that page for anyone to copy into
// the game. The game never talks to it. A track goes in through the editor's
// IMPORT, as a code or a file, which runs the game's own checks (src/tracks/wire.lua)
// whatever this server let through.
//
// The checks here are the same limits, so nothing the game would refuse waits for
// review. They're kept in step with the Lua by a test that reads its constants.
// Nothing about the sender is kept: their address only counts uploads in memory.

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The game's limits, from src/tracks/wire.lua, share.lua and config.lua.
const (
	trackHeader       = "spppd-track 1"
	trackMaxBytes     = 64000 // wire.MAX_BYTES
	trackMaxCode      = 40000 // share.MAX_CODE
	trackPrefix       = "SPPPD-TRACK:"
	trackMaxNodes     = 1500
	trackMaxSegments  = 400
	trackMaxCurve     = 64
	trackMaxPoints    = 3000
	trackMaxCoord     = 100000
	trackMaxLapMetres = 20000
	trackMinWidth     = 1
	trackMaxWidth     = 400
	trackMinScale     = 1
	trackMaxScale     = 8
	trackMinRunoff    = 2
	trackMaxRunoff    = 30
	trackMaxTitle     = 24
	trackMeter        = 12  // config.METER: world px per metre
	trackScale        = 3.0 // config.TRACK_SCALE: the default
)

const (
	uploadsPerHour  = 5
	maxPending      = 100
	maxUploadBytes  = 128 << 10
	outlinePoints   = 80
	trackListMaxAge = 30 * time.Second
)

var trackThemes = map[string]bool{"meadow": true, "desert": true, "marina": true}

// Track states. A rejected track is deleted, not kept.
const (
	trackPending = "pending"
	trackLive    = "live"
	trackHidden  = "hidden"
)

var (
	errDuplicateTrack = errors.New("That track is already here")
	errNoTrack        = errors.New("That track isn't here any more")
	errQueueFull      = errors.New("Too many tracks are waiting to be checked. Try again in a few days")
)

// Point is one point of a track's outline, in a 100 by 100 box.
type Point [2]float64

// Track is one track on the server.
type Track struct {
	ID         int
	Title      string
	Author     string
	Contact    string // an email for the operator to reply to; never public
	Theme      string
	Metres     float64
	Text       string // the plain wire text, only lines the game reads
	Outline    []Point
	State      string
	Added      time.Time
	Reviewed   time.Time
	ReviewedBy string
}

// Checking ---------------------------------------------------------------------

func within(v, low, high float64) bool { return v >= low && v <= high } // NaN fails both

// trackNumbers reads the numbers of a line as wire.lua's numbers() does, or says no.
// Go reads fewer forms than Lua (no 0x10), which only refuses more.
func trackNumbers(text string) ([]float64, bool) {
	var out []float64
	for _, word := range strings.Fields(text) {
		v, err := strconv.ParseFloat(word, 64)
		if err != nil || !within(v, -trackMaxCoord, trackMaxCoord) {
			return nil, false
		}
		out = append(out, v)
	}
	return out, true
}

// cleanTrackTitle is wire.cleanTitle: the font only has ASCII.
func cleanTrackTitle(title string) string {
	var b strings.Builder
	for i := 0; i < len(title) && b.Len() < trackMaxTitle; i++ {
		c := title[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(" -_.'", c) >= 0 {
			b.WriteByte(c)
		}
	}
	if b.Len() == 0 {
		return "SHARED TRACK"
	}
	return b.String()
}

func polylineMetres(points []Point, scale float64, closed bool) float64 {
	total := 0.0
	for i := 1; i < len(points); i++ {
		total += math.Hypot(points[i][0]-points[i-1][0], points[i][1]-points[i-1][1])
	}
	if closed && len(points) > 2 {
		last := points[len(points)-1]
		total += math.Hypot(points[0][0]-last[0], points[0][1]-last[1])
	}
	return total * scale / trackMeter
}

// isSpace is Lua's %s.
func isSpace(c byte) bool { return c == ' ' || c >= '\t' && c <= '\r' }

// CheckTrack holds a track's wire text to the limits wire.decode does. It gives the
// track back with only the lines the game reads, plus its title, theme, length and
// outline.
func CheckTrack(text string) (Track, error) {
	bad := func(why string) (Track, error) {
		return Track{}, errors.New("Not a track the game can open (" + why + ")")
	}
	if len(text) > trackMaxBytes {
		return bad("too big")
	}
	if first, _, _ := strings.Cut(text, "\n"); first != trackHeader {
		return bad("not a track")
	}
	t := Track{Title: "SHARED TRACK", Theme: "meadow"}
	scale := trackScale
	var nodes, left, right []Point
	var leftSegs, rightSegs, totalPoints int
	var leftMetres, rightMetres float64
	kept := []string{trackHeader}
	for _, line := range strings.Split(text, "\n")[1:] {
		if line == "" || isSpace(line[0]) {
			continue // Lua's ^(%S+) doesn't match these, so the game skips them
		}
		end := 0
		for end < len(line) && !isSpace(line[end]) {
			end++
		}
		key, rest := line[:end], strings.TrimLeft(line[end:], " \t\n\v\f\r")
		switch key {
		case "title":
			t.Title = cleanTrackTitle(rest)
			continue // written again below, cleaned
		case "author":
			continue // the server credits whoever sends it in, from the form (Track.Wire)
		case "theme":
			if trackThemes[rest] {
				t.Theme = rest
			}
			continue
		case "scale", "runoff":
			v, err := strconv.ParseFloat(rest, 64)
			low, high := float64(trackMinScale), float64(trackMaxScale)
			if key == "runoff" {
				low, high = trackMinRunoff, trackMaxRunoff
			}
			if err != nil || !within(v, low, high) {
				return bad("bad " + key)
			}
			if key == "scale" {
				scale = v
			}
		case "start":
			if v, ok := trackNumbers(rest); !ok || len(v) != 3 {
				return bad("bad start")
			}
		case "node":
			v, ok := trackNumbers(rest)
			if !ok || len(v) != 4 {
				return bad("bad node")
			}
			if !within(v[2], trackMinWidth, trackMaxWidth) || !within(v[3], trackMinWidth, trackMaxWidth) {
				return bad("bad width")
			}
			if len(nodes) >= trackMaxNodes {
				return bad("too many nodes")
			}
			nodes = append(nodes, Point{v[0], v[1]})
		case "seg":
			parts := strings.SplitN(rest, " ", 3)
			if len(parts) != 3 || (parts[0] != "left" && parts[0] != "right") {
				return bad("bad segment")
			}
			switch parts[1] {
			case "line", "curve", "startPt", "kerb":
			default:
				return bad("bad segment")
			}
			v, ok := trackNumbers(parts[2])
			if !ok || len(v)%2 != 0 {
				return bad("bad segment")
			}
			if parts[1] == "curve" && len(v)/2 > trackMaxCurve {
				return bad("curve too complex")
			}
			points := make([]Point, 0, len(v)/2)
			for i := 0; i < len(v); i += 2 {
				points = append(points, Point{v[i], v[i+1]})
			}
			totalPoints += len(points)
			count := &leftSegs
			if parts[0] == "right" {
				count = &rightSegs
			}
			if *count >= trackMaxSegments || totalPoints > trackMaxPoints {
				return bad("too many segments")
			}
			*count++
			if parts[0] == "left" {
				left = append(left, points...)
				leftMetres += polylineMetres(points, trackMeter, false) // raw length; scaled once the scale is known
			} else {
				right = append(right, points...)
				rightMetres += polylineMetres(points, trackMeter, false)
			}
		default:
			continue // the game ignores it, and so does the copy kept here
		}
		kept = append(kept, line)
	}

	if len(nodes) > 0 {
		if len(nodes) < 4 {
			return bad("too few nodes")
		}
		if polylineMetres(nodes, scale, false) > trackMaxLapMetres {
			return bad("too long")
		}
		t.Metres = polylineMetres(nodes, scale, true)
		t.Outline = outline(nodes)
	} else {
		if leftSegs == 0 || rightSegs == 0 {
			return bad("no road")
		}
		leftMetres, rightMetres = leftMetres*scale/trackMeter, rightMetres*scale/trackMeter
		if leftMetres > trackMaxLapMetres || rightMetres > trackMaxLapMetres {
			return bad("too long")
		}
		t.Metres = (leftMetres + rightMetres) / 2
		t.Outline = outline(left)
	}
	// The title and theme go back in at the top, as wire.encode writes them.
	kept = append([]string{trackHeader, "title " + t.Title, "theme " + t.Theme}, kept[1:]...)
	t.Text = strings.Join(kept, "\n") + "\n"
	return t, nil
}

// Wire is the track as the game reads it, with the author credited on the line
// after the title, as wire.encode writes it. Kept apart from Text, so the same
// track sent in under two names is still the same track.
func (t Track) Wire() string {
	if t.Author == "" {
		return t.Text
	}
	title, rest, _ := strings.Cut(strings.TrimPrefix(t.Text, trackHeader+"\n"), "\n")
	return trackHeader + "\n" + title + "\nauthor " + t.Author + "\n" + rest
}

// outline thins a track's points to a few dozen, fitted to a 100 by 100 box.
func outline(points []Point) []Point {
	if len(points) == 0 {
		return nil
	}
	minX, minY, maxX, maxY := points[0][0], points[0][1], points[0][0], points[0][1]
	for _, p := range points {
		minX, maxX = math.Min(minX, p[0]), math.Max(maxX, p[0])
		minY, maxY = math.Min(minY, p[1]), math.Max(maxY, p[1])
	}
	size := math.Max(maxX-minX, maxY-minY)
	if size == 0 {
		size = 1
	}
	// Centred in the box, so a long thin track sits in the middle.
	offX := (size - (maxX - minX)) / 2
	offY := (size - (maxY - minY)) / 2
	step := 1.0
	if len(points) > outlinePoints {
		step = float64(len(points)) / outlinePoints
	}
	var out []Point
	for f := 0.0; int(f) < len(points); f += step {
		p := points[int(f)]
		out = append(out, Point{
			math.Round((p[0]-minX+offX)/size*1000) / 10,
			math.Round((p[1]-minY+offY)/size*1000) / 10,
		})
	}
	return out
}

// DecodeUpload takes what a player pasted or sent: a track code from COPY CODE,
// or a track file's plain text, as share.import does.
func DecodeUpload(raw string) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", errors.New("Paste a track code or pick a track file")
	}
	if len(text) >= len(trackPrefix) && strings.EqualFold(text[:len(trackPrefix)], trackPrefix) {
		if len(text) > trackMaxCode {
			return "", errors.New("That code is too long to be a track")
		}
		body := strings.Map(func(r rune) rune {
			if r < 128 && isSpace(byte(r)) {
				return -1
			}
			return r
		}, text[len(trackPrefix):])
		packed, err := base64.StdEncoding.DecodeString(body)
		if err != nil {
			packed, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(body, "="))
		}
		if err != nil {
			return "", errors.New("That isn't a whole track code. Copy it again")
		}
		reader, err := zlib.NewReader(bytes.NewReader(packed))
		if err != nil {
			return "", errors.New("That isn't a whole track code. Copy it again")
		}
		// One byte past the limit, so a code that inflates too far is seen.
		inflated, err := io.ReadAll(io.LimitReader(reader, trackMaxBytes+1))
		if err != nil && len(inflated) <= trackMaxBytes {
			return "", errors.New("That isn't a whole track code. Copy it again")
		}
		if len(inflated) > trackMaxBytes {
			return "", errors.New("Not a track the game can open (too big)")
		}
		text = string(inflated)
	}
	return strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n"), nil
}

// TrackCode is what the editor's COPY CODE makes: the text deflated with zlib, in
// base64. LÖVE's "zlib" is the standard format, so the game reads it.
func TrackCode(text string) string {
	var packed bytes.Buffer
	w, _ := zlib.NewWriterLevel(&packed, zlib.BestCompression)
	_, _ = w.Write([]byte(strings.TrimRight(text, "\n")))
	_ = w.Close()
	return trackPrefix + base64.StdEncoding.EncodeToString(packed.Bytes())
}

// Storing ------------------------------------------------------------------------

const trackColumns = `id, title, author, contact, theme, metres, text, outline, state, added, reviewed, reviewed_by`

func scanTrack(row interface{ Scan(...any) error }) (Track, error) {
	var t Track
	var outlineJSON string
	var added, reviewed int64
	if err := row.Scan(&t.ID, &t.Title, &t.Author, &t.Contact, &t.Theme, &t.Metres, &t.Text, &outlineJSON,
		&t.State, &added, &reviewed, &t.ReviewedBy); err != nil {
		return t, err
	}
	_ = json.Unmarshal([]byte(outlineJSON), &t.Outline)
	t.Added = time.Unix(added, 0)
	if reviewed != 0 {
		t.Reviewed = time.Unix(reviewed, 0)
	}
	return t, nil
}

// AddTrack keeps a track that's waiting for review.
func (s *Store) AddTrack(t Track, now time.Time) (int, error) {
	var pending int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM tracks WHERE state = ?`, trackPending).Scan(&pending); err != nil {
		return 0, err
	}
	if pending >= maxPending {
		return 0, errQueueFull
	}
	sum := sha256.Sum256([]byte(t.Text))
	outlineJSON, _ := json.Marshal(t.Outline)
	result, err := s.db.Exec(`INSERT INTO tracks (title, author, contact, theme, metres, text, outline, hash, state, added)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (hash) DO NOTHING`,
		t.Title, t.Author, t.Contact, t.Theme, t.Metres, t.Text, string(outlineJSON), hex.EncodeToString(sum[:]), trackPending, now.Unix())
	if err != nil {
		return 0, err
	}
	if n, _ := result.RowsAffected(); n == 0 {
		return 0, errDuplicateTrack
	}
	id, err := result.LastInsertId()
	return int(id), err
}

// Tracks lists the tracks in one state: the newest first while they wait, the
// oldest first once they're live, so the list doesn't shuffle as tracks are added.
func (s *Store) Tracks(state string) ([]Track, error) {
	order := "added DESC"
	if state != trackPending {
		order = "reviewed, id"
	}
	rows, err := s.db.Query(`SELECT `+trackColumns+` FROM tracks WHERE state = ? ORDER BY `+order, state)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) Track(id int) (Track, bool) {
	t, err := scanTrack(s.db.QueryRow(`SELECT `+trackColumns+` FROM tracks WHERE id = ?`, id))
	return t, err == nil
}

// RenameTrack gives a track a new title, both in its title column and on the title
// line of the text the game downloads. The hash follows the text, so the same track
// sent in again under its new name is still caught as already here.
func (s *Store) RenameTrack(id int, title string) error {
	t, found := s.Track(id)
	if !found {
		return errNoTrack
	}
	_, rest, _ := strings.Cut(strings.TrimPrefix(t.Text, trackHeader+"\n"), "\n")
	text := trackHeader + "\ntitle " + title + "\n" + rest
	sum := sha256.Sum256([]byte(text))
	_, err := s.db.Exec(`UPDATE tracks SET title = ?, text = ?, hash = ? WHERE id = ?`,
		title, text, hex.EncodeToString(sum[:]), id)
	if err != nil && strings.Contains(err.Error(), "UNIQUE") {
		return errDuplicateTrack
	}
	return err
}

func (s *Store) SetTrackState(id int, state, by string, now time.Time) bool {
	result, err := s.db.Exec(`UPDATE tracks SET state = ?, reviewed = ?, reviewed_by = ? WHERE id = ?`, state, now.Unix(), by, id)
	if err != nil {
		return false
	}
	n, _ := result.RowsAffected()
	return n == 1
}

func (s *Store) DeleteTrack(id int) bool {
	result, err := s.db.Exec(`DELETE FROM tracks WHERE id = ?`, id)
	if err != nil {
		return false
	}
	n, _ := result.RowsAffected()
	return n == 1
}

// Serving ------------------------------------------------------------------------

// TrackServer answers /api/tracks, and holds what the dashboard changes.
type TrackServer struct {
	store *Store
	note  func(format string, args ...any)
	now   func() time.Time

	mu      sync.Mutex
	uploads map[string]*hourCount // by IP, in memory only
	list    []byte                // the public list, made once and kept a while
	listAt  time.Time
}

func NewTrackServer(store *Store, note func(string, ...any)) *TrackServer {
	return &TrackServer{store: store, note: note, now: time.Now, uploads: make(map[string]*hourCount)}
}

// publicTrack is a track as the website sees it.
type publicTrack struct {
	ID      int     `json:"id"`
	Title   string  `json:"title"`
	Author  string  `json:"author,omitempty"`
	Theme   string  `json:"theme"`
	Metres  int     `json:"metres"`
	Outline []Point `json:"outline"`
	Code    string  `json:"code"`
	Added   string  `json:"added"`
}

func (ts *TrackServer) publicList() ([]byte, error) {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	if ts.list != nil && ts.now().Sub(ts.listAt) < trackListMaxAge {
		return ts.list, nil
	}
	tracks, err := ts.store.Tracks(trackLive)
	if err != nil {
		return nil, err
	}
	out := make([]publicTrack, 0, len(tracks))
	for _, t := range tracks {
		out = append(out, publicTrack{
			ID: t.ID, Title: t.Title, Author: t.Author, Theme: t.Theme, Metres: int(math.Round(t.Metres)),
			Outline: t.Outline, Code: TrackCode(t.Wire()), Added: dayOf(t.Reviewed),
		})
	}
	list, err := json.Marshal(map[string]any{"tracks": out})
	if err != nil {
		return nil, err
	}
	ts.list, ts.listAt = list, ts.now()
	return list, nil
}

// changed drops the kept list, so a track approved or hidden shows at once.
func (ts *TrackServer) changed() {
	ts.mu.Lock()
	ts.list = nil
	ts.mu.Unlock()
}

func (ts *TrackServer) allowUpload(ip string) bool {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	now := ts.now()
	c := ts.uploads[ip]
	if c == nil || now.Sub(c.Since) >= time.Hour {
		if c == nil && len(ts.uploads) >= maxRateEntries {
			for other := range ts.uploads {
				delete(ts.uploads, other)
				break
			}
		}
		c = &hourCount{Since: now}
		ts.uploads[ip] = c
	}
	if c.N >= uploadsPerHour {
		return false
	}
	c.N++
	return true
}

// uploaderIP is who sent a request. Caddy puts the player's address in X-Real-IP;
// it's believed only from a proxy on this machine or the private network, so
// nobody reaching the relay some other way can name themselves anyone.
func uploaderIP(r *http.Request) string {
	peer := clientIP(r)
	if ip := net.ParseIP(peer); ip != nil && (ip.IsLoopback() || ip.IsPrivate()) {
		if real := net.ParseIP(strings.TrimSpace(r.Header.Get("X-Real-IP"))); real != nil {
			return real.String()
		}
	}
	return peer
}

func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}

func (ts *TrackServer) serveList(w http.ResponseWriter, r *http.Request) {
	list, err := ts.publicList()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "The tracks couldn't be read"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=60")
	_, _ = w.Write(list)
}

// serveFile answers /api/tracks/12.spppd with the track's file, to download.
func (ts *TrackServer) serveFile(w http.ResponseWriter, r *http.Request) {
	name, ok := strings.CutSuffix(r.PathValue("file"), ".spppd")
	id, err := strconv.Atoi(name)
	if !ok || err != nil {
		http.NotFound(w, r)
		return
	}
	t, found := ts.store.Track(id)
	if !found || t.State != trackLive {
		http.NotFound(w, r)
		return
	}
	file := strings.Trim(strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			return r
		}
		if r >= 'A' && r <= 'Z' {
			return r + 32
		}
		return '_'
	}, t.Title), "_")
	if file == "" {
		file = "track"
	}
	h := w.Header()
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.spppd"`, file))
	h.Set("Cache-Control", "public, max-age=300")
	_, _ = io.WriteString(w, t.Wire())
}

type uploadRequest struct {
	Track   string `json:"track"`
	Author  string `json:"author"`
	Contact string `json:"contact"`
}

// cleanContact checks an email the sender gave, so the dashboard's link to it works.
// An address with a display name, or anything that isn't one plain address, is refused.
func cleanContact(raw string) (string, error) {
	contact := strings.TrimSpace(raw)
	if contact == "" {
		return "", nil
	}
	parsed, err := mail.ParseAddress(contact)
	if err != nil || parsed.Name != "" || parsed.Address != contact || len(contact) > 254 ||
		strings.ContainsAny(contact, "<>\"'`?&") {
		return "", errors.New("That email doesn't look right. Leave it empty if you'd rather not give one")
	}
	return contact, nil
}

func (ts *TrackServer) serveUpload(w http.ResponseWriter, r *http.Request) {
	refuse := func(code int, message string) { writeJSON(w, code, map[string]string{"error": message}) }
	var req uploadRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxUploadBytes)).Decode(&req); err != nil {
		refuse(http.StatusBadRequest, "That's too big to be a track")
		return
	}
	text, err := DecodeUpload(req.Track)
	if err != nil {
		refuse(http.StatusBadRequest, err.Error())
		return
	}
	t, err := CheckTrack(text)
	if err != nil {
		refuse(http.StatusBadRequest, err.Error())
		return
	}
	if author := strings.TrimSpace(req.Author); author != "" {
		if t.Author, err = cleanName(author); err != nil {
			refuse(http.StatusBadRequest, err.Error())
			return
		}
	}
	if t.Contact, err = cleanContact(req.Contact); err != nil {
		refuse(http.StatusBadRequest, err.Error())
		return
	}
	// Counted only once the track is good, so a typo doesn't use up a try.
	if !ts.allowUpload(uploaderIP(r)) {
		refuse(http.StatusTooManyRequests, "That's enough tracks for now. Try again in an hour")
		return
	}
	id, err := ts.store.AddTrack(t, ts.now())
	switch {
	case errors.Is(err, errDuplicateTrack), errors.Is(err, errQueueFull):
		refuse(http.StatusConflict, err.Error())
		return
	case err != nil:
		refuse(http.StatusInternalServerError, "The track couldn't be kept. Try again later")
		return
	}
	by := ""
	if t.Author != "" {
		by = " by " + t.Author
	}
	ts.note("[TRACK] %q%s sent in, waiting for review (no. %d)", t.Title, by, id)
	writeJSON(w, http.StatusAccepted, map[string]any{"id": id, "title": t.Title,
		"message": "Thanks! " + t.Title + " will show up here once it's been checked."})
}

// Rename is a dashboard user's new title for a track, cleaned as a sent-in title is.
func (ts *TrackServer) Rename(id int, title, by string) error {
	title = strings.TrimSpace(strings.ToUpper(title))
	if title == "" {
		return errors.New("Give the track a name")
	}
	clean := cleanTrackTitle(title)
	t, found := ts.store.Track(id)
	if !found {
		return errNoTrack
	}
	if clean == t.Title {
		return nil
	}
	if err := ts.store.RenameTrack(id, clean); err != nil {
		return err
	}
	ts.changed()
	ts.note("[TRACK] %q renamed %q by %s", t.Title, clean, by)
	return nil
}

// Review is a dashboard user's decision on a track.
func (ts *TrackServer) Review(id int, action, by string) bool {
	t, found := ts.store.Track(id)
	if !found {
		return false
	}
	now := ts.now()
	ok := false
	switch action {
	case "approve", "show":
		ok = ts.store.SetTrackState(id, trackLive, by, now)
	case "hide":
		ok = ts.store.SetTrackState(id, trackHidden, by, now)
	case "reject", "delete":
		ok = ts.store.DeleteTrack(id)
	}
	if ok {
		ts.changed()
		past := map[string]string{"approve": "approved", "show": "shown again", "hide": "hidden", "reject": "rejected", "delete": "deleted"}
		ts.note("[TRACK] %q %s by %s", t.Title, past[action], by)
	}
	return ok
}

func (ts *TrackServer) handle(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/tracks", ts.serveList)
	mux.HandleFunc("GET /api/tracks/{file}", ts.serveFile)
	mux.HandleFunc("POST /api/tracks", ts.serveUpload)
}
