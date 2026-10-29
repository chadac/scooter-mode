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
