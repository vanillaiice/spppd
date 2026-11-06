package main

// The probe checks that a relay answers, without taking a seat. A protocol 5 ask
// without a cookie only gets a cookie back: the relay counts no visitor, writes no
// activity and makes no room, so checking the official server leaves its analytics
// and dashboard alone. Only the bytes count.

import (
	"fmt"
	"net"
	"strings"
	"time"
)

// probe asks the relay at address for a cookie, a few times within timeout.
func probe(address string, timeout time.Duration) error {
	conn, err := net.Dial("udp", address)
	if err != nil {
		return err
	}
	defer conn.Close()
	ask := []byte(fmt.Sprintf("event|host|%d|PROBE||", cookieProto))
	if pad := minRegisterBytes - len(ask); pad > 0 {
		ask = append(ask, []byte("|"+strings.Repeat(".", pad-1))...)
	}
	deadline := time.Now().Add(timeout)
	reply := make([]byte, maxPacketBytes)
	for time.Now().Before(deadline) {
		if _, err := conn.Write(ask); err != nil {
			return err
		}
		wait := time.Now().Add(500 * time.Millisecond)
		if wait.After(deadline) {
			wait = deadline
		}
		_ = conn.SetReadDeadline(wait)
		n, err := conn.Read(reply)
		if err != nil {
			// Lost, or the relay isn't up yet. A refusal comes back at once, so wait.
			time.Sleep(time.Until(wait))
			continue
		}
		if strings.HasPrefix(string(reply[:n]), "event|cookie|") {
			return nil
		}
		return fmt.Errorf("unexpected answer %q", reply[:n])
	}
	return fmt.Errorf("no answer from %s within %v", address, timeout)
}

func probeCommand(args []string) int {
	if len(args) != 2 {
		usage()
		return 1
	}
	timeout := 3 * time.Second
	if err := probe(args[1], timeout); err != nil {
		fmt.Println(err)
		return 1
	}
	fmt.Printf("The relay at %s answers (protocol %d)\n", args[1], cookieProto)
	return 0
}
