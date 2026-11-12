package main

import (
	"context"
	"strings"
	"sync"
	"time"
)

// helperCacheDuration is how long headers without an "expires" field are
// reused, matching Bazel's --credential_helper_cache_duration default.
const helperCacheDuration = 30 * time.Minute

// helperRefreshSlack renews headers this long before they expire, so a call
// that starts just before expiry doesn't arrive with a stale token.
const helperRefreshSlack = 30 * time.Second

// helperCredentials adds a Bazel credential helper's headers to every BES
// call. It reruns the helper when the headers expire, so a build that outlasts
// one token can still report its end. RequireTransportSecurity keeps the
// headers off plaintext connections.
type helperCredentials struct {
	helper string
	uri    string
	now    func() time.Time

	mu      sync.Mutex
	headers map[string]string
	expires time.Time
}

func newHelperCredentials(helper, besBackend string) *helperCredentials {
	return &helperCredentials{helper: helper, uri: helperURI(besBackend), now: time.Now}
}

// helperURI is the URI a credential helper is asked about: https:// for TLS
// endpoints, including ones given without a scheme.
func helperURI(besBackend string) string {
	switch {
	case strings.HasPrefix(besBackend, "grpcs://"):
		return "https://" + strings.TrimPrefix(besBackend, "grpcs://")
	case strings.HasPrefix(besBackend, "grpc://"):
		return "http://" + strings.TrimPrefix(besBackend, "grpc://")
	default:
		return "https://" + besBackend
	}
}

func (c *helperCredentials) GetRequestMetadata(ctx context.Context, _ ...string) (map[string]string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.headers != nil && c.now().Before(c.expires.Add(-helperRefreshSlack)) {
		return c.headers, nil
	}
	headers, expires, err := runCredentialHelper(ctx, c.helper, c.uri)
	if err != nil {
		return nil, err
	}
	md := make(map[string]string, len(headers))
	for k, v := range headers {
		if len(v) > 0 {
			md[strings.ToLower(k)] = strings.Join(v, ",")
		}
	}
	if expires.IsZero() {
		expires = c.now().Add(helperCacheDuration)
	}
	c.headers, c.expires = md, expires
	return md, nil
}

func (c *helperCredentials) RequireTransportSecurity() bool { return true }
