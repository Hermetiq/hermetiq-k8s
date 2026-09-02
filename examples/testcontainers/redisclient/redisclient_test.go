package redisclient

import (
	"context"
	"testing"
	"time"

	tcredis "github.com/testcontainers/testcontainers-go/modules/redis"
)

// TestRoundTrip spins up a Redis container via Testcontainers and verifies
// that RoundTrip can SET and then GET a value. The BUILD file sets
// exec_properties = {"pool": "testcontainers"} so Buildbarn routes the action
// to the Testcontainers worker fleet, where a Docker-in-Docker sidecar provides
// the daemon.
func TestRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	container, err := tcredis.Run(ctx, "redis:7-alpine")
	if err != nil {
		t.Fatalf("start redis container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(context.Background()); err != nil {
			t.Logf("terminate redis container: %v", err)
		}
	})

	host, err := container.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := container.MappedPort(ctx, "6379/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}
	addr := host + ":" + port.Port()

	got, err := RoundTrip(ctx, addr, "k", "v")
	if err != nil {
		t.Fatalf("round trip: %v", err)
	}
	if got != "v" {
		t.Fatalf("got %q, want %q", got, "v")
	}
}
