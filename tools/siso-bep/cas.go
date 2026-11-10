package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"strings"
	"time"

	"github.com/google/uuid"
	bspb "google.golang.org/genproto/googleapis/bytestream"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

// casTarget is where Siso stores blobs: the REAPI address and instance from
// its command line or environment, as Siso itself resolves them.
type casTarget struct {
	address  string
	instance string
	insecure bool
}

func (inv *invocation) casTarget() (casTarget, bool) {
	t := casTarget{
		address:  inv.reapiAddress(),
		instance: os.Getenv("SISO_REAPI_INSTANCE"),
		insecure: os.Getenv("RBE_service_no_security") == "true" || os.Getenv("SISO_REAPI_INSECURE") == "true",
	}
	applyArgs := func(args []string) {
		if v := flagValue(args, "reapi_instance"); v != "" {
			t.instance = v
		}
		if v := flagValue(args, "reapi_cas_address"); v != "" {
			t.address = v
		}
		for _, a := range args {
			if a == "--" {
				break
			}
			switch a {
			case "-reapi_insecure", "--reapi_insecure", "-reapi_insecure=true", "--reapi_insecure=true":
				t.insecure = true
			case "-reapi_insecure=false", "--reapi_insecure=false":
				t.insecure = false
			}
		}
	}
	applyArgs(inv.command)
	if inv.siso != nil {
		applyArgs(inv.siso.CommandLine)
		if v := inv.siso.ReapiInstance; v != "" {
			t.instance = v
		}
	}
	switch {
	case strings.HasPrefix(t.address, "grpc://"):
		t.address = strings.TrimPrefix(t.address, "grpc://")
		t.insecure = true
	case strings.HasPrefix(t.address, "grpcs://"):
		t.address = strings.TrimPrefix(t.address, "grpcs://")
	}
	return t, t.address != ""
}

// bytestreamURI is the form Bazel uses in BuildToolLogs, which bep-nats reads
// back through the project's ByteStream client.
func (t casTarget) bytestreamURI(hash string, size int) string {
	return fmt.Sprintf("bytestream://%s/%s", t.address, path.Join(t.instance, "blobs", hash, fmt.Sprint(size)))
}

const byteStreamChunk = 1 << 20

// uploadBlob writes data to the CAS with ByteStream and returns its URI.
// Credentials come from the same helper Siso uses for REAPI.
func uploadBlob(ctx context.Context, t casTarget, credentialHelper string, data []byte) (string, error) {
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])

	creds := credentials.NewTLS(nil)
	if t.insecure {
		creds = insecure.NewCredentials()
	}
	conn, err := grpc.NewClient(t.address, grpc.WithTransportCredentials(creds))
	if err != nil {
		return "", err
	}
	defer func() { _ = conn.Close() }()

	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	if credentialHelper != "" && !t.insecure {
		headers, helperErr := credentialHelperHeaders(ctx, credentialHelper, "grpcs://"+t.address)
		if helperErr != nil {
			return "", fmt.Errorf("credential helper: %w", helperErr)
		}
		md := metadata.MD{}
		for k, v := range headers {
			md.Append(strings.ToLower(k), v...)
		}
		ctx = metadata.NewOutgoingContext(ctx, md)
	}

	stream, err := bspb.NewByteStreamClient(conn).Write(ctx)
	if err != nil {
		return "", err
	}
	resource := path.Join(t.instance, "uploads", uuid.NewString(), "blobs", hash, fmt.Sprint(len(data)))
	for offset := 0; ; {
		end := min(offset+byteStreamChunk, len(data))
		req := &bspb.WriteRequest{WriteOffset: int64(offset), Data: data[offset:end], FinishWrite: end == len(data)}
		if offset == 0 {
			req.ResourceName = resource
		}
		if stream.Send(req) != nil {
			break // The real error comes from CloseAndRecv.
		}
		if end == len(data) {
			break
		}
		offset = end
	}
	resp, err := stream.CloseAndRecv()
	if err != nil {
		return "", fmt.Errorf("bytestream write %s: %w", resource, err)
	}
	if resp.GetCommittedSize() != int64(len(data)) {
		return "", fmt.Errorf("bytestream write committed %d of %d bytes", resp.GetCommittedSize(), len(data))
	}
	return t.bytestreamURI(hash, len(data)), nil
}
