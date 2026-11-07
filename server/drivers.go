package main

// Drivers: a name that every room shows, kept with a key on each device it's
// signed in on. There's no email and no password. The game makes a device key
// and a recovery key when the player picks a name, sends each once, and from then
// on proves it holds one with an HMAC over the relay's cookie, which only its own
// address sees and which changes every 30 seconds.
//
// Every driver and key is held in memory, so checking a proof never touches the
// disk. Changes are made to memory under the lock and handed to one goroutine
// that writes them, as the temporary store does. When it's too far behind, a
// request is dropped unanswered and the game asks again.

import (
	"crypto/hmac"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	driverKeyBytes  = 16
	proofChars      = 22
	maxDeviceKeys   = 10
	maxLabel        = 16
	firstDriverID   = 1001
	renameEvery     = 30 * 24 * time.Hour
	signupsPerHour  = 3
	recoversPerHour = 10
	driverQueue     = 256
	notRecovered    = "That recovery code isn't right"
)

// Answers to a driver request, as the game reads them:
//
//	event|driver|ID|NAME           you are driver ID (sign-up, recover, rename)
//	event|profile|NAME|SINCE|DEVICES|ID
//	event|signedout|ID             this device isn't signed in to ID, or no longer
//	event|nodriver|ID              there's no driver ID (any more)
//	event|denied|INTENT|MESSAGE    the request was turned down
var driverIntents = map[string]bool{
	"signup": true, "recover": true, "signout": true, "rename": true, "forget": true, "profile": true,
}

// Account is one driver. Named so as not to clash with Driver, a seat on the dashboard.
type Account struct {
	ID       int
	Name     string
	Recovery []byte
	Created  time.Time
	Seen     string    // the day of the last sign-in
	Renamed  time.Time // zero until the first rename
	Banned   bool
	Keys     []*DeviceKey
}

// DeviceKey is one device a driver is signed in on.
type DeviceKey struct {
	ID    int
	Key   []byte
	Label string // "Android", "Linux"…
	Added string // days, not times
	Seen  string
}

// hourCount counts requests from one address, or for one driver, in an hour.
type hourCount struct {
	Since time.Time
	N     int
}

// Names --------------------------------------------------------------------------

var (
	nameShape = regexp.MustCompile(`^[A-Z0-9_-]{3,12}$`)
	// Kept for the server, or likely to confuse: DRIVER1042 is what the dashboard
	// renames someone to.
	reservedNames = []string{"ADMIN", "SPPPD", "SERVER", "MOD", "MODERATOR", "DELETED", "SYSTEM", "RELAY",
		"OFFICIAL", "STAFF", "YOU", "HOST", "NOBODY", "ANONYMOUS"}
	serverName = regexp.MustCompile(`^DRIVER[0-9]+$`)
	// Look-alikes folded before the blocklist is checked.
	lookAlikes = strings.NewReplacer("0", "O", "1", "I", "3", "E", "4", "A", "5", "S", "7", "T", "8", "B", "_", "", "-", "")
)

//go:embed blocked_names.txt
var blockedNamesText string

var blockedNames = func() []string {
	var out []string
	for _, line := range strings.Split(blockedNamesText, "\n") {
		line = strings.ToUpper(strings.TrimSpace(line))
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out
}()

// cleanName checks a name a player picked, and gives it in capitals.
func cleanName(raw string) (string, error) {
	name := strings.ToUpper(raw)
	if !nameShape.MatchString(name) {
		return "", fmt.Errorf("Names are 3 to 12 letters, numbers, - or _")
	}
	for _, reserved := range reservedNames {
		if name == reserved {
			return "", fmt.Errorf("That name is kept for the server")
		}
	}
	if serverName.MatchString(name) {
		return "", fmt.Errorf("That name is kept for the server")
	}
	folded := lookAlikes.Replace(name)
	for _, word := range blockedNames {
		if strings.Contains(folded, word) {
			return "", fmt.Errorf("That name isn't allowed")
		}
	}
	return name, nil
}

// Proofs -------------------------------------------------------------------------

// proofOf is what a game holding key sends to prove it: the start of an HMAC of
// the message, in base64url. The message always holds the cookie.
func proofOf(key []byte, message string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(message))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))[:proofChars]
}

func proofMatches(key []byte, message, proof string) bool {
	return len(proof) == proofChars && hmac.Equal([]byte(proofOf(key, message)), []byte(proof))
}

// decodeKey reads a key the game made, sent in base64url.
func decodeKey(text string) ([]byte, bool) {
	key, err := base64.RawURLEncoding.DecodeString(text)
	return key, err == nil && len(key) == driverKeyBytes
}

func cleanLabel(raw string) string {
	out := make([]byte, 0, maxLabel)
	for _, c := range []byte(raw) {
		if len(out) == maxLabel {
			break
		}
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == ' ' {
			out = append(out, c)
		}
	}
	if len(out) == 0 {
		return "Unknown"
	}
	return string(out)
}

// signedIn finds the driver behind an ACCOUNT and PROOF pair, and which of its
// keys made the proof. A missing or wrong proof is no driver. Callers hold the lock
// and have checked the cookie.
func (r *Relay) signedIn(id, proof, intent, cookie string) (*Account, *DeviceKey) {
	n, err := strconv.Atoi(id)
	if err != nil || proof == "" {
		return nil, nil
	}
	account := r.accounts[n]
	if account == nil {
		return nil, nil
	}
	message := intent + "|" + cookie
	for _, key := range account.Keys {
		if proofMatches(key.Key, message, proof) {
			r.seenToday(account, key)
			return account, key
		}
	}
	return nil, nil
}

// seenToday notes the day a driver and one of its devices were last used. It
// writes at most once a day for each.
func (r *Relay) seenToday(account *Account, key *DeviceKey) {
	today := dayOf(r.now())
	if account.Seen == today && key.Seen == today {
		return
	}
	if !r.canWrite() {
		return
	}
	account.Seen, key.Seen = today, today
	id, keyID := account.ID, key.ID
	r.write(func(s *Store) error { return s.SeeDriver(id, keyID, today) })
}

// Writing ------------------------------------------------------------------------

// canWrite says whether a change can be queued for the disk. Only Handle queues,
// under the lock, so a yes holds until the change is queued.
func (r *Relay) canWrite() bool {
	return r.driverWrites == nil || len(r.driverWrites) < cap(r.driverWrites)
}

func (r *Relay) write(change func(*Store) error) {
	if r.driverWrites != nil {
		r.driverWrites <- change
	}
}

// KeepDrivers loads every driver from the store, and writes changes to it from
// now on. stop writes what's waiting and returns.
func (r *Relay) KeepDrivers(store *Store) (stop func(), err error) {
	accounts, err := store.Drivers()
	if err != nil {
		return nil, err
	}
	last, err := store.LastDriverID()
	if err != nil {
		return nil, err
	}
	writes := make(chan func(*Store) error, driverQueue)
	r.mu.Lock()
	for _, account := range accounts {
		r.addAccount(account)
	}
	r.nextDriver = max(r.nextDriver, last+1)
	r.driverWrites = writes
	r.mu.Unlock()

	done := make(chan struct{})
	go func() {
		defer close(done)
		for change := range writes {
			if err := change(store); err != nil {
				log.Printf("[DRIVERS] saving: %v", err)
			}
		}
	}()
	return func() {
		r.mu.Lock()
		r.driverWrites = nil
		r.mu.Unlock()
		close(writes)
		<-done
	}, nil
}

func (r *Relay) addAccount(account *Account) {
	r.accounts[account.ID] = account
	r.names[account.Name] = account.ID
	r.nextDriver = max(r.nextDriver, account.ID+1)
	for _, key := range account.Keys {
		r.nextKey = max(r.nextKey, key.ID+1)
	}
}

// Requests -----------------------------------------------------------------------

// allowHourly counts one request against key in counts, and says whether it's
// within limit. Forged sources can't fill the table: past its size, one entry
// is forgotten at random.
func (r *Relay) allowHourly(counts map[string]*hourCount, key string, limit int) bool {
	now := r.now()
	c := counts[key]
	if c == nil || now.Sub(c.Since) >= time.Hour {
		if c == nil && len(counts) >= maxRateEntries {
			for other := range counts {
				delete(counts, other)
				break
			}
		}
		c = &hourCount{Since: now}
		counts[key] = c
	}
	if c.N >= limit {
		return false
	}
	c.N++
	return true
}

func (r *Relay) deny(intent, message string, addr *net.UDPAddr) {
	r.send([]byte("event|denied|"+intent+"|"+message), addr)
}

func (r *Relay) tellDriver(account *Account, addr *net.UDPAddr) {
	r.send([]byte(fmt.Sprintf("event|driver|%d|%s", account.ID, account.Name)), addr)
}

// driverRequest handles a sign-up and everything else to do with a driver, from
// any address, in a room or not. Each is event|INTENT|PROTO|COOKIE|… padded as a
// seat request is, and answered only once the cookie is right.
func (r *Relay) driverRequest(parts []string, size int, addr *net.UDPAddr) {
	if size < minRegisterBytes || len(parts) < 5 {
		return
	}
	version, err := strconv.Atoi(parts[2])
	if err != nil || version < cookieProto {
		return
	}
	cookie := parts[3]
	if !r.validCookie(cookie, addr) {
		r.send([]byte("event|cookie|"+r.cookie(addr)), addr)
		return
	}
	intent := parts[1]
	switch intent {
	case "signup":
		r.signUp(field(parts, 4), field(parts, 5), field(parts, 6), field(parts, 7), addr)
	case "recover":
		r.recover(field(parts, 4), field(parts, 5), field(parts, 6), field(parts, 7), cookie, addr)
	default:
		r.driverAction(intent, field(parts, 4), field(parts, 5), parts, cookie, addr)
	}
}

// signUp makes a driver. Asked again with the same name and keys, because the
// answer was lost, it answers again.
func (r *Relay) signUp(rawName, keyText, recoveryText, label string, addr *net.UDPAddr) {
	key, okKey := decodeKey(keyText)
	recovery, okRecovery := decodeKey(recoveryText)
	if !okKey || !okRecovery {
		return
	}
	name, err := cleanName(rawName)
	if err != nil {
		r.deny("signup", err.Error(), addr)
		return
	}
	if id, taken := r.names[name]; taken {
		account := r.accounts[id]
		if hmac.Equal(account.Recovery, recovery) && hasKey(account, key) {
			r.tellDriver(account, addr)
		} else {
			r.deny("signup", "That name is taken", addr)
		}
		return
	}
	if !r.canWrite() {
		return
	}
	if !r.allowHourly(r.signups, addr.IP.String(), signupsPerHour) {
		r.deny("signup", "Too many new drivers from your address. Try again in an hour", addr)
		return
	}
	now := r.now()
	today := dayOf(now)
	account := &Account{
		ID: r.nextDriver, Name: name, Recovery: recovery, Created: now, Seen: today,
		Keys: []*DeviceKey{{ID: r.nextKey, Key: key, Label: cleanLabel(label), Added: today, Seen: today}},
	}
	r.addAccount(account)
	// The writer reads its own copy, never what the lock guards.
	saved, first := *account, *account.Keys[0]
	saved.Keys = []*DeviceKey{&first}
	r.write(func(s *Store) error { return s.AddDriver(&saved) })
	if r.tally != nil {
		r.tally.Signups++
	}
	r.event("[DRIVER] %s signed up as %d from %v", name, account.ID, addr)
	r.tellDriver(account, addr)
}

func hasKey(account *Account, key []byte) bool {
	for _, k := range account.Keys {
		if hmac.Equal(k.Key, key) {
			return true
		}
	}
	return false
}

// recover signs a new device in with the recovery code. The proof covers the new
// device's key, so a proof seen on the way can't add a different one. Past the
// limit, the device seen least recently is dropped.
func (r *Relay) recover(id, keyText, label, proof, cookie string, addr *net.UDPAddr) {
	key, ok := decodeKey(keyText)
	if !ok {
		return
	}
	if !r.allowHourly(r.recoversByIP, addr.IP.String(), recoversPerHour) ||
		!r.allowHourly(r.recoversByDriver, id, recoversPerHour) {
		r.deny("recover", "Too many tries. Try again in an hour", addr)
		return
	}
	n, _ := strconv.Atoi(id)
	account := r.accounts[n]
	if account == nil || !proofMatches(account.Recovery, "recover|"+cookie+"|"+keyText, proof) {
		r.deny("recover", notRecovered, addr)
		return
	}
	if hasKey(account, key) {
		r.tellDriver(account, addr)
		return
	}
	if !r.canWrite() {
		return
	}
	today := dayOf(r.now())
	device := &DeviceKey{ID: r.nextKey, Key: key, Label: cleanLabel(label), Added: today, Seen: today}
	r.nextKey++
	account.Keys = append(account.Keys, device)
	account.Seen = today
	var dropped []int
	if len(account.Keys) > maxDeviceKeys {
		sort.SliceStable(account.Keys, func(i, j int) bool {
			a, b := account.Keys[i], account.Keys[j]
			if a.Seen != b.Seen {
				return a.Seen > b.Seen
			}
			return a.ID > b.ID
		})
		for _, old := range account.Keys[maxDeviceKeys:] {
			dropped = append(dropped, old.ID)
		}
		account.Keys = account.Keys[:maxDeviceKeys]
	}
	added, driverID := *device, account.ID
	r.write(func(s *Store) error { return s.AddDeviceKey(driverID, &added, dropped, today) })
	r.event("[DRIVER] %s signed in on another device from %v", account.Name, addr)
	r.tellDriver(account, addr)
}

// driverAction is a request from a device already signed in: event|INTENT|PROTO|
// COOKIE|ID|PROOF|…, with the new name after the proof for a rename.
func (r *Relay) driverAction(intent, id, proof string, parts []string, cookie string, addr *net.UDPAddr) {
	n, err := strconv.Atoi(id)
	if err != nil {
		return
	}
	if r.accounts[n] == nil {
		r.send([]byte("event|nodriver|"+id), addr)
		return
	}
	account, key := r.signedIn(id, proof, intent, cookie)
	if account == nil {
		r.send([]byte("event|signedout|"+id), addr)
		return
	}
	switch intent {
	case "profile":
		r.send([]byte(fmt.Sprintf("event|profile|%s|%s|%d|%d", account.Name, dayOf(account.Created), len(account.Keys), account.ID)), addr)
	case "rename":
		name, err := cleanName(field(parts, 6))
		if err != nil {
			r.deny(intent, err.Error(), addr)
			return
		}
		if name == account.Name {
			r.tellDriver(account, addr)
			return
		}
		if other, taken := r.names[name]; taken && other != account.ID {
			r.deny(intent, "That name is taken", addr)
			return
		}
		if wait := account.Renamed.Add(renameEvery).Sub(r.now()); !account.Renamed.IsZero() && wait > 0 {
			days := int((wait + 24*time.Hour - 1) / (24 * time.Hour))
			r.deny(intent, fmt.Sprintf("You can rename again in %d days", days), addr)
			return
		}
		if !r.canWrite() {
			return
		}
		r.renameAccount(account, name, r.now())
		r.tellDriver(account, addr)
	case "signout":
		if !r.canWrite() {
			return
		}
		for i, k := range account.Keys {
			if k == key {
				account.Keys = append(account.Keys[:i:i], account.Keys[i+1:]...)
				break
			}
		}
		keyID := key.ID
		r.write(func(s *Store) error { return s.DeleteDeviceKey(keyID) })
		r.send([]byte("event|signedout|"+id), addr)
	case "forget":
		if !r.canWrite() {
			return
		}
		r.forgetAccount(account)
		r.event("[DRIVER] %d deleted itself", account.ID)
		r.send([]byte("event|nodriver|"+id), addr)
	}
}

// renameAccount gives a driver a new name. Rooms show it from their next update.
// Callers hold the lock and have checked canWrite.
func (r *Relay) renameAccount(account *Account, name string, at time.Time) {
	delete(r.names, account.Name)
	old := account.Name
	account.Name, account.Renamed = name, at
	r.names[name] = account.ID
	id := account.ID
	r.write(func(s *Store) error { return s.RenameDriver(id, name, at) })
	r.event("[DRIVER] %s is now %s", old, name)
}

// forgetAccount deletes a driver at once. Seats it holds race on without a name.
func (r *Relay) forgetAccount(account *Account) {
	delete(r.accounts, account.ID)
	delete(r.names, account.Name)
	for _, client := range r.clients {
		if client.Account == account {
			client.Account = nil
		}
	}
	id := account.ID
	r.write(func(s *Store) error { return s.DeleteDriver(id) })
}

// names is the names of the seats in a room that signed in: "2:BOB,3:AL".
func (room *Room) names() string {
	var out []string
	for _, member := range room.members() {
		if member.Account != nil {
			out = append(out, fmt.Sprintf("%d:%s", member.Slot, member.Account.Name))
		}
	}
	return strings.Join(out, ",")
}

// sweepDrivers forgets request counts more than an hour old. Callers hold the lock.
func (r *Relay) sweepDrivers() {
	now := r.now()
	for _, counts := range []map[string]*hourCount{r.signups, r.recoversByIP, r.recoversByDriver} {
		for key, c := range counts {
			if now.Sub(c.Since) >= time.Hour {
				delete(counts, key)
			}
		}
	}
}

// For the dashboard ----------------------------------------------------------------

// DriverView is a driver as the dashboard shows it. Keys show only their label and days.
type DriverView struct {
	ID      int
	Name    string
	Created time.Time
	Seen    string
	Banned  bool
	Devices []DeviceView
}

type DeviceView struct {
	Label, Added, Seen string
}

const maxDriverResults = 50

// FindDrivers lists drivers whose name holds query, or the driver with that number,
// newest first. An empty query lists the newest.
func (r *Relay) FindDrivers(query string) (views []DriverView, total int) {
	r.mu.Lock()
	defer r.mu.Unlock()

	query = strings.ToUpper(strings.TrimSpace(query))
	var found []*Account
	for _, account := range r.accounts {
		if query == "" || strings.Contains(account.Name, query) || strconv.Itoa(account.ID) == query {
			found = append(found, account)
		}
	}
	sort.Slice(found, func(i, j int) bool { return found[i].ID > found[j].ID })
	total = len(r.accounts)
	for i, account := range found {
		if i == maxDriverResults {
			break
		}
		view := DriverView{ID: account.ID, Name: account.Name, Created: account.Created, Seen: account.Seen, Banned: account.Banned}
		for _, key := range account.Keys {
			view.Devices = append(view.Devices, DeviceView{Label: key.Label, Added: key.Added, Seen: key.Seen})
		}
		views = append(views, view)
	}
	return views, total
}

// ResetDriverName renames a driver to DRIVER and its number, for a name that
// shouldn't be shown. Their game hears it from the next room or profile.
func (r *Relay) ResetDriverName(id int, by string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	account := r.accounts[id]
	if account == nil || !r.canWrite() {
		return false
	}
	name := fmt.Sprintf("DRIVER%d", id)
	if account.Name != name {
		r.renameAccount(account, name, account.Renamed) // doesn't use up their own rename
		r.event("[DRIVER] renamed by %s", by)
	}
	return true
}

// BanDriver keeps a driver out of every room, or lets them back in. Seats they
// hold now are closed with the ban.
func (r *Relay) BanDriver(id int, banned bool, by string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	account := r.accounts[id]
	if account == nil || !r.canWrite() {
		return false
	}
	account.Banned = banned
	r.write(func(s *Store) error { return s.BanDriver(id, banned) })
	if banned {
		r.event("[BAN] driver %s (%d) by %s", account.Name, id, by)
		for _, client := range r.clients {
			if client.Account == account {
				r.send([]byte("event|closed|"+bannedDriver), client.Addr)
				r.remove(client)
			}
		}
	} else {
		r.event("[UNBAN] driver %s (%d) by %s", account.Name, id, by)
	}
	return true
}

const bannedDriver = "This driver is banned"
