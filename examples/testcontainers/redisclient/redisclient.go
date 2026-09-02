// Package redisclient is a thin wrapper around go-redis used by the
// Testcontainers smoke test in the same package. It exists so the test has
// something to exercise — the real point of the example is that the test
// itself runs on the Buildbarn `pool=testcontainers` worker fleet, where
// the Docker-in-Docker sidecar provides the daemon Testcontainers needs.
package redisclient

import (
	"context"

	"github.com/redis/go-redis/v9"
)

// RoundTrip connects to the Redis instance at addr (host:port), writes
// value under key, reads it back, and returns the read value.
func RoundTrip(ctx context.Context, addr, key, value string) (string, error) {
	rdb := redis.NewClient(&redis.Options{Addr: addr})
	defer rdb.Close()
	if err := rdb.Set(ctx, key, value, 0).Err(); err != nil {
		return "", err
	}
	return rdb.Get(ctx, key).Result()
}
