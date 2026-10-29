// Command scooter connects local tools to a Scooter server.
//
//	scooter acp --server URL [flags]   ACP agent on stdio (agent-shell)
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("scooter: ")
	if len(os.Args) < 2 || os.Args[1] != "acp" {
		fmt.Fprintln(os.Stderr, "usage: scooter acp --server URL [--conversation ID] [--model M] [--project] [--headers-command CMD | --headers-file PATH]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet("acp", flag.ExitOnError)
	server := fs.String("server", "", "Scooter base URL")
	conversation := fs.String("conversation", "", "attach the first new session to this conversation id")
	model := fs.String("model", "", "model for new conversations (default: the server's)")
	project := fs.Bool("project", false, "put the working directory's git remote and branch in the first prompt")
	headersCmd := fs.String("headers-command", "", "shell command printing the auth headers as a JSON object; {retry} becomes t after an auth wall")
	headersFile := fs.String("headers-file", "", "file holding the auth headers as a JSON object")
	_ = fs.Parse(os.Args[2:]) // ExitOnError: it exits rather than returning one.
	if *server == "" {
		log.Fatal("--server is required")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	c := newClient(*server, headerSource{command: *headersCmd, file: *headersFile})
	out := newRPC(os.Stdout)
	a := newAgent(ctx, c, out, agentOptions{conversation: *conversation, model: *model, project: *project})
	if err := out.serve(ctx, os.Stdin, a.handle, a.notify); err != nil {
		log.Fatal(err)
	}
}
