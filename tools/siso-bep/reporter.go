package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	buildpb "google.golang.org/genproto/googleapis/devtools/build/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"

	bes "github.com/Hermetiq/hermetiq-k8s/tools/siso-bep/pb/build_event_stream"
)

// invocation is what the wrapper knows about the build it runs.
type invocation struct {
	id           string
	buildID      string
	outDir       string
	command      []string
	started      time.Time
	workingDir   string
	workspaceDir string
	user         string
	host         string
	metadata     map[string]string
	siso         *sisoMetadata
}

// collectEnvironment fills in the user, host, directories and build metadata:
// --metadata flags first, then git details for keys the caller didn't set.
func (inv *invocation) collectEnvironment(ctx context.Context, flags []string) {
	inv.user = os.Getenv("USER")
	inv.host, _ = os.Hostname()
	inv.workingDir, _ = os.Getwd()
	inv.workspaceDir = findWorkspaceRoot(filepath.Join(inv.workingDir, inv.outDir), inv.workingDir)
	inv.metadata = map[string]string{"TAG_tool": "siso"}
	for _, kv := range flags {
		if k, v, ok := strings.Cut(kv, "="); ok {
			inv.metadata[k] = v
		}
	}
	for key, args := range map[string][]string{
		"REPO_URL":    {"remote", "get-url", "origin"},
		"BRANCH_NAME": {"rev-parse", "--abbrev-ref", "HEAD"},
		"COMMIT_SHA":  {"rev-parse", "HEAD"},
	} {
		if _, set := inv.metadata[key]; set {
			continue
		}
		out, err := exec.CommandContext(ctx, "git", append([]string{"-C", inv.workspaceDir}, args...)...).Output() //nolint:gosec // G204: fixed git subcommands
		if v := strings.TrimSpace(string(out)); err == nil && v != "" {
			inv.metadata[key] = v
		}
	}
}

// findWorkspaceRoot mirrors Siso: the workspace root is the nearest ancestor
// of the out dir that contains build/config/siso.
func findWorkspaceRoot(dir, fallback string) string {
	for d := dir; ; d = filepath.Dir(d) {
		if st, err := os.Stat(filepath.Join(d, "build", "config", "siso")); err == nil && st.IsDir() {
			return d
		}
		if parent := filepath.Dir(d); parent == d {
			return fallback
		}
	}
}

func (inv *invocation) targets() []string {
	if inv.siso != nil && len(inv.siso.Targets) > 0 {
		return inv.siso.Targets
	}
	return []string{"default"}
}

func (inv *invocation) toolVersion() string {
	if inv.siso != nil && inv.siso.SisoVersion != "" {
		return "siso " + inv.siso.SisoVersion
	}
	return "siso"
}

var sisoBoolFlags = map[string]bool{
	"b":              true,
	"batch":          true,
	"clobber":        true,
	"confirm_no_op":  true,
	"dry_run":        true,
	"fast_exit":      true,
	"n":              true,
	"o":              true,
	"offline":        true,
	"prepare":        true,
	"reapi_insecure": true,
	"strict_remote":  true,
	"v":              true,
	"verbose":        true,
}

// sisoFlagArgs returns Siso's command line stripped of the leading binary,
// "ninja" subcommand and trailing targets.
func (inv *invocation) sisoFlagArgs() []string {
	args := inv.command
	if inv.siso != nil && len(inv.siso.CommandLine) > 0 {
		args = inv.siso.CommandLine
	}
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") && args[0] != "ninja" {
		args = args[1:]
	}
	if len(args) > 0 && args[0] == "ninja" {
		args = args[1:]
	}
	if inv.siso != nil {
		if n := len(inv.siso.Targets); n > 0 && n <= len(args) {
			args = args[:len(args)-n]
		}
	}
	return args
}

// sisoFlags is Siso's own command line without the subcommand and targets,
// with "-C dir" style pairs joined as "-C=dir".
func (inv *invocation) sisoFlags() []string {
	args := inv.sisoFlagArgs()
	var flags []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			break
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			continue
		}
		if len(a) > 2 && strings.HasPrefix(a, "-C") && a[2] != '=' {
			flags = append(flags, "-C="+a[2:])
			continue
		}
		trimmed := strings.TrimLeft(a, "-")
		if !strings.Contains(a, "=") && !sisoBoolFlags[trimmed] && i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
			a += "=" + args[i+1]
			i++
		}
		flags = append(flags, a)
	}
	return flags
}

func (inv *invocation) reapiAddress() string {
	if inv.siso != nil {
		if v := flagValue(inv.siso.CommandLine, "reapi_address"); v != "" {
			return v
		}
	}
	if v := flagValue(inv.command, "reapi_address"); v != "" {
		return v
	}
	return os.Getenv("SISO_REAPI_ADDRESS")
}

func (inv *invocation) platformName() string {
	if inv.siso == nil {
		return ""
	}
	p := inv.siso.Machine.Platform
	return p.OS + "_" + p.Architecture
}

func (inv *invocation) cpu() string {
	if inv.siso == nil {
		return ""
	}
	return inv.siso.Machine.Platform.Architecture
}

// console tees the build's stdout and stderr to the terminal and keeps what
// hasn't been reported yet.
type console struct {
	mu             sync.Mutex
	stdout, stderr io.Writer
	out, err       bytes.Buffer
}

type teeWriter struct {
	c        *console
	terminal io.Writer
	buf      *bytes.Buffer
}

func (w *teeWriter) Write(p []byte) (int, error) {
	w.c.mu.Lock()
	w.buf.Write(p)
	w.c.mu.Unlock()
	return w.terminal.Write(p)
}

// newConsole keeps unreported output only when buffer is set. Without a
// reporter nothing drains the buffers, so output goes straight through.
func newConsole(stdout, stderr io.Writer, buffer bool) *console {
	c := &console{stdout: stdout, stderr: stderr}
	if buffer {
		c.stdout = &teeWriter{c: c, terminal: stdout, buf: &c.out}
		c.stderr = &teeWriter{c: c, terminal: stderr, buf: &c.err}
	}
	return c
}

func (c *console) take() (stdout, stderr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	stdout, stderr = c.out.String(), c.err.String()
	c.out.Reset()
	c.err.Reset()
	return stdout, stderr
}

// stepFailure is a failed step as reported on the frontend stream, which is
// the only Siso output with a step's exit status and output.
type stepFailure struct {
	desc    string
	command string
	outputs []string
	status  int64
	output  string
	// err is Siso's own error line. An infrastructure failure has no step
	// output, so this is all that explains it.
	err string
}

const maxStepOutput = 4 << 10

func (f *stepFailure) message() string {
	msg := fmt.Sprintf("%s failed (exit %d)", f.desc, f.status)
	if out := strings.TrimSpace(f.output); out != "" {
		msg += "\n" + truncate(out, maxStepOutput)
	} else if f.err != "" {
		msg += "\n" + truncate(f.err, maxStepOutput)
	}
	return msg
}

// edgeTracker follows the frontend stream. With -frontend_file set, Siso
// prints nothing to the terminal, so the tracker also writes ninja-style
// progress lines and Siso's messages to the console (terminal and build log).
type edgeTracker struct {
	mu       sync.Mutex
	started  map[uint64]*edgeStarted
	failures []*stepFailure
	total    uint64
	done     uint64
	stdout   io.Writer
	stderr   io.Writer
}

func newEdgeTracker(stdout, stderr io.Writer) *edgeTracker {
	return &edgeTracker{started: map[uint64]*edgeStarted{}, stdout: stdout, stderr: stderr}
}

// read blocks until Siso opens the FIFO, then records failed steps until Siso
// closes it.
func (t *edgeTracker) read(path string) {
	f, err := os.Open(path) //nolint:gosec // G304: our own FIFO
	if err != nil {
		log.Printf("siso-bep: frontend stream: %v", err)
		return
	}
	defer func() { _ = f.Close() }()
	if err := readFrontend(f, t.handle); err != nil {
		log.Printf("siso-bep: frontend stream: %v", err)
	}
}

func (t *edgeTracker) handle(e frontendEvent) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e.TotalEdges > 0 {
		t.total = e.TotalEdges
	}
	if e.Message != nil && e.Message.Level != messageDebug {
		w := t.stdout
		if e.Message.Level >= messageWarning {
			w = t.stderr
		}
		_, _ = fmt.Fprintln(w, strings.TrimRight(e.Message.Text, "\n"))
	}
	if e.Started != nil {
		t.started[e.Started.ID] = e.Started
	}
	if e.Finished == nil {
		return
	}
	s := t.started[e.Finished.ID]
	delete(t.started, e.Finished.ID)
	if s == nil {
		return
	}
	t.done++
	elapsed := time.Duration(min(e.Finished.EndMs, math.MaxUint32)) * time.Millisecond
	_, _ = fmt.Fprintf(t.stdout, "[%d/%d] %.2fs %s\n", t.done, t.total, elapsed.Seconds(), s.Desc)
	failed := e.Finished.Status != 0 && !e.Finished.Canceled
	if failed {
		_, _ = fmt.Fprintf(t.stderr, "FAILED: %s\n%s\n", strings.Join(s.Outputs, " "), s.Command)
	}
	if out := strings.TrimRight(e.Finished.Output, "\n"); out != "" {
		_, _ = fmt.Fprintln(t.stdout, out)
	}
	if failed {
		t.failures = append(t.failures, &stepFailure{
			desc:    s.Desc,
			command: s.Command,
			outputs: s.Outputs,
			status:  e.Finished.Status,
			output:  e.Finished.Output,
		})
	}
}

func (t *edgeTracker) failed() []*stepFailure {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]*stepFailure(nil), t.failures...)
}

// byOutput indexes failures by every output path.
func byOutput(failures []*stepFailure) map[string]*stepFailure {
	m := map[string]*stepFailure{}
	for _, f := range failures {
		for _, o := range f.outputs {
			m[o] = f
		}
	}
	return m
}

// reporter turns one build into BEP.
type reporter struct {
	opts     *options
	conn     *grpc.ClientConn
	pub      *publisher
	console  *console
	preamble sync.Once
	progress int32
	stop     chan struct{}
	stopped  chan struct{}
}

func newReporter(ctx context.Context, opts *options, inv *invocation) (*reporter, error) {
	target, creds := opts.besBackend, credentials.NewTLS(nil)
	switch {
	case strings.HasPrefix(target, "grpc://"):
		target, creds = strings.TrimPrefix(target, "grpc://"), insecure.NewCredentials()
	case strings.HasPrefix(target, "grpcs://"):
		target = strings.TrimPrefix(target, "grpcs://")
	}
	conn, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(creds),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{Time: 60 * time.Second, Timeout: 20 * time.Second}),
	)
	if err != nil {
		return nil, err
	}
	md, err := requestMetadata(ctx, opts)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	pub := newPublisher(buildpb.NewPublishBuildEventClient(conn), md, opts.projectID, inv.buildID, inv.id)
	// The invocation row must exist before Siso's first remote action reaches
	// BB CAL or the cache proxy; bep-nats writes it before this returns.
	if err := pub.lifecycle(ctx, 1, inv.started, invocationStarted()); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("publish InvocationAttemptStarted: %w", err)
	}
	pub.start(ctx)
	return &reporter{opts: opts, conn: conn, pub: pub, stop: make(chan struct{}), stopped: make(chan struct{})}, nil
}

func requestMetadata(ctx context.Context, opts *options) (metadata.MD, error) {
	md := metadata.MD{}
	if opts.projectID != "" {
		md.Set("x-hermetiq-project-id", opts.projectID)
	}
	if opts.user != "" {
		md.Set("x-forwarded-user", opts.user)
	}
	if opts.credentialHelper != "" {
		headers, err := credentialHelperHeaders(ctx, opts.credentialHelper, opts.besBackend)
		if err != nil {
			return nil, fmt.Errorf("credential helper: %w", err)
		}
		for k, v := range headers {
			md.Append(strings.ToLower(k), v...)
		}
	}
	for _, h := range opts.headers {
		k, v, ok := strings.Cut(h, "=")
		if !ok {
			return nil, fmt.Errorf("--bes_header %q is not NAME=VALUE", h)
		}
		md.Append(strings.ToLower(k), v)
	}
	return md, nil
}

// credentialHelperHeaders runs a Bazel credential helper
// (https://github.com/EngFlow/credential-helper-spec), the same protocol
// SISO_CREDENTIAL_HELPER uses.
func credentialHelperHeaders(ctx context.Context, helper, uri string) (map[string][]string, error) {
	uri = strings.Replace(strings.Replace(uri, "grpcs://", "https://", 1), "grpc://", "http://", 1)
	req, err := json.Marshal(map[string]string{"uri": uri})
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, helper, "get") //nolint:gosec // G204: user-configured helper
	cmd.Stdin = bytes.NewReader(req)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var resp struct {
		Headers map[string][]string `json:"headers"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, fmt.Errorf("parse helper output: %w", err)
	}
	return resp.Headers, nil
}

func (r *reporter) send(event *bes.BuildEvent, at time.Time) {
	if err := r.pub.send(event, at); err != nil {
		log.Printf("siso-bep: %v", err)
	}
}

// startStreaming waits for Siso's siso_metadata.json for this build (Siso
// writes it at startup) so the Started event carries the real version,
// targets and flags, then reports console output every second.
func (r *reporter) startStreaming(inv *invocation, c *console) {
	r.console = c
	go func() {
		defer close(r.stopped)
		deadline := time.After(30 * time.Second)
		poll := time.NewTicker(100 * time.Millisecond)
		defer poll.Stop()
	wait:
		for inv.siso == nil {
			select {
			case <-r.stop:
				return
			case <-deadline:
				break wait
			case <-poll.C:
				r.loadSisoMetadata(inv)
			}
		}
		r.sendPreamble(inv)
		flush := time.NewTicker(time.Second)
		defer flush.Stop()
		for {
			select {
			case <-r.stop:
				return
			case <-flush.C:
				r.flushConsole()
			}
		}
	}()
}

func (r *reporter) loadSisoMetadata(inv *invocation) {
	md, err := readSisoMetadata(filepath.Join(inv.outDir, "siso_metadata.json"))
	if err == nil && md.BuildID == inv.id {
		inv.siso = md
	}
}

func (r *reporter) sendPreamble(inv *invocation) {
	r.preamble.Do(func() {
		r.send(startedEvent(inv), inv.started)
		r.send(unstructuredCommandLineEvent(inv), inv.started)
		r.send(commandLineEvent(inv), inv.started)
		r.send(optionsParsedEvent(inv), inv.started)
		r.send(buildMetadataEvent(inv), inv.started)
		r.send(workspaceStatusEvent(inv), inv.started)
		r.send(configurationEvent(inv), inv.started)
	})
}

func (r *reporter) flushConsole() {
	if r.console == nil {
		return
	}
	stdout, stderr := r.console.take()
	if stdout == "" && stderr == "" {
		return
	}
	r.send(progressEvent(r.progress, stdout, stderr), time.Time{})
	r.progress++
}

// finishBuild reports the result and everything Siso wrote about the build.
// --flush_timeout bounds all of it: the profile upload, draining the tool
// stream and the final lifecycle event.
func (r *reporter) finishBuild(ctx context.Context, inv *invocation, edges *edgeTracker, result buildResult) {
	finishedAt := time.Now()
	ctx, cancel := context.WithTimeout(ctx, r.opts.flushTimeout)
	defer cancel()
	select {
	case <-r.stop:
	default:
		close(r.stop)
	}
	if r.console != nil {
		<-r.stopped
	}
	if inv.siso == nil {
		r.loadSisoMetadata(inv)
	}
	r.sendPreamble(inv)
	r.flushConsole()

	start, failures := inv.startAndFailures(edges, result)
	metrics, err := readSisoMetrics(filepath.Join(inv.outDir, "siso_metrics.json"))
	switch {
	case err != nil:
		log.Printf("siso-bep: no step metrics: %v", err)
		metrics = nil
	case metrics.BuildID != inv.id:
		log.Printf("siso-bep: siso_metrics.json is from another build; skipping step metrics")
		metrics = nil
	}
	if metrics != nil {
		index := byOutput(failures)
		for _, t := range summarizeTargets(start, metrics.Steps, index) {
			r.send(targetConfiguredEvent(t), t.first)
			r.send(targetCompletedEvent(t), t.last)
		}
		for i := range metrics.Steps {
			s := &metrics.Steps[i]
			if s.Err || r.opts.allActions {
				_, end := s.times(start)
				r.send(actionEvent(start, s, index[firstOutput(s)]), end)
			}
		}
		r.send(buildMetricsEvent(start, metrics), finishedAt)
		profileCtx, profileCancel := context.WithTimeout(ctx, max(r.opts.flushTimeout/2, time.Millisecond))
		profileURI := r.uploadProfile(profileCtx, inv, start, metrics)
		profileCancel()
		r.send(buildToolLogsEvent(metrics, profileURI), finishedAt)
	}
	r.send(finishedEvent(finishedAt, result, failures), finishedAt)
	streamCtx := ctx
	if deadline, ok := ctx.Deadline(); ok {
		if reserve := r.opts.flushTimeout / 5; time.Until(deadline) > reserve {
			var streamCancel context.CancelFunc
			streamCtx, streamCancel = context.WithDeadline(ctx, deadline.Add(-reserve))
			defer streamCancel()
		}
	}
	if err := r.pub.finish(streamCtx); err != nil {
		log.Printf("siso-bep: BES upload incomplete: %v", err)
	}
	if err := r.pub.lifecycle(ctx, 2, finishedAt, invocationFinished(result)); err != nil {
		log.Printf("siso-bep: publish InvocationAttemptFinished: %v", err)
	}
}

func (inv *invocation) startAndFailures(edges *edgeTracker, result buildResult) (time.Time, []*stepFailure) {
	start := inv.started
	if inv.siso != nil && !inv.siso.StartTime.IsZero() {
		start = inv.siso.StartTime
	}
	failures := edges.failed()
	if len(failures) == 0 && result.exitCode != 0 {
		since := inv.started
		if !start.IsZero() && (since.IsZero() || start.Before(since)) {
			since = start
		}
		failures = readSisoFailures(filepath.Join(inv.outDir, "siso_output"), since)
	}
	return start, failures
}

// uploadProfile stores a Bazel-format trace of the build in Siso's CAS, as
// Bazel does for --profile, and returns its bytestream URI. It returns "" when
// the profile is disabled or the upload fails.
func (r *reporter) uploadProfile(ctx context.Context, inv *invocation, start time.Time, m *sisoMetrics) string {
	if r.opts.noProfile {
		return ""
	}
	target, ok := inv.casTarget()
	if !ok {
		return ""
	}
	profile, err := buildProfile(inv, start, m)
	if err != nil {
		log.Printf("siso-bep: build profile: %v", err)
		return ""
	}
	uri, err := uploadBlob(ctx, target, r.opts.credentialHelper, profile)
	if err != nil {
		log.Printf("siso-bep: upload profile: %v", err)
		return ""
	}
	return uri
}

func (r *reporter) close() { _ = r.conn.Close() }
