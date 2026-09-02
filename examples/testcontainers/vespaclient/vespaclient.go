// Package vespaclient is a thin client for talking to a Vespa instance:
// build an application package zip, deploy it, feed documents, run queries.
// It exists so the smoke test in the same package can drive Vespa end-to-end
// without bringing in a heavy Vespa SDK.
//
// All operations target Vespa's HTTP APIs:
//   - port 19071 (config server) for deploy
//   - port 8080 (default container) for /ApplicationStatus, feed, search
package vespaclient

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// BuildAppPackage walks fsys (typically an embed.FS rooted at the testapp
// directory) and returns a zip archive suitable for POSTing to Vespa's
// /application/v2/tenant/default/prepareandactivate endpoint.
//
// Vespa expects the zip to have services.xml, hosts.xml, and a schemas/
// directory at its root, so fsys should already be rooted there.
func BuildAppPackage(fsys fs.FS) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	err := fs.WalkDir(fsys, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		f, err := fsys.Open(p)
		if err != nil {
			return fmt.Errorf("open %s: %w", p, err)
		}
		defer f.Close()
		w, err := zw.Create(p)
		if err != nil {
			return fmt.Errorf("zip create %s: %w", p, err)
		}
		if _, err := io.Copy(w, f); err != nil {
			return fmt.Errorf("zip write %s: %w", p, err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DeployApp uploads the zipped application package to the config server and
// activates it. configServerURL is the base URL of the config server, e.g.
// http://localhost:19071.
func DeployApp(ctx context.Context, configServerURL string, zipBytes []byte) error {
	endpoint := strings.TrimRight(configServerURL, "/") +
		"/application/v2/tenant/default/prepareandactivate"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(zipBytes))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/zip")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("deploy POST: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("deploy failed: status=%d body=%s", resp.StatusCode, string(body))
	}
	return nil
}

// WaitForAppReady polls containerURL/ApplicationStatus until it returns 200
// or ctx is canceled. After DeployApp returns, the container service still
// needs to start, load the schema, and become ready to serve queries —
// typically 20-60s after deploy on a cold pod.
func WaitForAppReady(ctx context.Context, containerURL string) error {
	endpoint := strings.TrimRight(containerURL, "/") + "/ApplicationStatus"
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return err
		}
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for ApplicationStatus: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

// FeedDoc PUTs a single document to /document/v1/default/{docType}/docid/{id}.
// The fields map is encoded as Vespa's required {"fields": {...}} envelope.
func FeedDoc(ctx context.Context, containerURL, docType, id string, fields map[string]any) error {
	endpoint := fmt.Sprintf("%s/document/v1/default/%s/docid/%s",
		strings.TrimRight(containerURL, "/"), docType, url.PathEscape(id))
	body, err := json.Marshal(map[string]any{"fields": fields})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("feed POST: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("feed failed: status=%d body=%s", resp.StatusCode, string(respBody))
	}
	return nil
}

// QueryResult is a partial view of Vespa's query response — only the fields
// the smoke test actually inspects.
type QueryResult struct {
	Root struct {
		Fields struct {
			TotalCount int `json:"totalCount"`
		} `json:"fields"`
		Children []struct {
			ID     string         `json:"id"`
			Fields map[string]any `json:"fields"`
		} `json:"children"`
	} `json:"root"`
}

// Query runs a YQL query against /search/ and returns the decoded result.
func Query(ctx context.Context, containerURL, yql string) (*QueryResult, error) {
	endpoint := strings.TrimRight(containerURL, "/") + "/search/"
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	q.Set("yql", yql)
	q.Set("hits", "10")
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("query GET: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("query failed: status=%d body=%s", resp.StatusCode, string(respBody))
	}
	var qr QueryResult
	if err := json.Unmarshal(respBody, &qr); err != nil {
		return nil, fmt.Errorf("decode query result: %w; body=%s", err, string(respBody))
	}
	return &qr, nil
}

