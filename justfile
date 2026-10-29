# scooter-mode task runner: `just` with no args lists recipes.

default:
    @just --list

# Evaluate the flake structure (fast; does not build derivations).
check-flake:
    nix flake show

# Fail on unformatted Go files.
check-fmt:
    test -z "$(gofmt -l .)"

# go vet plus golangci-lint's default linters.
lint:
    go vet ./...
    golangci-lint run ./...

# Unit tests against a fake Scooter server, with the race detector.
test-unit:
    go test -race ./...

# Fast checks, as CI runs them.
ci: check-flake check-fmt lint test-unit
    @echo "✅ ci passed"

# Static release binaries in dist/, one per OS/arch, plus SHA256SUMS.
dist version="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf dist && mkdir dist
    for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
      os=${target%/*} arch=${target#*/}
      CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
        -ldflags "-s -w -X main.version={{version}}" \
        -o "dist/scooter-$os-$arch" ./cmd/scooter
    done
    (cd dist && sha256sum scooter-* > SHA256SUMS)
