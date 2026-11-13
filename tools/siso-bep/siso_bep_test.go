package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	bspb "google.golang.org/genproto/googleapis/bytestream"
	buildpb "google.golang.org/genproto/googleapis/devtools/build/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/emptypb"

	bes "github.com/Hermetiq/hermetiq-k8s/tools/siso-bep/pb/build_event_stream"
)

func TestInsertSisoFlagsGoesBeforeTargets(t *testing.T) {
	tests := []struct {
		name string
		in   []string
		want []string
	}{
		{
			name: "siso ninja",
			in:   []string{"siso", "ninja", "-C", "out/Default", "chrome"},
			want: []string{"siso", "ninja", "--build_id=X", "-C", "out/Default", "chrome"},
		},
		{
			name: "autoninja",
			in:   []string{"autoninja", "-C", "out/Default", "chrome"},
			want: []string{"autoninja", "--build_id=X", "-C", "out/Default", "chrome"},
		},
		{
			name: "autoninja building ninja target",
			in:   []string{"autoninja", "-C", "out/Default", "ninja"},
			want: []string{"autoninja", "--build_id=X", "-C", "out/Default", "ninja"},
		},
		{
			name: "siso ninja building ninja target",
			in:   []string{"siso", "ninja", "-C", "out/Default", "ninja"},
			want: []string{"siso", "ninja", "--build_id=X", "-C", "out/Default", "ninja"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := insertSisoFlags(tt.in, "--build_id=X"); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("insertSisoFlags = %q, want %q", got, tt.want)
			}
		})
	}
}

// autoninja rewrites arguments starting with -j or -t before Siso sees them.
func TestInsertedFlagsSurviveAutoninja(t *testing.T) {
	args, _ := prepareSisoArgs([]string{"autoninja", "-C", "out", "chrome"})
	for _, a := range args[1:] {
		if strings.HasPrefix(a, "-j") || strings.HasPrefix(a, "-t") {
			t.Errorf("autoninja would rewrite %q", a)
		}
	}
}

func TestPrepareSisoArgsReusesCallerIDs(t *testing.T) {
	args, ids := prepareSisoArgs([]string{"siso", "ninja", "-build_id", "inv-1", "--job_id=job-1", "all"})
	if ids.invocationID != "inv-1" || ids.jobID != "job-1" {
		t.Fatalf("ids = %+v, want the caller's", ids)
	}
	if len(args) != 6 {
		t.Errorf("args = %q, want them unchanged", args)
	}

	args, ids = prepareSisoArgs([]string{"siso", "ninja", "-C", "out", "all"})
	if ids.invocationID == "" || ids.jobID == "" {
		t.Fatalf("ids = %+v, want generated IDs", ids)
	}
	if args[2] != "--job_id="+ids.jobID || args[3] != "--build_id="+ids.invocationID || args[len(args)-1] != "all" {
		t.Errorf("args = %q, want IDs after the subcommand and the target last", args)
	}
	if got := sisoOutDir(args); got != "out" {
		t.Errorf("sisoOutDir = %q, want out", got)
	}
}

// frame encodes one length-delimited ninja.Status message.
func frame(status []byte) []byte {
	return append(protowire.AppendVarint(nil, uint64(len(status))), status...)
}

func field(num protowire.Number, msg []byte) []byte {
	b := protowire.AppendTag(nil, num, protowire.BytesType)
	return protowire.AppendBytes(b, msg)
}

func varintField(num protowire.Number, v uint64) []byte {
	b := protowire.AppendTag(nil, num, protowire.VarintType)
	return protowire.AppendVarint(b, v)
}

func stringField(num protowire.Number, s string) []byte { return field(num, []byte(s)) }

func TestReadFrontendRecordsFailedStepAndPrintsProgress(t *testing.T) {
	var stream bytes.Buffer
	stream.Write(frame(field(statusTotalEdges, varintField(totalEdgesCount, 2))))
	for _, e := range []struct {
		id     uint64
		desc   string
		status int64
		output string
	}{
		{1, "CXX obj/a.o", 0, ""},
		{2, "CXX obj/b.o", 1, "b.cc:1: error: boom"},
	} {
		started := append(varintField(edgeStartedID, e.id), stringField(edgeStartedDesc, e.desc)...)
		started = append(started, stringField(edgeStartedOutputs, strings.TrimPrefix(e.desc, "CXX "))...)
		started = append(started, stringField(edgeStartedCommand, "g++ -c x")...)
		stream.Write(frame(field(statusEdgeStarted, started)))
		finished := append(varintField(edgeFinishedID, e.id), varintField(edgeFinishedTime, 1500)...)
		finished = append(finished, varintField(edgeFinishedStatus, protowire.EncodeZigZag(e.status))...)
		finished = append(finished, stringField(edgeFinishedOutput, e.output)...)
		stream.Write(frame(field(statusEdgeFinished, finished)))
	}
	msg := append(varintField(messageLevel, messageInfo), stringField(messageText, "Build Failure")...)
	stream.Write(frame(field(statusMessage, msg)))

	var out, errOut bytes.Buffer
	tracker := newEdgeTracker(&out, &errOut)
	if err := readFrontend(&stream, tracker.handle); err != nil {
		t.Fatal(err)
	}
	failures := tracker.failed()
	if len(failures) != 1 || failures[0].status != 1 || failures[0].outputs[0] != "obj/b.o" {
		t.Fatalf("failures = %+v, want obj/b.o with status 1", failures)
	}
	if !strings.Contains(failures[0].message(), "boom") {
		t.Errorf("message = %q, want the step output", failures[0].message())
	}
	for _, want := range []string{"[1/2] 1.50s CXX obj/a.o", "[2/2] 1.50s CXX obj/b.o", "Build Failure"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("progress output %q is missing %q", out.String(), want)
		}
	}
	if !strings.Contains(errOut.String(), "FAILED: obj/b.o") {
		t.Errorf("stderr %q is missing the failure line", errOut.String())
	}
}

// helloMetrics is a trimmed siso_metrics.json from examples/siso-hello.
const helloMetrics = `{"step_id":"a","action":"cxx","outputs":["obj/main.o"],"cached":true,"cache_nanos":2000000,"action_start_nanos":30000000,"action_end_nanos":35000000,"duration_nanos":5000000,"ready_nanos":29000000}
{"step_id":"b","action":"link","outputs":["hello"],"is_remote":true,"cache_nanos":1000000,"prev":"a","action_start_nanos":35000000,"action_end_nanos":115000000,"duration_nanos":80000000,"queue_nanos":400000,"input_fetch_nanos":900000,"exec_nanos":66000000,"output_upload_nanos":3700000}
{"step_id":"c","action":"stamp","outputs":["all.stamp"],"is_local":true,"prev":"b","action_start_nanos":115000000,"action_end_nanos":118000000,"duration_nanos":3000000,"utime_nanos":1000000,"stime_nanos":2000000}
{"step_id":"d","action":"cxx","outputs":["obj/broken.o"],"is_remote":true,"err":true,"action_start_nanos":30000000,"action_end_nanos":40000000,"duration_nanos":10000000}
{"build_id":"inv-1","duration_nanos":120000000,"err":true}
`

func writeMetrics(t *testing.T) *sisoMetrics {
	t.Helper()
	path := filepath.Join(t.TempDir(), "siso_metrics.json")
	if err := os.WriteFile(path, []byte(helloMetrics), 0o600); err != nil {
		t.Fatal(err)
	}
	m, err := readSisoMetrics(path)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestReadSisoMetrics(t *testing.T) {
	m := writeMetrics(t)
	if len(m.Steps) != 4 || m.BuildID != "inv-1" || m.BuildDuration != 120*time.Millisecond || !m.BuildErr {
		t.Fatalf("metrics = %+v", m)
	}
	c := countRunners(m.Steps)
	want := runnerCounts{total: 4, cacheHits: 1, remote: 2, local: 1, cacheMisses: 1}
	if c != want {
		t.Errorf("countRunners = %+v, want %+v", c, want)
	}
}

func TestCriticalPathLogFollowsPrevLinks(t *testing.T) {
	m := writeMetrics(t)
	log := criticalPathLog(m.Steps)
	lines := strings.Split(strings.TrimSpace(log), "\n")
	if len(lines) != 4 {
		t.Fatalf("critical path = %q, want a header and 3 steps", log)
	}
	if !strings.HasPrefix(lines[0], "Critical Path: 0.09s, Remote (96.59% of the time)") {
		t.Errorf("header = %q", lines[0])
	}
	if !strings.Contains(lines[1], "action 'cxx obj/main.o'") ||
		!strings.Contains(lines[2], "Remote (100.00% of the time): [queue: 0.50%") ||
		!strings.Contains(lines[3], "action 'stamp all.stamp'") {
		t.Errorf("entries = %q", lines[1:])
	}
}

func TestSummarizeTargetsUsesStepTimesAndFailures(t *testing.T) {
	m := writeMetrics(t)
	start := time.Unix(1000, 0)
	failures := map[string]*stepFailure{"obj/broken.o": {desc: "CXX obj/broken.o", status: 1, output: "error: boom"}}
	targets := summarizeTargets(start, m.Steps, failures)
	if len(targets) != 4 {
		t.Fatalf("targets = %d, want 4", len(targets))
	}
	link := targets[1]
	if link.label != "hello" || link.kind != "link rule" ||
		link.first != start.Add(35*time.Millisecond) || link.last != start.Add(115*time.Millisecond) {
		t.Errorf("link target = %+v", link)
	}
	broken := targets[3]
	if broken.failed != 1 || !strings.Contains(broken.failure, "boom") {
		t.Errorf("broken target = %+v, want the step's failure output", broken)
	}
	ev := targetCompletedEvent(broken)
	if ev.GetCompleted().GetSuccess() || !strings.Contains(ev.GetCompleted().GetFailureDetail().GetMessage(), "boom") {
		t.Errorf("TargetComplete = %v", ev)
	}
}

func TestReadSisoFailures(t *testing.T) {
	const output = "FAILED: 5dffa308-5440 \"./obj/broken.o\" CXX obj/broken.o\n" +
		"err: remote-exec 6794/328 failed: exit=3\n" +
		"second line of err\n" +
		"stacktrace: siso/build/run.go:42\n" +
		"digest: 6794/328\n" +
		"build step: cxx \"./obj/broken.o\"\n" +
		"siso_rule: cxx\n" +
		"/usr/bin/g++ -c ../../src/broken.cc -o obj/broken.o\n" +
		"stdout:\n" +
		"note from stdout\n" +
		"stderr:\n" +
		"broken.cc:3:23: error: 'undefined_symbol' was not declared in this scope\n" +
		"auxiliary outputs:\n" +
		"obj/broken.o.d\n" +
		"\f\n" +
		"SUCCESS: 8b00 \"./obj/warn.o\" CXX obj/warn.o\n" +
		"build step: cxx \"./obj/warn.o\"\n" +
		"/usr/bin/g++ -c warn.cc -o obj/warn.o\n" +
		"stderr:\n" +
		"warn.cc:1: warning: unused variable\n" +
		"\f\n" +
		"FAILED[remote]: 7a11 \"./obj/other.o\" CXX obj/other.o\n" +
		"err: remote-exec timed out\n" +
		"/usr/bin/g++ -c other.cc -o obj/other.o\n" +
		"stderr:\n" +
		"\f\n"
	path := filepath.Join(t.TempDir(), "siso_output")
	started := time.Now()
	if err := os.WriteFile(path, []byte(output), 0o600); err != nil {
		t.Fatal(err)
	}
	failures := readSisoFailures(path, started)
	if len(failures) != 2 {
		t.Fatalf("failures = %+v, want 2", failures)
	}
	broken := failures[0]
	if broken.desc != "CXX obj/broken.o" || broken.status != 3 || broken.outputs[0] != "obj/broken.o" ||
		broken.command != "/usr/bin/g++ -c ../../src/broken.cc -o obj/broken.o" ||
		!strings.Contains(broken.err, "second line of err") {
		t.Errorf("first failure = %+v", broken)
	}
	if !strings.Contains(broken.output, "note from stdout") ||
		!strings.Contains(broken.output, "undefined_symbol") ||
		strings.Contains(broken.output, "stderr:") ||
		strings.Contains(broken.output, "unused variable") ||
		strings.Contains(broken.output, "broken.o.d") {
		t.Errorf("output = %q", broken.output)
	}
	// With no exit status in the err line and an empty stderr: section, the
	// step still counts as failed and falls back to err in message().
	if failures[1].status != 1 || failures[1].outputs[0] != "obj/other.o" || failures[1].output != "" ||
		!strings.Contains(failures[1].message(), "remote-exec timed out") {
		t.Errorf("second failure = %+v, message = %q", failures[1], failures[1].message())
	}
	// An older build's file is not this build's failures.
	if got := readSisoFailures(path, time.Now().Add(time.Hour)); got != nil {
		t.Errorf("stale file gave %+v", got)
	}
	if got := readSisoFailures(path+".missing", time.Time{}); got != nil {
		t.Errorf("missing file gave %+v", got)
	}
}

func TestActiveIntervalExcludesSisoSlotWaits(t *testing.T) {
	retried := stepMetric{
		IsRemote: true, ActionStartNanos: 10, ActionEndNanos: 3350, DurationNanos: 3340, ExecStartNanos: -5,
		Spans: []span{
			{Name: "step:cxx", StartNs: 8, DurNs: 3340},
			{Name: "exec-remote-cache-check", StartNs: 10, DurNs: 4},
			{Name: "exec-remote-exec-attempt", StartNs: 16, DurNs: 120},
			{Name: "exec-remote-exec-attempt", StartNs: 3230, DurNs: 120},
		},
	}
	if b, e := retried.activeInterval(); b != 3230 || e != 3350 {
		t.Errorf("retried remote step = %d..%d, want its last attempt 3230..3350", b, e)
	}
	localWithCacheCheck := stepMetric{
		IsLocal: true, ActionStartNanos: 10, ExecStartNanos: 90, ActionEndNanos: 100,
		Spans: []span{
			{Name: "exec-remote-cache-check", StartNs: 12, DurNs: 3},
			{Name: "exec-local-run", StartNs: 90, DurNs: 10},
		},
	}
	if b, e := localWithCacheCheck.activeInterval(); b != 90 || e != 100 {
		t.Errorf("local step with cache check = %d..%d, want 90..100", b, e)
	}
	fallback := stepMetric{
		IsRemote: true, IsLocal: true, Fallback: true,
		ActionStartNanos: 10, ExecStartNanos: 90, ActionEndNanos: 100,
		Spans: []span{
			{Name: "exec-remote-exec-attempt", StartNs: 16, DurNs: 50},
			{Name: "exec-local-run", StartNs: 90, DurNs: 10},
		},
	}
	if b, e := fallback.activeInterval(); b != 90 || e != 100 {
		t.Errorf("fallback step = %d..%d, want local execution 90..100", b, e)
	}
	missingEnd := stepMetric{IsLocal: true, ActionStartNanos: 10, ExecStartNanos: 90, DurationNanos: 90}
	if b, e := missingEnd.activeInterval(); b != 90 || e != 100 {
		t.Errorf("missing ActionEndNanos step = %d..%d, want 90..100", b, e)
	}
	noExec := stepMetric{NoExec: true, ActionStartNanos: 10, ExecStartNanos: -5, ActionEndNanos: 12}
	if b, _ := noExec.activeInterval(); b != 10 {
		t.Errorf("no-exec step begins at %d, want 10", b)
	}
}

func TestGNActionRulesShareOneMnemonic(t *testing.T) {
	gn := stepMetric{Action: "__base_buildflags___build_toolchain_linux_clang_x64__rule", Rule: "x"}
	if got := gn.mnemonic(); got != "action" {
		t.Errorf("mnemonic = %q, want action", got)
	}
	cxx := stepMetric{Action: "cxx", Rule: "clang/cxx"}
	if got := cxx.mnemonic(); got != "cxx" {
		t.Errorf("mnemonic = %q, want cxx", got)
	}
}

func TestInfraFailureMessageKeepsSisoError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "siso_output")
	output := `FAILED: 1 "./obj/a.o" CXX obj/a.o
err: remote-exec 1/2 no-fallback: failed to get op: Unimplemented
digest: 1/2
g++ -c a.cc
`
	if err := os.WriteFile(path, []byte(output), 0o600); err != nil {
		t.Fatal(err)
	}
	failures := readSisoFailures(path, time.Time{})
	if len(failures) != 1 || !strings.Contains(failures[0].message(), "Unimplemented") {
		t.Errorf("failures = %+v", failures)
	}
}

func TestGNTargetLabelGetsSlashes(t *testing.T) {
	s := stepMetric{StepID: "x", GNTarget: "base:base", Outputs: []string{"obj/base/a.o"}}
	if got := s.label(); got != "//base:base" {
		t.Errorf("label = %q", got)
	}
}

// fakeBES records events and drops the first stream after a few acks, to
// check that the publisher resends unacknowledged events.
type fakeBES struct {
	buildpb.UnimplementedPublishBuildEventServer
	mu         sync.Mutex
	lifecycle  []*buildpb.PublishLifecycleEventRequest
	seqs       []int64
	events     []*buildpb.BuildEvent
	streams    int
	failFirstN int
	// failEveryN drops every stream after it has received this many events.
	failEveryN int
	headers    metadata.MD
	// stall makes the server stop acknowledging tool events and hang the
	// final lifecycle event until the client gives up.
	stall bool
}

func (f *fakeBES) PublishLifecycleEvent(ctx context.Context, req *buildpb.PublishLifecycleEventRequest) (*emptypb.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lifecycle = append(f.lifecycle, req)
	f.headers, _ = metadata.FromIncomingContext(ctx)
	stall := f.stall && req.GetBuildEvent().GetSequenceNumber() == 2
	f.mu.Unlock()
	if stall {
		<-ctx.Done()
		f.mu.Lock()
		return nil, ctx.Err()
	}
	f.mu.Lock()
	return &emptypb.Empty{}, nil
}

func (f *fakeBES) PublishBuildToolEventStream(stream buildpb.PublishBuildEvent_PublishBuildToolEventStreamServer) error {
	f.mu.Lock()
	f.streams++
	first := f.streams == 1
	f.mu.Unlock()
	received := 0
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		received++
		if f.stall {
			continue
		}
		if first && f.failFirstN > 0 && received > f.failFirstN {
			return io.ErrUnexpectedEOF
		}
		if f.failEveryN > 0 && received > f.failEveryN {
			return io.ErrUnexpectedEOF
		}
		obe := req.GetOrderedBuildEvent()
		f.mu.Lock()
		f.seqs = append(f.seqs, obe.GetSequenceNumber())
		f.events = append(f.events, obe.GetEvent())
		f.mu.Unlock()
		if err := stream.Send(&buildpb.PublishBuildToolEventStreamResponse{
			StreamId: obe.GetStreamId(), SequenceNumber: obe.GetSequenceNumber(),
		}); err != nil {
			return err
		}
	}
}

// dialFakeBES serves fake over an in-memory listener and returns a client
// connection to it.
func dialFakeBES(t *testing.T, fake *fakeBES) *grpc.ClientConn {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	buildpb.RegisterPublishBuildEventServer(server, fake)
	go func() { _ = server.Serve(lis) }()
	t.Cleanup(server.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func TestPublisherResendsAfterStreamFailure(t *testing.T) {
	fake := &fakeBES{failFirstN: 2}
	conn := dialFakeBES(t, fake)

	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.Pairs("x-forwarded-user", "dev"), "proj", "build", "inv")
	if err := pub.lifecycle(ctx, 1, time.Now(), invocationStarted()); err != nil {
		t.Fatal(err)
	}
	pub.start(ctx)
	for i := range 5 {
		if err := pub.send(progressEvent(int32(i), "line\n", ""), time.Time{}); err != nil { //nolint:gosec // G115: tiny test counts
			t.Fatal(err)
		}
	}
	finishCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pub.finish(finishCtx); err != nil {
		t.Fatal(err)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.streams < 2 {
		t.Errorf("streams = %d, want a reconnect", fake.streams)
	}
	// Events 1-2 were acked on the first stream; 3-6 (5 progress events plus
	// ComponentStreamFinished) must arrive on the second, in order.
	if want := []int64{1, 2, 3, 4, 5, 6}; !reflect.DeepEqual(fake.seqs, want) {
		t.Errorf("acked sequence numbers = %v, want %v", fake.seqs, want)
	}
	if len(fake.lifecycle) != 1 || fake.lifecycle[0].GetProjectId() != "proj" ||
		fake.lifecycle[0].GetBuildEvent().GetStreamId().GetInvocationId() != "inv" {
		t.Errorf("lifecycle = %v", fake.lifecycle)
	}
	if got := fake.headers.Get("x-forwarded-user"); len(got) != 1 || got[0] != "dev" {
		t.Errorf("x-forwarded-user = %q", got)
	}
}

func TestFinishedEventMapsExitCodes(t *testing.T) {
	at := time.Now()
	for _, tt := range []struct {
		result buildResult
		name   string
		code   int32
	}{
		{buildResult{exitCode: 0}, "SUCCESS", 0},
		{buildResult{exitCode: 1}, "BUILD_FAILURE", 1},
		{buildResult{exitCode: 130, interrupted: true}, "INTERRUPTED", 8},
	} {
		ev := finishedEvent(at, tt.result, nil)
		got := ev.GetFinished().GetExitCode()
		if got.GetName() != tt.name || got.GetCode() != tt.code {
			t.Errorf("exit %d: got %s/%d, want %s/%d", tt.result.exitCode, got.GetName(), got.GetCode(), tt.name, tt.code)
		}
	}
}

func TestBuildProfileIsBazelShaped(t *testing.T) {
	m := writeMetrics(t)
	inv := &invocation{id: "inv-1", siso: &sisoMetadata{SisoVersion: "v1.6.7"}}
	start := time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)
	gz, err := buildProfile(inv, start, m)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		t.Fatal(err)
	}
	var p traceProfile
	if err := json.NewDecoder(zr).Decode(&p); err != nil {
		t.Fatal(err)
	}
	if p.OtherData["date"] != "2026-10-30T12:00:00Z" || p.OtherData["build_id"] != "inv-1" {
		t.Errorf("otherData = %v", p.OtherData)
	}
	counts := map[string]int{}
	for _, e := range p.TraceEvents {
		counts[e.Cat+"/"+e.Ph]++
		if e.Cat == categoryAction {
			if e.Args["mnemonic"] == "" || e.Args["target"] == "" || e.Args["target_label"] == "" || e.Out == "" || e.Ts <= 0 || e.Dur <= 0 {
				t.Errorf("action event the parser would drop: %+v", e)
			}
		}
	}
	for key, want := range map[string]int{
		"action processing/X":                  4,
		"critical path component/X":            3,
		"remote execution queuing time/X":      1,
		"remote execution process wall time/X": 1,
		"remote action cache check/X":          2,
		"build phase marker/i":                 6,
	} {
		if counts[key] != want {
			t.Errorf("%s events = %d, want %d", key, counts[key], want)
		}
	}
	if counts["/C"] == 0 {
		t.Error("no action count counter events")
	}
}

func TestSIGTERMIsForwardedToTheBuild(t *testing.T) {
	signals := make(chan chan<- os.Signal, 1)
	saved := notifySignals
	notifySignals = func(c chan<- os.Signal) { signals <- c }
	t.Cleanup(func() { notifySignals = saved })

	started := filepath.Join(t.TempDir(), "started")
	// Exits 0 only once it gets SIGTERM; without forwarding it never exits.
	script := `trap 'exit 0' TERM; touch "$1"; while :; do sleep 0.05; done`
	done := make(chan int, 1)
	go func() {
		done <- runBuild(context.Background(), &options{}, []string{"sh", "-c", script, "sh", started}, &invocation{}, nil)
	}()

	c := <-signals
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("build never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	c <- syscall.SIGTERM
	select {
	case code := <-done:
		// The build exited 0 after the signal; the wrapper still reports it
		// as interrupted, the way a shell would.
		if code != 128+int(syscall.SIGTERM) {
			t.Errorf("exit code = %d, want %d", code, 128+int(syscall.SIGTERM))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("build kept running after SIGTERM")
	}
}

func TestInterruptedBuildReportsOneExitCode(t *testing.T) {
	result := buildResult{exitCode: 130, interrupted: true}
	finished := finishedEvent(time.Now(), result, nil).GetFinished().GetExitCode()
	status := invocationFinished(result).GetInvocationAttemptFinished().GetInvocationStatus()
	if finished.GetCode() != 8 || status.GetBuildToolExitCode().GetValue() != 8 {
		t.Errorf("Finished code %d, lifecycle code %d; want 8 for both", finished.GetCode(), status.GetBuildToolExitCode().GetValue())
	}
	if status.GetResult() != buildpb.BuildStatus_CANCELLED {
		t.Errorf("lifecycle result = %v, want CANCELLED", status.GetResult())
	}
	failed := invocationFinished(buildResult{exitCode: 2}).GetInvocationAttemptFinished().GetInvocationStatus()
	if failed.GetBuildToolExitCode().GetValue() != 1 || failed.GetResult() != buildpb.BuildStatus_COMMAND_FAILED {
		t.Errorf("failed build status = %v", failed)
	}
}

func TestFinishBuildHonorsFlushTimeout(t *testing.T) {
	fake := &fakeBES{stall: true}
	conn := dialFakeBES(t, fake)
	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.MD{}, "proj", "build", "inv")
	if err := pub.lifecycle(ctx, 1, time.Now(), invocationStarted()); err != nil {
		t.Fatal(err)
	}
	pub.start(ctx)
	r := &reporter{
		opts:    &options{flushTimeout: 100 * time.Millisecond},
		pub:     pub,
		stop:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	inv := &invocation{id: "inv", outDir: t.TempDir(), started: time.Now()}

	begin := time.Now()
	r.finishBuild(ctx, inv, nil, buildResult{})
	if elapsed := time.Since(begin); elapsed > 2*time.Second {
		t.Errorf("finishBuild took %s with a 100ms flush timeout", elapsed)
	}
}

func TestLocalFallbackCountsAsLocal(t *testing.T) {
	// Siso sets both flags on a step whose remote attempt fell back to local.
	fallback := stepMetric{
		StepID: "f", Action: "cxx", Outputs: []string{"obj/f.o"},
		IsRemote: true, IsLocal: true, Fallback: true, ExecNanos: 5_000_000,
		ActionStartNanos: 1_000_000, ActionEndNanos: 9_000_000, DurationNanos: 8_000_000,
	}
	if got := fallback.strategy(); got != "local" {
		t.Errorf("strategy = %q, want local", got)
	}
	if c := countRunners([]stepMetric{fallback}); c.local != 1 || c.remote != 0 {
		t.Errorf("countRunners = %+v, want one local step", c)
	}
	if phases := stepPhaseEvents(&fallback, firstLaneTid); len(phases) != 0 {
		t.Errorf("remote phase events for a local fallback: %+v", phases)
	}
	counters := actionCountEvents([]*stepMetric{&fallback})
	if len(counters) == 0 || counters[0].Args["local action"] != 1 {
		t.Errorf("action count counters = %+v, want 1 local action", counters)
	}
}

func TestConsoleWithoutReportingDoesNotBuffer(t *testing.T) {
	var out, errOut bytes.Buffer
	c := newConsole(&out, &errOut, false)
	_, _ = c.stdout.Write([]byte("hello\n"))
	_, _ = c.stderr.Write([]byte("oops\n"))
	if stdout, stderr := c.take(); stdout != "" || stderr != "" {
		t.Errorf("unreported output kept: %q %q", stdout, stderr)
	}
	if out.String() != "hello\n" || errOut.String() != "oops\n" {
		t.Errorf("terminal got %q %q", out.String(), errOut.String())
	}
	buffered := newConsole(io.Discard, io.Discard, true)
	_, _ = buffered.stdout.Write([]byte("line\n"))
	if stdout, _ := buffered.take(); stdout != "line\n" {
		t.Errorf("buffered console take = %q", stdout)
	}
}

func TestSisoOutDirAndFlagValue(t *testing.T) {
	if got := sisoOutDir([]string{"autoninja", "-Cout/Default", "chrome"}); got != "out/Default" {
		t.Errorf("sisoOutDir(-Cout/Default) = %q, want out/Default", got)
	}
	if got := sisoOutDir([]string{"siso", "ninja", "-C", "out/Debug", "-C", "out/Release", "chrome"}); got != "out/Release" {
		t.Errorf("sisoOutDir(repeated -C) = %q, want out/Release", got)
	}
	if got := sisoOutDir([]string{"siso", "ninja", "--", "-C", "out/Ignored"}); got != "." {
		t.Errorf("sisoOutDir(after --) = %q, want .", got)
	}
}

func TestSisoFlagsAndCASTarget(t *testing.T) {
	inv := &invocation{
		command: []string{"/usr/bin/siso", "ninja", "-Cout/Default", "-reapi_insecure", "--reapi_address=grpc://localhost:8980", "--reapi_instance=proj-1", "--", "chrome"},
	}
	wantFlags := []string{"-C=out/Default", "-reapi_insecure", "--reapi_address=grpc://localhost:8980", "--reapi_instance=proj-1"}
	if got := inv.sisoFlags(); !reflect.DeepEqual(got, wantFlags) {
		t.Errorf("sisoFlags (fallback to command) = %q, want %q", got, wantFlags)
	}
	for _, opt := range commandLineEvent(inv).GetStructuredCommandLine().GetSections()[2].GetOptionList().GetOption() {
		if opt.GetOptionName() == "" {
			t.Errorf("empty option name in commandLineEvent: %+v", opt)
		}
		if opt.GetOptionName() == "reapi_insecure" && opt.GetOptionValue() != "" {
			t.Errorf("boolean flag swallowed target: %+v", opt)
		}
	}

	target, ok := inv.casTarget()
	if !ok || target.address != "localhost:8980" || target.instance != "proj-1" || !target.insecure {
		t.Errorf("casTarget = %+v, ok=%v; want localhost:8980 proj-1 insecure", target, ok)
	}
	if uri := target.bytestreamURI("abc", 42); uri != "bytestream://localhost:8980/proj-1/blobs/abc/42" {
		t.Errorf("bytestreamURI = %q", uri)
	}

	inv.siso = &sisoMetadata{
		CommandLine:   []string{"siso", "ninja", "-C", "out/Default", "--reapi_address=grpcs://cas.example.com:443", "--reapi_insecure=true", "--reapi_insecure=false", "chrome"},
		Targets:       []string{"chrome"},
		ReapiInstance: "proj-2",
	}
	target, ok = inv.casTarget()
	if !ok || target.address != "cas.example.com:443" || target.instance != "proj-2" || target.insecure {
		t.Errorf("casTarget with metadata override = %+v, ok=%v", target, ok)
	}
}

func TestFastExitWithoutOpeningFIFODoesNotStall(t *testing.T) {
	fake := &fakeBES{}
	conn := dialFakeBES(t, fake)
	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.MD{}, "proj", "build", "inv")
	if err := pub.lifecycle(ctx, 1, time.Now(), invocationStarted()); err != nil {
		t.Fatal(err)
	}
	pub.start(ctx)
	opts := &options{flushTimeout: 5 * time.Second}
	rep := &reporter{
		opts:    opts,
		conn:    conn,
		pub:     pub,
		stop:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	inv := &invocation{id: "inv", buildID: "build", outDir: t.TempDir(), command: []string{"true"}, started: time.Now()}

	begin := time.Now()
	code := runBuild(ctx, opts, []string{"true"}, inv, rep)
	if code != 0 {
		t.Errorf("exit code = %d, want 0", code)
	}
	if elapsed := time.Since(begin); elapsed > 2*time.Second {
		t.Errorf("runBuild took %s when the command never opened the frontend FIFO", elapsed)
	}
}

type stalledByteStream struct {
	bspb.UnimplementedByteStreamServer
}

func (s *stalledByteStream) Write(stream bspb.ByteStream_WriteServer) error {
	<-stream.Context().Done()
	return stream.Context().Err()
}

func TestFinishBuildHungProfileUploadDoesNotStarveLifecycle(t *testing.T) {
	casLis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	casServer := grpc.NewServer()
	bspb.RegisterByteStreamServer(casServer, &stalledByteStream{})
	go func() { _ = casServer.Serve(casLis) }()
	t.Cleanup(casServer.Stop)

	fake := &fakeBES{}
	conn := dialFakeBES(t, fake)
	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.MD{}, "proj", "build", "inv-1")
	if err := pub.lifecycle(ctx, 1, time.Now(), invocationStarted()); err != nil {
		t.Fatal(err)
	}
	pub.start(ctx)

	outDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(outDir, "siso_metrics.json"), []byte(helloMetrics), 0o600); err != nil {
		t.Fatal(err)
	}
	inv := &invocation{
		id:      "inv-1",
		buildID: "build",
		outDir:  outDir,
		command: []string{"siso", "ninja", "-reapi_address=" + casLis.Addr().String(), "-reapi_insecure"},
		started: time.Now(),
	}
	r := &reporter{
		opts:    &options{flushTimeout: 200 * time.Millisecond},
		pub:     pub,
		stop:    make(chan struct{}),
		stopped: make(chan struct{}),
	}

	begin := time.Now()
	r.finishBuild(ctx, inv, nil, buildResult{exitCode: 1})
	if elapsed := time.Since(begin); elapsed > 2*time.Second {
		t.Errorf("finishBuild took %s with a 200ms flush timeout", elapsed)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.lifecycle) != 2 || fake.lifecycle[1].GetBuildEvent().GetSequenceNumber() != 2 {
		t.Errorf("lifecycle events = %d, want InvocationAttemptStarted and InvocationAttemptFinished", len(fake.lifecycle))
	}
	if len(fake.seqs) == 0 {
		t.Error("tool stream events were starved by the hung CAS profile upload")
	}
}

func TestBuildProfilePhaseEventsStayWithinActionSpan(t *testing.T) {
	step := stepMetric{
		StepID:           "s1",
		Action:           "cxx",
		Outputs:          []string{"obj/a.o"},
		IsRemote:         true,
		ReadyNanos:       500,
		DurationNanos:    10_000_000,
		CacheNanos:       2_000_000,
		QueueNanos:       3_000_000,
		InputFetchNanos:  2_000_000,
		ExecNanos:        5_000_000,
		OutputUploadNano: 2_000_000,
	}
	actionStart, actionDur := stepSpan(&step)
	actionEnd := actionStart + actionDur
	phases := stepPhaseEvents(&step, firstLaneTid)
	if len(phases) == 0 {
		t.Fatal("expected phase events")
	}
	for _, ev := range phases {
		if ev.Ts < actionStart || ev.Ts+ev.Dur > actionEnd {
			t.Errorf("phase %q [%d, %d] overflows action [%d, %d]", ev.Cat, ev.Ts, ev.Ts+ev.Dur, actionStart, actionEnd)
		}
	}
}

func TestTruncateKeepsCharactersWhole(t *testing.T) {
	s := strings.Repeat("a", 9) + "‘quoted’"
	got := truncate(s, 10) // byte 10 is inside the 3-byte ‘
	if !utf8.ValidString(got) || !strings.HasPrefix(got, strings.Repeat("a", 9)+"\n") {
		t.Errorf("truncate = %q, want 9 a's then the truncation note", got)
	}
}

func TestPublisherSendsEventsWithInvalidUTF8(t *testing.T) {
	fake := &fakeBES{}
	conn := dialFakeBES(t, fake)
	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.MD{}, "proj", "build", "inv")
	pub.start(ctx)
	if err := pub.send(progressEvent(0, "bad \xff byte\n", ""), time.Time{}); err != nil {
		t.Fatalf("send with invalid UTF-8: %v", err)
	}
	finishCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pub.finish(finishCtx); err != nil {
		t.Fatal(err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	var be bes.BuildEvent
	if err := fake.events[0].GetBazelEvent().UnmarshalTo(&be); err != nil {
		t.Fatal(err)
	}
	if got := be.GetProgress().GetStdout(); got != "bad � byte\n" {
		t.Errorf("stdout = %q", got)
	}
}

func TestConsoleHoldsBackACutOffCharacter(t *testing.T) {
	c := newConsole(io.Discard, io.Discard, true)
	quote := []byte("‘") // 3 bytes
	_, _ = c.stdout.Write(append([]byte("x"), quote[:2]...))
	if got, _ := c.take(); got != "x" {
		t.Errorf("first take = %q, want the complete part only", got)
	}
	_, _ = c.stdout.Write(quote[2:])
	if got, _ := c.take(); got != "‘" {
		t.Errorf("second take = %q, want the completed character", got)
	}
}

func TestHelperURI(t *testing.T) {
	for in, want := range map[string]string{
		"grpcs://bes.example.com:443": "https://bes.example.com:443",
		"grpc://localhost:8985":       "http://localhost:8985",
		"bes.example.com:443":         "https://bes.example.com:443",
	} {
		if got := helperURI(in); got != want {
			t.Errorf("helperURI(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHelperCredentialsRerunHelperWhenHeadersExpire(t *testing.T) {
	dir := t.TempDir()
	count := filepath.Join(dir, "count")
	helper := filepath.Join(dir, "helper")
	script := "#!/bin/sh\necho x >> " + count + "\n" +
		`echo '{"headers":{"Authorization":["Bearer t"]},"expires":"2026-01-01T01:00:00Z"}'` + "\n"
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil { //nolint:gosec // G306: test helper must be executable
		t.Fatal(err)
	}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	c := newHelperCredentials(helper, "grpcs://bes.example.com")
	c.now = func() time.Time { return now }
	calls := func() int {
		b, _ := os.ReadFile(count) //nolint:gosec // G304: test file
		return strings.Count(string(b), "x")
	}

	for range 2 {
		md, err := c.GetRequestMetadata(context.Background())
		if err != nil || md["authorization"] != "Bearer t" {
			t.Fatalf("GetRequestMetadata = %v, %v", md, err)
		}
	}
	if calls() != 1 {
		t.Errorf("helper ran %d times before expiry, want 1", calls())
	}
	now = now.Add(time.Hour)
	if _, err := c.GetRequestMetadata(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls() != 2 {
		t.Errorf("helper ran %d times after expiry, want 2", calls())
	}
	if !c.RequireTransportSecurity() {
		t.Error("credential helper headers must not go over plaintext")
	}
}

func TestInsertSisoFlagsAfterSisoTopLevelFlags(t *testing.T) {
	got := insertSisoFlags([]string{"siso", "-log_dir", "/tmp", "ninja", "-C", "out", "chrome"}, "--build_id=x")
	want := []string{"siso", "-log_dir", "/tmp", "ninja", "--build_id=x", "-C", "out", "chrome"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("insertSisoFlags = %q, want %q", got, want)
	}
}

func TestCollectEnvironmentWithAbsoluteOutDir(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "build/config/siso"), 0o750); err != nil {
		t.Fatal(err)
	}
	inv := &invocation{outDir: filepath.Join(root, "out/Default")}
	inv.collectEnvironment(context.Background(), nil)
	if inv.workspaceDir != root {
		t.Errorf("workspaceDir = %q, want %q", inv.workspaceDir, root)
	}
}

func TestCollectEnvironmentRepoURLNeverCarriesCredential(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	for origin, want := range map[string]string{
		"https://u:V10DUMMY^x@example.invalid/org/repo.git":  "https://example.invalid/org/repo.git",
		"https://u:12/V10DUMMY@example.invalid/org/repo.git": "",
	} {
		root := t.TempDir()
		if err := os.MkdirAll(filepath.Join(root, "build/config/siso"), 0o750); err != nil {
			t.Fatal(err)
		}
		for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", origin}} {
			if out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v: %s", args, err, out)
			}
		}
		inv := &invocation{outDir: root}
		inv.collectEnvironment(context.Background(), nil)
		got, set := inv.metadata["REPO_URL"]
		if want == "" && set {
			t.Errorf("origin %q: REPO_URL = %q, want omitted", origin, got)
		} else if want != "" && got != want {
			t.Errorf("origin %q: REPO_URL = %q, want %q", origin, got, want)
		}
	}
}

func TestPublisherSurvivesRepeatedStreamResets(t *testing.T) {
	old := reconnectBackoff
	reconnectBackoff = time.Millisecond
	t.Cleanup(func() { reconnectBackoff = old })

	fake := &fakeBES{failEveryN: 2}
	conn := dialFakeBES(t, fake)
	ctx := context.Background()
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), metadata.MD{}, "proj", "build", "inv")
	pub.start(ctx)
	// Every stream acknowledges two events and then drops, so this needs far
	// more than maxReconnects streams in total.
	for i := range 3 * maxReconnects {
		if err := pub.send(progressEvent(int32(i), "line\n", ""), time.Time{}); err != nil { //nolint:gosec // G115: tiny test counts
			t.Fatal(err)
		}
	}
	finishCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := pub.finish(finishCtx); err != nil {
		t.Fatalf("finish after periodic stream resets: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.streams <= maxReconnects+1 {
		t.Errorf("streams = %d; the test needs more than maxReconnects+1 to mean anything", fake.streams)
	}
}

func TestReadSisoMetricsKeepsStepBuildIDWithoutSummaryLine(t *testing.T) {
	const stepOnly = `{"build_id":"inv-step-only","step_id":"s1","action":"cxx","outputs":["obj/a.o"],"is_remote":true,"action_start_nanos":1000000,"action_end_nanos":5000000,"duration_nanos":4000000}
`
	path := filepath.Join(t.TempDir(), "siso_metrics.json")
	if err := os.WriteFile(path, []byte(stepOnly), 0o600); err != nil {
		t.Fatal(err)
	}
	m, err := readSisoMetrics(path)
	if err != nil {
		t.Fatal(err)
	}
	if m.BuildID != "inv-step-only" || len(m.Steps) != 1 {
		t.Fatalf("readSisoMetrics = %+v, want BuildID inv-step-only and 1 step", m)
	}
	if got := m.wallTime(); got != 5*time.Millisecond {
		t.Errorf("wallTime = %v, want 5ms", got)
	}
}

func TestBuildMetricsEventUsesEarliestPositiveReadyNanos(t *testing.T) {
	m := writeMetrics(t)
	m.Steps[0].GNTarget = "//base:base"
	m.Steps[1].GNTarget = "chrome:chrome"
	start := time.Unix(1000, 0)
	ev := buildMetricsEvent(start, m).GetBuildMetrics()
	timing := ev.GetTimingMetrics()
	if timing.GetAnalysisPhaseTimeInMs() != 29 || timing.GetExecutionPhaseTimeInMs() != 91 || timing.GetWallTimeInMs() != 120 {
		t.Errorf("TimingMetrics = %+v, want analysis=29ms execution=91ms wall=120ms", timing)
	}
	if got := ev.GetPackageMetrics().GetPackagesLoaded(); got != 2 {
		t.Errorf("PackagesLoaded = %d, want 2", got)
	}
}

func TestMultiLineSisoFailureWithoutBuildStepHeader(t *testing.T) {
	const output = "FAILED: 1 \"./obj/a.o\" CXX obj/a.o\n" +
		"err: remote-exec 1/2 failed: exit=2\n" +
		"line two of error\n" +
		"line three of error\n" +
		"digest: 1/2\n" +
		"/usr/bin/clang++ -c a.cc -o obj/a.o\n"
	path := filepath.Join(t.TempDir(), "siso_output")
	if err := os.WriteFile(path, []byte(output), 0o600); err != nil {
		t.Fatal(err)
	}
	failures := readSisoFailures(path, time.Time{})
	if len(failures) != 1 {
		t.Fatalf("failures = %+v, want 1", failures)
	}
	f := failures[0]
	if !strings.Contains(f.err, "line two of error") || !strings.Contains(f.err, "line three of error") {
		t.Errorf("err = %q, want all continuation lines", f.err)
	}
	if f.command != "/usr/bin/clang++ -c a.cc -o obj/a.o" {
		t.Errorf("command = %q, want the compiler command after digest:", f.command)
	}
}

func TestStartAndFailuresBackfillsInfraErrorFromSisoOutput(t *testing.T) {
	outDir := t.TempDir()
	const sisoOut = "FAILED: 1 \"./obj/a.o\" CXX obj/a.o\n" +
		"err: remote-exec 1/2 no-fallback: DeadlineExceeded\n" +
		"digest: 1/2\n" +
		"g++ -c a.cc -o obj/a.o\n"
	if err := os.WriteFile(filepath.Join(outDir, "siso_output"), []byte(sisoOut), 0o600); err != nil {
		t.Fatal(err)
	}
	tracker := newEdgeTracker(io.Discard, io.Discard)
	tracker.handle(frontendEvent{Started: &edgeStarted{ID: 1, Desc: "CXX obj/a.o", Outputs: []string{"obj/a.o"}, Command: "g++ -c a.cc -o obj/a.o"}})
	tracker.handle(frontendEvent{Finished: &edgeFinished{ID: 1, EndMs: 100, Status: 1}})

	inv := &invocation{outDir: outDir, started: time.Now()}
	_, failures := inv.startAndFailures(tracker, buildResult{exitCode: 1})
	if len(failures) != 1 || !strings.Contains(failures[0].message(), "DeadlineExceeded") {
		t.Fatalf("failures = %+v, message = %q, want DeadlineExceeded from siso_output", failures, failures[0].message())
	}
}

func TestSisoFlagsAndTargetsWithTopLevelAndQuietFlags(t *testing.T) {
	inv := &invocation{
		command: []string{"siso", "-log_dir", "/tmp", "-v", "ninja", "-C", "out/Default", "--quiet", "chrome", "unit_tests"},
	}
	wantFlags := []string{"-log_dir=/tmp", "-v", "-C=out/Default", "--quiet"}
	if got := inv.sisoFlags(); !reflect.DeepEqual(got, wantFlags) {
		t.Errorf("sisoFlags = %q, want %q", got, wantFlags)
	}
	wantTargets := []string{"chrome", "unit_tests"}
	if got := inv.targets(); !reflect.DeepEqual(got, wantTargets) {
		t.Errorf("targets = %q, want %q", got, wantTargets)
	}
}

func TestStepWithEmptyActionRuleAndOutputsProducesValidProfileAndActionEvent(t *testing.T) {
	s := stepMetric{
		StepID:           "step-1",
		GNTarget:         "//base:base",
		ActionStartNanos: 1_000_000,
		ActionEndNanos:   2_000_000,
		DurationNanos:    1_000_000,
		Err:              true,
	}
	if got := s.label(); got != "//base:base" {
		t.Errorf("label = %q, want //base:base", got)
	}
	if got := s.mnemonic(); got != "action" {
		t.Errorf("mnemonic = %q, want action", got)
	}
	ev := actionEvent(time.Unix(1000, 0), &s, nil)
	if ev.GetId().GetActionCompleted().GetPrimaryOutput() != "step-1" {
		t.Errorf("ActionCompleted PrimaryOutput = %q, want step-1", ev.GetId().GetActionCompleted().GetPrimaryOutput())
	}
	gz, err := buildProfile(&invocation{id: "inv-1"}, time.Unix(1000, 0), &sisoMetrics{BuildID: "inv-1", Steps: []stepMetric{s}})
	if err != nil {
		t.Fatal(err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		t.Fatal(err)
	}
	var p traceProfile
	if err := json.NewDecoder(zr).Decode(&p); err != nil {
		t.Fatal(err)
	}
	for _, te := range p.TraceEvents {
		if te.Cat == categoryAction {
			if te.Args["mnemonic"] == "" || te.Out == "" {
				t.Errorf("action trace event has empty mnemonic or Out: %+v", te)
			}
		}
	}
}

func TestSanitizeUTF8MapKeysAndFinalConsoleDrain(t *testing.T) {
	inv := &invocation{
		metadata: map[string]string{
			"bad\xffkey": "bad\xfeval",
		},
	}
	ev := buildMetadataEvent(inv)
	sanitizeUTF8(ev)
	md := ev.GetBuildMetadata().GetMetadata()
	if md["bad\ufffdkey"] != "bad\ufffdval" {
		t.Errorf("sanitized map = %v", md)
	}

	c := newConsole(io.Discard, io.Discard, true)
	quote := []byte("‘") // 3-byte UTF-8 rune
	_, _ = c.stdout.Write(quote[:2])
	if got, _ := c.take(); got != "" {
		t.Errorf("take before completion = %q, want empty", got)
	}
	if got, _ := c.drain(); got != string(quote[:2]) {
		t.Errorf("drain on exit = %q, want remaining partial rune bytes", got)
	}
}

func TestSanitizeRepoURLAndRequestMetadataValidation(t *testing.T) {
	for in, want := range map[string]string{
		"https://x-access-token:ghs_secret@github.com/org/repo.git": "https://github.com/org/repo.git",
		"https://token@github.com/org/repo.git":                     "https://github.com/org/repo.git",
		"ssh://git:secret@github.com/org/repo.git":                  "ssh://git@github.com/org/repo.git",
		"ssh://git@github.com/org/repo.git":                         "ssh://git@github.com/org/repo.git",
		"git@github.com:org/repo.git":                               "git@github.com:org/repo.git",
		"https://github.com/org/repo.git":                           "https://github.com/org/repo.git",
		"https://host:8443/org/repo.git?ref=main#top":               "https://host:8443/org/repo.git?ref=main#top",
		// url.Parse rejects these; the secret must still be stripped.
		"https://u:V10DUMMY^x@example.invalid/org/repo.git":   "https://example.invalid/org/repo.git",
		"https://u:V10DUMMY\"x@example.invalid/org/repo.git":  "https://example.invalid/org/repo.git",
		"https://u:V10 DUMMY@example.invalid/org/repo.git":    "https://example.invalid/org/repo.git",
		"https://u:V10DUMMY%g1@example.invalid/org/repo.git":  "https://example.invalid/org/repo.git",
		"https://u:V10DUMMY@example.invalid:abc/org/repo.git": "https://example.invalid:abc/org/repo.git",
		"HTTPS://u:V10DUMMY|x@example.invalid/org/repo.git":   "HTTPS://example.invalid/org/repo.git",
		"https://u:p@ss:V10DUMMY@example.invalid/org/repo":    "https://example.invalid/org/repo",
		"ssh://git:V10DUMMY^x@example.invalid/org/repo.git":   "ssh://git@example.invalid/org/repo.git",
	} {
		if got, ok := sanitizeRepoURL(in); !ok || got != want {
			t.Errorf("sanitizeRepoURL(%q) = %q, %v, want %q, true", in, got, ok, want)
		}
	}
	// An '@' outside the delimited authority cannot be separated from the
	// host safely (url.Parse accepts the first form with User == nil), so
	// REPO_URL is omitted.
	for _, in := range []string{
		"https://u:12/V10DUMMY@example.invalid/org/repo.git",
		"https://u:V10/DUMMY@example.invalid/org/repo.git",
		"https://u:V10?DUMMY@example.invalid/org/repo.git",
		"https://u:V10#DUMMY@example.invalid/org/repo.git",
	} {
		if got, ok := sanitizeRepoURL(in); ok || got != "" {
			t.Errorf("sanitizeRepoURL(%q) = %q, %v, want omitted", in, got, ok)
		}
	}
	if _, err := requestMetadata(&options{headers: stringList{"=value"}}); err == nil {
		t.Error("requestMetadata accepted empty header name")
	}
}

type memoryByteStream struct {
	bspb.UnimplementedByteStreamServer
	mu       sync.Mutex
	resource string
	data     []byte
}

func (m *memoryByteStream) Write(stream bspb.ByteStream_WriteServer) error {
	var buf bytes.Buffer
	var res string
	for {
		req, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if req.GetResourceName() != "" {
			res = req.GetResourceName()
		}
		buf.Write(req.GetData())
		if req.GetFinishWrite() {
			break
		}
	}
	m.mu.Lock()
	m.resource = res
	m.data = buf.Bytes()
	m.mu.Unlock()
	return stream.SendAndClose(&bspb.WriteResponse{CommittedSize: int64(buf.Len())})
}

func TestUploadBlobWritesProfileToCAS(t *testing.T) {
	casLis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cas := &memoryByteStream{}
	casServer := grpc.NewServer()
	bspb.RegisterByteStreamServer(casServer, cas)
	go func() { _ = casServer.Serve(casLis) }()
	t.Cleanup(casServer.Stop)

	target := casTarget{address: casLis.Addr().String(), instance: "proj-1", insecure: true}
	payload := []byte("profile-bytes")
	uri, err := uploadBlob(context.Background(), target, "", payload)
	if err != nil {
		t.Fatalf("uploadBlob: %v", err)
	}
	if !strings.HasPrefix(uri, "bytestream://"+casLis.Addr().String()+"/proj-1/blobs/") || !strings.HasSuffix(uri, "/13") {
		t.Errorf("uri = %q", uri)
	}
	cas.mu.Lock()
	defer cas.mu.Unlock()
	if !bytes.Equal(cas.data, payload) || !strings.HasPrefix(cas.resource, "proj-1/uploads/") {
		t.Errorf("uploaded resource=%q data=%q", cas.resource, cas.data)
	}
}
