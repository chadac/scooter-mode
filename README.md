# scooter-mode

Use [Scooter](https://github.com/chadac/scooter) from Emacs: browse and start
conversations on one or more Scooter servers, chat through
[agent-shell](https://github.com/xenodium/agent-shell), and sign in behind
oauth2-proxy.

Work in progress.

## Emacs

Needs Emacs 29.1+, `magit-section`, `transient`, `agent-shell` and `curl`, plus
the `scooter` binary on `PATH` (`nix profile install github:chadac/scooter-mode`).

```elisp
(add-to-list 'load-path "~/src/scooter-mode/lisp")
(require 'scooter)
(require 'scooter-project)          ; C-x p p and Projectile hooks
(server-start)                      ; lets the bridge refresh logins
(keymap-global-set "C-c s" scooter-command-map)

(setq scooter-servers
      '((home :url "https://scooter.example.org" :auth cookie)
        (work :url "https://scooter.corp.example"
              :auth (oidc :issuer "https://oauth.id.jumpcloud.com/"
                          :client-id "scooter-emacs"))))
```

- `C-c s l` lists conversations on every server, grouped by status. `RET`
  opens one in agent-shell; `c` new, `s` star, `t` retitle, `k` stop the run,
  `z` suspend, `f` files viewer, `b` browser, `g` refresh, `?` menu.
- `C-c s c`, `C-c s r`, `C-c s p` start a conversation from a prompt, the
  region, or the current project; `C-c s R` sends the region to an existing
  one.
- Auth: `cookie` asks for the `_oauth2_proxy` cookie (or reads it from
  auth-source, host = the server, user = `_oauth2_proxy`). `oidc` logs in
  through the browser with PKCE; oauth2-proxy must run with
  `--skip-jwt-bearer-tokens` and accept the client as an extra JWT issuer.
  GitHub issues no ID tokens, so GitHub-backed servers use `cookie`.

## `scooter acp`

`scooter acp --server https://scooter.example.org` is an
[ACP](https://agentclientprotocol.com) agent on stdin/stdout. A new ACP session
creates a Scooter conversation; `--conversation <id>` attaches the first one to
an existing conversation instead. Auth headers come from
`--headers-command` (or `--headers-file`), as a JSON object such as
`{"Authorization": "Bearer …"}` or `{"Cookie": "_oauth2_proxy=…"}`. The command
is rerun once when the server's auth proxy rejects a request, with `{retry}`
in it replaced by `t` (otherwise `nil`).

Prebuilt static binaries for Linux and macOS (amd64, arm64) are attached to
each [GitHub release](https://github.com/chadac/scooter-mode/releases), with
`SHA256SUMS`; `scooter version` prints the release. Or run it with Nix:

```sh
nix run github:chadac/scooter-mode -- acp --server https://scooter.example.org \
  --headers-command 'pass show scooter/headers'
```
