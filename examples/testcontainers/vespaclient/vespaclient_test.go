package vespaclient

import (
	"context"
	"embed"
	"io/fs"
	"strings"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

//go:embed testapp
var testappFS embed.FS

// TestVespaDeployFeedQuery exercises a real Vespa workflow end-to-end:
//
//   1. Start vespaengine/vespa:8 in a container via testcontainers-go.
//   2. Wait for the config server (port 19071) to be reachable.
//   3. Zip and deploy the embedded testapp application package.
//   4. Wait for the container service (port 8080) to finish loading the
//      schema and respond 200 on /ApplicationStatus.
//   5. Feed one document.
//   6. Query for it; assert at least one hit and that the returned id matches.
//
// The Buildbarn scheduler routes this action to the Testcontainers worker
// fleet via exec_properties = {"pool": "testcontainers"} in the BUILD file.
// Vespa cold-starts take 30-60s and the deploy/index cycle adds another
// 15-30s, so we budget 5 minutes for the whole test.
func TestVespaDeployFeedQuery(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Sub-FS rooted at the testapp/ directory so paths inside the zip match
	// Vespa's expectations (services.xml, hosts.xml, schemas/doc.sd at root).
	appFS, err := fs.Sub(testappFS, "testapp")
	if err != nil {
		t.Fatalf("fs.Sub(testapp): %v", err)
	}

	req := testcontainers.ContainerRequest{
		Image:        "vespaengine/vespa:8",
		ExposedPorts: []string{"19071/tcp", "8080/tcp"},
		// Config server is the first thing to come up. We use it as the
		// readiness signal for "container is alive enough to accept deploys."
		WaitingFor: wait.ForHTTP("/state/v1/health").
			WithPort("19071/tcp").
			WithStartupTimeout(3 * time.Minute),
	}
	container, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		t.Fatalf("start vespa container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(context.Background()); err != nil {
			t.Logf("terminate vespa: %v", err)
		}
	})

	host, err := container.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	configPort, err := container.MappedPort(ctx, "19071/tcp")
	if err != nil {
		t.Fatalf("config server port: %v", err)
	}
	queryPort, err := container.MappedPort(ctx, "8080/tcp")
	if err != nil {
		t.Fatalf("query port: %v", err)
	}
	configURL := "http://" + host + ":" + configPort.Port()
	queryURL := "http://" + host + ":" + queryPort.Port()
	t.Logf("vespa config server: %s", configURL)
	t.Logf("vespa container endpoint: %s", queryURL)

	zipBytes, err := BuildAppPackage(appFS)
	if err != nil {
		t.Fatalf("build app package: %v", err)
	}
	t.Logf("application package: %d bytes", len(zipBytes))

	if err := DeployApp(ctx, configURL, zipBytes); err != nil {
		t.Fatalf("deploy app: %v", err)
	}

	if err := WaitForAppReady(ctx, queryURL); err != nil {
		t.Fatalf("wait for app ready: %v", err)
	}

	if err := FeedDoc(ctx, queryURL, "doc", "1", map[string]any{
		"title": "hello vespa",
		"body":  "this is a testcontainers smoke test running on buildbarn",
	}); err != nil {
		t.Fatalf("feed doc: %v", err)
	}

	// Give the indexer a moment to make the freshly fed doc visible. Vespa
	// is "real-time" but there's still a tiny consistency window after the
	// write returns.
	time.Sleep(2 * time.Second)

	result, err := Query(ctx, queryURL, `select * from doc where title contains "hello"`)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result.Root.Children) == 0 {
		t.Fatalf("expected at least 1 hit, got 0 (totalCount=%d)", result.Root.Fields.TotalCount)
	}
	got := result.Root.Children[0]
	if !strings.HasSuffix(got.ID, "::1") {
		t.Errorf("hit id %q doesn't reference docid 1", got.ID)
	}
	t.Logf("query returned %d hit(s); first: id=%s fields=%v",
		len(result.Root.Children), got.ID, got.Fields)
}
