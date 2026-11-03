package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"golang.org/x/term"
)

var errUsage = errors.New("wrong use")

func usage() {
	out := flag.CommandLine.Output()
	fmt.Fprintf(out, `Usage:
  relay [flags]                     run the relay
  relay [-db FILE] user list        list dashboard users
  relay [-db FILE] user add NAME    add a dashboard user
  relay [-db FILE] user passwd NAME set a user's password, ending their logins
  relay [-db FILE] user del NAME    remove a user

Passwords are read from the terminal without echo, or as one line from stdin.

Flags:
`)
	flag.PrintDefaults()
}

// runCommand runs a "user" command against the database and gives an exit code.
func runCommand(store *Store, args []string) int {
	if err := userCommand(store, args, os.Stdin, os.Stdout); err != nil {
		if errors.Is(err, errUsage) {
			usage()
		}
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func userCommand(store *Store, args []string, in io.Reader, out io.Writer) error {
	if len(args) < 2 || args[0] != "user" {
		return fmt.Errorf("%w: unknown command", errUsage)
	}
	switch command := args[1]; {
	case command == "list" && len(args) == 2:
		users, err := store.Users()
		if err != nil {
			return err
		}
		for _, user := range users {
			fmt.Fprintf(out, "%s\tadded %s\n", user.Name, formatDate(user.Created))
		}
		return nil
	case len(args) != 3:
		return fmt.Errorf("%w: give one NAME", errUsage)
	case command == "add":
		password, err := readPassword(in, out, "Password for "+args[2])
		if err != nil {
			return err
		}
		if err := store.AddUser(args[2], password, time.Now()); err != nil {
			return err
		}
		fmt.Fprintf(out, "Added %s\n", args[2])
	case command == "passwd":
		password, err := readPassword(in, out, "New password for "+args[2])
		if err != nil {
			return err
		}
		if err := store.SetPassword(args[2], password); err != nil {
			return err
		}
		fmt.Fprintf(out, "Changed the password for %s and ended their logins\n", args[2])
	case command == "del":
		if err := store.DeleteUser(args[2]); err != nil {
			return err
		}
		fmt.Fprintf(out, "Removed %s\n", args[2])
	default:
		return fmt.Errorf("%w: unknown command %q", errUsage, command)
	}
	return nil
}

// readPassword asks twice on a terminal, without echo. Anything else gives it as
// one line, so it can be piped in.
func readPassword(in io.Reader, out io.Writer, prompt string) (string, error) {
	if file, ok := in.(*os.File); ok && term.IsTerminal(int(file.Fd())) {
		fmt.Fprint(out, prompt+": ")
		first, err := term.ReadPassword(int(file.Fd()))
		fmt.Fprintln(out)
		if err != nil {
			return "", err
		}
		fmt.Fprint(out, "Again: ")
		second, err := term.ReadPassword(int(file.Fd()))
		fmt.Fprintln(out)
		if err != nil {
			return "", err
		}
		if string(first) != string(second) {
			return "", errors.New("the passwords don't match")
		}
		return string(first), nil
	}
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && !(errors.Is(err, io.EOF) && line != "") {
		return "", errors.New("no password given")
	}
	return strings.TrimRight(line, "\r\n"), nil
}
