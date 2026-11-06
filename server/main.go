// Relay server for SPPPD online races. A host opens a room, up to three others
// join with its code, and from then on every packet goes to the rest of the
// room, stamped with the seat it came from. The relay reads nothing it forwards.
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxCodeLength  = 16
	maxPacketBytes = 2048
	maxEvents      = 200
	maxRoomPlayers = 4
	maxPerIP       = 16 // a whole LAN party can share one address
	maxRateEntries = 1 << 16
	// A client that has said nothing for this long isn't listening, so the sweep
	// stops repeating its room to it. Games send four times a second at least.
	announceWindow = 2 * time.Second

	// From protocol 5 a client earns its seat. Its first host, join or back gets a
	// cookie, a keyed hash of its address that only that address sees, and only a
	// request that repeats it is seated. So a forged source can't hold a seat, and
	// gets one answer no bigger than what it sent.
	cookieProto      = 5
	minRegisterBytes = 64 // games pad their requests to this, so the cookie is never bigger
	cookieWindow     = 30 // seconds; a cookie works for one to two windows
	cookieBytes      = 16
	tokenBytes       = 16
)

const outOfDate = "This game is out of date. Update it to play online"

var eventPrefix = []byte("event|")

// Sender delivers a packet to an address. Tests replace the real socket.
type Sender func(data []byte, to *net.UDPAddr)

type Client struct {
	Addr     *net.UDPAddr
	LastSeen time.Time
	Room     *Room
	Slot     int // 1 to maxRoomPlayers
	// Token lets the seat be taken back from a new address. Only this client is
	// told it. Clients from before protocol 5 have none, and can't come back.
	Token string
	// Away is a driver gone quiet in a shared room. The seat waits for them, and
	// nothing is forwarded to them, until they come back or run out of time.
	Away bool
}

// Room is a group of up to four drivers. Seat 1 is the host. A locked room has
// started racing and takes nobody new. Its code stays taken until it empties.
type Room struct {
	Code   string
	Proto  string
	Since  time.Time
	Locked bool
	Raced  time.Time // when it locked
	Racers int       // seats taken when it locked
	Seats  [maxRoomPlayers]*Client
}

func (room *Room) members() []*Client {
	out := make([]*Client, 0, maxRoomPlayers)
	for _, client := range room.Seats {
		if client != nil {
			out = append(out, client)
		}
	}
	return out
}

// rateBucket is a token bucket for one IP.
type rateBucket struct {
	tokens float64
	last   time.Time
}

// Traffic counts packets and bytes in each direction.
type Traffic struct {
	PacketsIn, PacketsOut uint64
	BytesIn, BytesOut     uint64
}

func (t Traffic) minus(other Traffic) Traffic {
	return Traffic{
		PacketsIn:  t.PacketsIn - other.PacketsIn,
		PacketsOut: t.PacketsOut - other.PacketsOut,
		BytesIn:    t.BytesIn - other.BytesIn,
		BytesOut:   t.BytesOut - other.BytesOut,
	}
}

// refusalCount gathers refusals between sweeps, so a flood of them makes one
// dashboard line a second rather than pushing everything else off the list.
type refusalCount struct {
	total   int
	last    string         // the latest address refused
	reasons map[string]int // how often each reason was given
}

// Event is one line of the dashboard's recent activity.
type Event struct {
	Seq  uint64 // counts up, so the page can tell which lines are new
	At   time.Time
	Text string
}

type Relay struct {
	mu         sync.Mutex
	clients    map[string]*Client
	rooms      map[string]*Room
	banned     map[string]Ban
	perIP      map[string]int
	buckets    map[string]*rateBucket
	rate       float64       // packets a second per IP, 0 for no limit
	minProto   int           // older games are told to update
	away       time.Duration // how long a seat waits for its driver, past the race timeout
	cookieKey  []byte
	maxPlayers int
	maxRooms   int // 0 for no limit beyond maxPlayers
	events     []Event
	eventSeq   uint64
	total      Traffic
	sampled    Traffic
	perSecond  Traffic
	dropped    uint64
	refusals   refusalCount // since the last sweep
	started    time.Time
	send       Sender
	now        func() time.Time

	store        *Store   // nil in tests that don't need one
	tally        *Tally   // today's analytics, nil when they're off
	finished     []*Tally // earlier days not yet written
	analyticsKey []byte
	flushMu      sync.Mutex

	tempEvents chan<- Event // to the temporary file's writer, nil when there's none
	tempLost   uint64       // events left unwritten because it was behind
}

func NewRelay(send Sender) *Relay {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic(err)
	}
	r := &Relay{
		cookieKey:  key,
		away:       30 * time.Second,
		clients:    make(map[string]*Client),
		rooms:      make(map[string]*Room),
		banned:     make(map[string]Ban),
		perIP:      make(map[string]int),
		buckets:    make(map[string]*rateBucket),
		rate:       300,
		maxPlayers: 2000,
		started:    time.Now(),
		now:        time.Now,
	}
	r.send = func(data []byte, to *net.UDPAddr) {
		r.total.PacketsOut++
		r.total.BytesOut += uint64(len(data))
		send(data, to)
	}
	return r
}

// AttachStore keeps bans in the store from now on, starting with the ones it holds.
func (r *Relay) AttachStore(store *Store) error {
	bans, err := store.Bans()
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.store = store
	for _, ban := range bans {
		r.banned[ban.IP] = ban
	}
	return nil
}

// record keeps a line for the dashboard. Callers hold the lock.
func (r *Relay) record(text string) {
	r.eventSeq++
	r.events = append(r.events, Event{Seq: r.eventSeq, At: r.now(), Text: text})
	if len(r.events) > maxEvents {
		r.events = r.events[1:]
	}
	if r.tempEvents != nil {
		// Never wait for the disk: a line it's too busy for is only lost from
		// what a restart brings back.
		select {
		case r.tempEvents <- r.events[len(r.events)-1]:
		default:
			r.tempLost++
		}
	}
}

// event records a line and writes it to the log. Callers hold the lock.
func (r *Relay) event(format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	log.Print(text)
	r.record(text)
}

// refuse turns a player away. It stays out of the log, because anyone can
// send these as fast as they like, and the sweep sums them up for the dashboard.
func (r *Relay) refuse(reason string, addr *net.UDPAddr) {
	r.send([]byte("event|error|"+reason), addr)
	if r.tally != nil {
		r.tally.Refused++
	}
	if r.refusals.reasons == nil {
		r.refusals.reasons = make(map[string]int)
	}
	r.refusals.total++
	r.refusals.last = addr.String()
	r.refusals.reasons[reason]++
}

// reportRefusals writes the refusals since the last sweep as one line. A lone one
// reads as it always did. Callers hold the lock.
func (r *Relay) reportRefusals() {
	count := r.refusals
	r.refusals = refusalCount{}
	if count.total == 0 {
		return
	}
	reasons := make([]string, 0, len(count.reasons))
	for reason := range count.reasons {
		reasons = append(reasons, reason)
	}
	sort.Strings(reasons)
	if count.total == 1 {
		r.record(fmt.Sprintf("[REFUSED] %s: %s", count.last, reasons[0]))
		return
	}
	for i, reason := range reasons {
		reasons[i] = fmt.Sprintf("%s (%d)", reason, count.reasons[reason])
	}
	r.record(fmt.Sprintf("[REFUSED] %d times, last %s: %s", count.total, count.last, strings.Join(reasons, ", ")))
}

// allow spends one token from an IP's bucket. Callers hold the lock.
func (r *Relay) allow(ip string) bool {
	if r.rate <= 0 {
		return true
	}
	now := r.now()
	burst := r.rate * 2
	bucket := r.buckets[ip]
	if bucket == nil {
		// Forged sources can't grow this without limit. Nor can they fill it to
		// shut everyone new out: a full table makes room by forgetting an entry at
		// random, which is most likely one of theirs. A forgotten bucket starts
		// full, so the worst it does is give that address a fresh burst.
		if len(r.buckets) >= maxRateEntries {
			for other := range r.buckets {
				delete(r.buckets, other)
				break
			}
		}
		bucket = &rateBucket{tokens: burst, last: now}
		r.buckets[ip] = bucket
	}
	bucket.tokens = min(burst, bucket.tokens+now.Sub(bucket.last).Seconds()*r.rate)
	bucket.last = now
	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens--
	return true
}

// Handle processes one packet from addr.
func (r *Relay) Handle(data []byte, addr *net.UDPAddr) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.total.PacketsIn++
	r.total.BytesIn += uint64(len(data))
	ip := addr.IP.String()
	if _, banned := r.banned[ip]; banned {
		return
	}
	if len(data) > maxPacketBytes || !r.allow(ip) {
		r.dropped++
		return
	}

	client := r.clients[addr.String()]
	if client != nil {
		client.LastSeen = r.now()
		if client.Away {
			client.Away = false
			r.event("[BACK] %v in room %q", client.Addr, client.Room.Code)
			r.announce(client.Room)
		}
	}
	if !bytes.HasPrefix(data, eventPrefix) {
		if client != nil {
			r.forward(client, data)
		}
		return
	}

	parts := strings.SplitN(string(data), "|", 8)
	if client == nil {
		r.register(parts, len(data), addr)
		return
	}
	switch parts[1] {
	case "leave":
		r.event("[LEAVE] %v", client.Addr)
		r.remove(client)
	case "lock":
		r.lock(client.Room)
	case "host", "join", "back":
		// The answer may have been lost, so repeat it.
		r.tell(client)
	}
}

// lock starts a room racing. The game may say so more than once.
func (r *Relay) lock(room *Room) {
	if room.Locked {
		return
	}
	room.Locked = true
	room.Raced = r.now()
	room.Racers = len(room.members())
	if r.tally != nil {
		r.tally.Races++
		r.tally.Racers += room.Racers
	}
}

// dropRoom forgets an empty or closed room, and counts it if it raced.
func (r *Relay) dropRoom(room *Room) {
	delete(r.rooms, room.Code)
	if room.Locked && r.tally != nil {
		r.tally.Finished = append(r.tally.Finished, RaceRecord{
			Started: room.Raced, Ended: r.now(), Players: room.Racers, Proto: room.Proto,
		})
	}
}

// forward passes a packet to the rest of the room, stamped with its sender's
// seat so nobody can pose as someone else. Callers hold the lock.
func (r *Relay) forward(from *Client, data []byte) {
	out := make([]byte, 0, len(data)+2)
	out = strconv.AppendInt(out, int64(from.Slot), 10)
	out = append(out, '|')
	out = append(out, data...)
	for _, client := range from.Room.Seats {
		if client != nil && client != from && !client.Away {
			r.send(out, client.Addr)
		}
	}
}

// tell sends one client the room as it stands: its own seat, the room's code,
// the seats taken, and whether it has locked. From protocol 5 it adds the
// client's own token and the seats that are away. Fields are only ever added
// at the end, and games ignore any they don't know.
func (r *Relay) tell(client *Client) {
	room := client.Room
	seats := make([]string, 0, maxRoomPlayers)
	away := make([]string, 0, maxRoomPlayers)
	for _, member := range room.members() {
		seats = append(seats, strconv.Itoa(member.Slot))
		if member.Away {
			away = append(away, strconv.Itoa(member.Slot))
		}
	}
	locked := 0
	if room.Locked {
		locked = 1
	}
	text := fmt.Sprintf("event|room|%d|%s|%s|%d", client.Slot, room.Code, strings.Join(seats, ","), locked)
	if client.Token != "" {
		text += "|" + client.Token + "|" + strings.Join(away, ",")
	}
	r.send([]byte(text), client.Addr)
}

func (r *Relay) announce(room *Room) {
	for _, member := range room.members() {
		r.tell(member)
	}
}

func validCode(code string) bool {
	if code == "" || len(code) > maxCodeLength {
		return false
	}
	for _, c := range []byte(code) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func validProto(proto string) bool {
	if proto == "" || len(proto) > 4 {
		return false
	}
	_, err := strconv.Atoi(proto)
	return err == nil
}

// bind files a client under its address. unbind takes it out again, leaving its seat.
func (r *Relay) bind(client *Client) {
	r.clients[client.Addr.String()] = client
	r.perIP[client.Addr.IP.String()]++
	if r.tally != nil {
		r.tally.Peak = max(r.tally.Peak, len(r.clients))
	}
}

func (r *Relay) unbind(client *Client) bool {
	key := client.Addr.String()
	if r.clients[key] != client {
		return false
	}
	delete(r.clients, key)
	ip := client.Addr.IP.String()
	if r.perIP[ip]--; r.perIP[ip] <= 0 {
		delete(r.perIP, ip)
	}
	return true
}

// seat adds a client to a room. Callers have checked there's a free seat.
func (r *Relay) seat(room *Room, slot int, addr *net.UDPAddr, token string) *Client {
	client := &Client{Addr: addr, LastSeen: r.now(), Room: room, Slot: slot, Token: token}
	room.Seats[slot-1] = client
	r.bind(client)
	return client
}

func newToken() string {
	raw := make([]byte, tokenBytes)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func (r *Relay) cookieAt(addr *net.UDPAddr, window int64) string {
	mac := hmac.New(sha256.New, r.cookieKey)
	fmt.Fprintf(mac, "%s|%d", addr.String(), window)
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:cookieBytes])
}

func (r *Relay) cookie(addr *net.UDPAddr) string {
	return r.cookieAt(addr, r.now().Unix()/cookieWindow)
}

func (r *Relay) validCookie(cookie string, addr *net.UDPAddr) bool {
	if cookie == "" {
		return false
	}
	window := r.now().Unix() / cookieWindow
	return hmac.Equal([]byte(cookie), []byte(r.cookieAt(addr, window))) ||
		hmac.Equal([]byte(cookie), []byte(r.cookieAt(addr, window-1)))
}

// register handles a host, join or back from an unknown address. Stragglers from
// a race that just ended aren't asking for a room, and get no answer.
//
// From protocol 5 the request is event|INTENT|PROTO|CODE|COOKIE|TOKEN|padding,
// and anything after TOKEN is ignored, so later games can add to it.
func (r *Relay) register(parts []string, size int, addr *net.UDPAddr) {
	if len(parts) < 3 {
		return
	}
	intent := parts[1]
	if intent != "host" && intent != "join" && intent != "back" {
		return
	}
	// Clients from before protocol 2 send event|host|CODE, and show this.
	if len(parts) == 3 {
		if intent != "back" {
			r.visit(addr.IP.String())
			r.refuse(outOfDate, addr)
		}
		return
	}
	proto := parts[2]
	if !validProto(proto) {
		return
	}
	version, _ := strconv.Atoi(proto)
	given := "" // the token of a seat being taken back
	if version >= cookieProto {
		if size < minRegisterBytes || len(parts) < 6 {
			return
		}
		if !r.validCookie(parts[4], addr) {
			r.send([]byte("event|cookie|"+r.cookie(addr)), addr)
			return
		}
		given = parts[5]
	} else if intent == "back" {
		return
	}
	// Past here the address has shown it's real, from protocol 5 on.
	r.visit(addr.IP.String())
	if version < r.minProto {
		r.refuse(outOfDate, addr)
		return
	}
	code := parts[3]
	if version < cookieProto {
		// Older games end the request with the code, so a | is part of it.
		code = strings.Join(parts[3:], "|")
	}
	if !validCode(code) {
		r.refuse("Room codes are 1 to 16 letters or numbers", addr)
		return
	}
	if r.perIP[addr.IP.String()] >= maxPerIP {
		r.refuse("Too many connections from your address", addr)
		return
	}
	// Coming back takes nobody's place, so a full server still lets it in.
	if intent == "back" {
		r.rejoin(code, given, addr)
		return
	}
	if len(r.clients) >= r.maxPlayers {
		r.refuse("The server is full", addr)
		return
	}
	token := ""
	if version >= cookieProto {
		token = newToken()
	}

	switch intent {
	case "host":
		if _, taken := r.rooms[code]; taken {
			r.refuse("That room code is taken", addr)
			return
		}
		if r.maxRooms > 0 && len(r.rooms) >= r.maxRooms {
			r.refuse("The server has no free rooms. Try again soon", addr)
			return
		}
		room := &Room{Code: code, Proto: proto, Since: r.now()}
		r.rooms[code] = room
		r.tell(r.seat(room, 1, addr, token))
		if r.tally != nil {
			r.tally.Rooms++
		}
		r.event("[HOST] %v created room %q", addr, code)
	case "join":
		room, found := r.rooms[code]
		if !found {
			r.refuse("No room with that code", addr)
			return
		}
		if room.Proto != proto {
			r.refuse("That room is on a different version of the game", addr)
			return
		}
		if room.Locked {
			r.refuse("That race has already started", addr)
			return
		}
		for slot := 1; slot <= maxRoomPlayers; slot++ {
			if room.Seats[slot-1] == nil {
				r.seat(room, slot, addr, token)
				if r.tally != nil {
					r.tally.Joins++
				}
				r.event("[JOIN] %v joined room %q in seat %d", addr, code, slot)
				r.announce(room)
				return
			}
		}
		r.refuse("That room is full", addr)
	}
}

// rejoin gives a seat back to its driver at a new address: a phone that changed
// networks, or came back from the background. The token proves whose seat it is.
// A locked room takes them back too, because it's their own seat.
func (r *Relay) rejoin(code, token string, addr *net.UDPAddr) {
	var client *Client
	if room := r.rooms[code]; room != nil && token != "" {
		for _, member := range room.members() {
			if member.Token != "" && subtle.ConstantTimeCompare([]byte(member.Token), []byte(token)) == 1 {
				client = member
			}
		}
	}
	if client == nil {
		r.refuse("Your place in that room has gone", addr)
		return
	}
	old := client.Addr
	r.unbind(client)
	client.Addr, client.LastSeen, client.Away = addr, r.now(), false
	r.bind(client)
	if r.tally != nil {
		r.tally.Backs++
	}
	r.event("[BACK] %v took seat %d in room %q back from %v", addr, client.Slot, code, old)
	r.announce(client.Room)
}

func (r *Relay) forget(client *Client) {
	if r.unbind(client) {
		client.Room.Seats[client.Slot-1] = nil
	}
}

// closeRoom empties a room, telling everyone in it why.
func (r *Relay) closeRoom(room *Room, reason string) {
	for _, member := range room.members() {
		r.send([]byte("event|closed|"+reason), member.Addr)
		r.forget(member)
	}
	r.dropRoom(room)
}

// remove takes one client out. A lobby can't go on without its host, because
// the race is the host's to set. A locked room can: everything needed to race
// again is already with the others.
func (r *Relay) remove(client *Client) {
	room := client.Room
	r.forget(client)
	if client.Slot == 1 && !room.Locked {
		r.closeRoom(room, "The host left the room")
		return
	}
	if len(room.members()) == 0 {
		r.dropRoom(room)
		return
	}
	r.announce(room)
}

// Sweep runs once a second. It drops clients that have gone quiet, giving
// someone alone in a room longer, works out the traffic rates, repeats each
// room's state to everyone still sending, so a lost update heals and clients
// know the relay is alive, and sums up the refusals.
func (r *Relay) Sweep(racing, waiting time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.perSecond = r.total.minus(r.sampled)
	r.sampled = r.total
	r.rollTally()
	if r.tally != nil {
		r.tally.BytesIn += r.perSecond.BytesIn
		r.tally.BytesOut += r.perSecond.BytesOut
	}

	now := r.now()
	for _, client := range r.clients {
		silent := now.Sub(client.LastSeen)
		switch {
		case len(client.Room.members()) == 1:
			if silent > waiting {
				r.event("[TIMEOUT] %v", client.Addr)
				r.remove(client)
			}
		case client.Token == "" && silent > racing, silent > racing+r.away:
			r.event("[TIMEOUT] %v", client.Addr)
			r.remove(client)
		case client.Token != "" && silent > racing && !client.Away:
			// The others hear it from the repeat below.
			client.Away = true
			r.event("[AWAY] %v in room %q", client.Addr, client.Room.Code)
		}
	}
	if r.tally != nil {
		r.tally.Peak = max(r.tally.Peak, len(r.clients))
	}
	// Only to those still talking: an address that sent one packet and went quiet
	// may never have been listening, and mustn't get a stream of answers.
	for _, client := range r.clients {
		if now.Sub(client.LastSeen) <= announceWindow {
			r.tell(client)
		}
	}
	r.reportRefusals()
	for ip, bucket := range r.buckets {
		if now.Sub(bucket.last) > 10*time.Second {
			delete(r.buckets, ip)
		}
	}
}

// Close removes the room the client at addr is in, with everyone in it.
func (r *Relay) Close(addr string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	client := r.clients[addr]
	if client == nil {
		return false
	}
	r.event("[CLOSE] room %q", client.Room.Code)
	r.closeRoom(client.Room, "Room closed by the server")
	return true
}

// Ban ignores an IP until Unban, and removes its clients now. Anyone else in
// their rooms carries on without them. With a store, the ban outlives a restart.
func (r *Relay) Ban(ip, by string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	ban := Ban{IP: parsed.String(), At: r.now(), By: by}
	store := r.ban(ban)
	// The disk is slow next to the relay, so it's kept out of the lock.
	if store != nil {
		if err := store.SaveBan(ban); err != nil {
			log.Printf("[BAN] saving %s: %v", ban.IP, err)
		}
	}
	return true
}

func (r *Relay) ban(ban Ban) *Store {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.banned[ban.IP] = ban
	r.event("[BAN] %s", ban.IP)
	for _, client := range r.clients {
		if client.Addr.IP.String() == ban.IP {
			r.send([]byte("event|closed|Removed by the server"), client.Addr)
			r.remove(client)
		}
	}
	return r.store
}

func (r *Relay) Unban(ip string) {
	r.mu.Lock()
	_, banned := r.banned[ip]
	if banned {
		delete(r.banned, ip)
		r.event("[UNBAN] %s", ip)
	}
	store := r.store
	r.mu.Unlock()

	if banned && store != nil {
		if err := store.DeleteBan(ip); err != nil {
			log.Printf("[UNBAN] saving %s: %v", ip, err)
		}
	}
}

// Shutdown tells everyone the relay is going away. With keep, rooms from protocol
// 5 on are told nothing: they're saved, and their games get back in when the relay
// is up again, as they would after losing the connection.
func (r *Relay) Shutdown(keep bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, room := range r.rooms {
		if !keep || !comesBack(room) {
			r.closeRoom(room, "The server is restarting")
		}
	}
}

// Driver is one seat in a room, for the dashboard.
type Driver struct {
	Slot int
	Addr string
	IP   string
	Away bool
}

// RoomView is a room as the dashboard shows it.
type RoomView struct {
	Code    string
	Drivers []Driver
	First   string // any address in the room, which is what /close takes
	Age     time.Duration
}

// Snapshot is a copy of the relay's state, safe to read without the lock.
type Snapshot struct {
	Uptime     time.Duration
	Players    int
	OpenRooms  int // waiting and racing
	MaxPlayers int
	MaxRooms   int
	Rooms      []RoomView // still open to join
	Races      []RoomView // locked and racing
	Banned     []Ban
	Events     []Event // newest first
	Total      Traffic
	Rate       Traffic
	Dropped    uint64
}

func (r *Relay) Snapshot() Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.now()
	snap := Snapshot{
		Uptime:     now.Sub(r.started),
		Players:    len(r.clients),
		OpenRooms:  len(r.rooms),
		MaxPlayers: r.maxPlayers,
		MaxRooms:   r.maxRooms,
		Total:      r.total,
		Rate:       r.perSecond,
		Dropped:    r.dropped,
	}
	for code, room := range r.rooms {
		view := RoomView{Code: code, Age: now.Sub(room.Since)}
		for _, member := range room.members() {
			view.Drivers = append(view.Drivers, Driver{Slot: member.Slot, Addr: member.Addr.String(), IP: member.Addr.IP.String(), Away: member.Away})
		}
		if len(view.Drivers) > 0 {
			view.First = view.Drivers[0].Addr
		}
		if room.Locked {
			snap.Races = append(snap.Races, view)
		} else {
			snap.Rooms = append(snap.Rooms, view)
		}
	}
	for _, ban := range r.banned {
		snap.Banned = append(snap.Banned, ban)
	}
	sort.Slice(snap.Rooms, func(i, j int) bool { return snap.Rooms[i].Code < snap.Rooms[j].Code })
	sort.Slice(snap.Races, func(i, j int) bool { return snap.Races[i].Code < snap.Races[j].Code })
	sort.Slice(snap.Banned, func(i, j int) bool { return snap.Banned[i].IP < snap.Banned[j].IP })
	for i := len(r.events) - 1; i >= 0; i-- {
		snap.Events = append(snap.Events, r.events[i])
	}
	return snap
}

func main() {
	listen := flag.String("addr", ":8080", "UDP address to listen on")
	racing := flag.Duration("race-timeout", 5*time.Second, "drop a driver in a shared room after this long without packets")
	waiting := flag.Duration("wait-timeout", 60*time.Second, "drop someone alone in a room after this long without packets")
	rate := flag.Float64("rate", 300, "packets a second allowed from one IP, 0 for no limit")
	away := flag.Duration("away-timeout", 30*time.Second, "past -race-timeout, how long a seat waits for its driver to come back (protocol 5 on)")
	minProto := flag.Int("min-proto", 2, "tell games older than this protocol to update; 5 turns away everything without cookies")
	players := flag.Int("max-players", 2000, "players the relay takes at once")
	rooms := flag.Int("max-rooms", 0, "rooms open at once, waiting or racing; 0 for no limit beyond -max-players")
	dashboard := flag.String("dashboard", "", "HTTP address for the dashboard (off if empty)")
	statusAddr := flag.String("status", "", "HTTP address for the public status at /api/status (off if empty)")
	dbPath := flag.String("db", "spppd-relay.db", "SQLite file for bans, dashboard users and analytics; empty keeps them in memory")
	tempPath := flag.String("temp-db", "spppd-relay-temp.db", "SQLite file for rooms and recent activity, so a restart doesn't end races; empty for none")
	analytics := flag.Bool("analytics", false, "count unique IPs (as keyed hashes), rooms, races and traffic")
	analyticsDays := flag.Int("analytics-days", 30, "days to keep the hashed IPs behind the unique counts; daily totals are kept")
	adminUser := flag.String("admin-user", envOr("SPPPD_ADMIN_USER", "admin"), "dashboard user made from SPPPD_ADMIN_PASSWORD when there are no users yet")
	flag.Usage = usage
	flag.Parse()

	store, err := OpenStore(*dbPath)
	if err != nil {
		log.Fatalf("Failed to open the database: %v", err)
	}
	defer store.Close()

	if flag.NArg() > 0 {
		os.Exit(runCommand(store, flag.Args()))
	}
	if *players < 1 || *rooms < 0 {
		log.Fatalf("-max-players must be at least 1, and -max-rooms 0 or more")
	}
	if *analyticsDays < 7 {
		log.Fatalf("-analytics-days must be at least 7")
	}

	// The first user can come from the environment, which is how a container gets
	// one. An existing user is never changed this way, so a password changed on
	// the dashboard stays changed.
	password := envOr("SPPPD_ADMIN_PASSWORD", os.Getenv("SPPPD_DASHBOARD_TOKEN"))
	if password != "" && !store.HasUsers() {
		if err := store.AddUser(*adminUser, password, time.Now()); err != nil {
			log.Fatalf("Failed to add dashboard user %q: %v", *adminUser, err)
		}
		log.Printf("Added dashboard user %q", *adminUser)
	}

	addr, err := net.ResolveUDPAddr("udp", *listen)
	if err != nil {
		log.Fatalf("Failed to resolve UDP address: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("Failed to start UDP listener: %v", err)
	}
	defer conn.Close()
	log.Printf("Relay server listening on %v", conn.LocalAddr())

	relay := NewRelay(func(data []byte, to *net.UDPAddr) {
		if _, err := conn.WriteToUDP(data, to); err != nil {
			log.Printf("[SEND] %v: %v", to, err)
		}
	})
	relay.rate = *rate
	relay.away = *away
	relay.minProto = *minProto
	relay.maxPlayers = *players
	relay.maxRooms = *rooms
	if err := relay.AttachStore(store); err != nil {
		log.Fatalf("Failed to load bans: %v", err)
	}
	stopTemp := func() {}
	if *tempPath != "" {
		temp, err := OpenTempStore(*tempPath)
		if err != nil {
			log.Fatalf("Failed to open the temporary database: %v", err)
		}
		defer temp.Close()
		rooms, drivers, err := relay.LoadTemp(temp, *racing+*away)
		if err != nil {
			log.Printf("[TEMP] %v", err)
		}
		stopTemp = relay.KeepTemp(temp)
		if rooms > 0 {
			relay.Note("[RESTORED] %d rooms with %d drivers from before the restart", rooms, drivers)
		}
	}
	if *analytics {
		key, err := store.AnalyticsKey()
		if err != nil {
			log.Fatalf("Failed to set up analytics: %v", err)
		}
		relay.EnableAnalytics(key)
		log.Printf("Analytics on, keeping hashed IPs for %d days", *analyticsDays)
	}

	if *dashboard != "" {
		server := &http.Server{
			Addr:    *dashboard,
			Handler: newDashboard(relay, store, *analyticsDays),
			// Nobody holds a connection open for nothing.
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      30 * time.Second,
			IdleTimeout:       2 * time.Minute,
			MaxHeaderBytes:    16 << 10,
		}
		go func() {
			log.Printf("Dashboard listening on %s", *dashboard)
			log.Fatalf("Dashboard stopped: %v", server.ListenAndServe())
		}()
	}

	if *statusAddr != "" {
		server := &http.Server{
			Addr:              *statusAddr,
			Handler:           newStatusPage(relay),
			ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout:       10 * time.Second,
			WriteTimeout:      10 * time.Second,
			IdleTimeout:       time.Minute,
			MaxHeaderBytes:    16 << 10,
		}
		go func() {
			log.Printf("Status listening on %s", *statusAddr)
			log.Fatalf("Status stopped: %v", server.ListenAndServe())
		}()
	}

	go func() {
		for range time.Tick(time.Second) {
			relay.Sweep(*racing, *waiting)
		}
	}()
	go func() {
		for now := range time.Tick(time.Minute) {
			relay.FlushAnalytics()
			if err := store.Prune(dayOf(now.AddDate(0, 0, -(*analyticsDays-1))), now); err != nil {
				log.Printf("[PRUNE] %v", err)
			}
		}
	}()

	stop, _ := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop.Done()
		relay.Shutdown(*tempPath != "")
		stopTemp()
		relay.FlushAnalytics()
		store.Close()
		log.Print("Relay server stopped")
		os.Exit(0)
	}()

	// One byte over the limit, so an oversized packet is seen rather than cut.
	buffer := make([]byte, maxPacketBytes+1)
	for {
		n, remote, err := conn.ReadFromUDP(buffer)
		if err != nil || n == 0 {
			continue
		}
		relay.Handle(buffer[:n], remote)
	}
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
