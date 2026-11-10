// Command siso-bep runs a Siso build and reports it to a Build Event Service
// as Bazel Build Event Protocol, so the build shows up in Hermetiq.
//
//	siso-bep --bes_backend=grpc://localhost:50091 --project=<id> -- \
//	    autoninja -C out/Default chrome
//
// Siso talks REAPI directly and sends no BEP. The wrapper passes Siso a
// -build_id equal to the BEP invocation ID, so the REAPI tool_invocation_id on
// every remote action (seen by BB CAL and the cache proxy) matches the
// invocation. It reports the console output while the build runs, reads
// Siso's -frontend_file stream for failed steps, and after the build turns
// siso_metrics.json into targets, actions and build metrics.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	buildpb "google.golang.org/genproto/googleapis/devtools/build/v1"
)

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

type options struct {
	besBackend       string
	headers          stringList
	metadata         stringList
	projectID        string
	user             string
	credentialHelper string
	resultsURL       string
	noFrontend       bool
	allActions       bool
	noProfile        bool
	flushTimeout     time.Duration
	command          []string
}

func parseOptions(args []string) (*options, error) {
	fs := flag.NewFlagSet("siso-bep", flag.ContinueOnError)
	o := &options{}
	fs.StringVar(&o.besBackend, "bes_backend", "", "Build Event Service address: grpc://host:port (plaintext) or grpcs://host:port (TLS). Empty runs the build without reporting.")
	fs.Var(&o.headers, "bes_header", "Extra BES request header as NAME=VALUE. Repeatable.")
	fs.Var(&o.metadata, "metadata", "Build metadata as KEY=VALUE, like Bazel's --build_metadata. Repeatable.")
	fs.StringVar(&o.projectID, "project", "", "Hermetiq project ID. BB CAL also needs Siso's -reapi_instance to equal it.")
	fs.StringVar(&o.user, "user", "", "Sent as x-forwarded-user, for BES endpoints that trust a forwarded identity (local labs).")
	fs.StringVar(&o.credentialHelper, "credential_helper", os.Getenv("SISO_CREDENTIAL_HELPER"), "Bazel-style credential helper for BES request headers. Defaults to $SISO_CREDENTIAL_HELPER.")
	fs.StringVar(&o.resultsURL, "results_url", "", "If set, printed with the invocation ID appended.")
	fs.BoolVar(&o.noFrontend, "no_frontend", false, "Don't pass -frontend_file to Siso. Failed steps' output then comes only from siso_output.")
	fs.BoolVar(&o.allActions, "all_actions", false, "Report every step as an action, not just failed ones. Hermetiq stores successful actions only for projects that enable it.")
	fs.BoolVar(&o.noProfile, "no_profile", false, "Don't upload a Bazel-format trace profile to Siso's CAS. Hermetiq's timeline and insights need it.")
	fs.DurationVar(&o.flushTimeout, "flush_timeout", 60*time.Second, "How long to wait for BES after the build finishes.")
	fs.Usage = func() {
		_, _ = fmt.Fprintf(fs.Output(), "usage: siso-bep [flags] -- <siso ninja | autoninja> [build args]\n\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	o.command = fs.Args()
	if len(o.command) == 0 {
		fs.Usage()
		return nil, errors.New("no build command given")
	}
	return o, nil
}

func main() {
	log.SetFlags(0)
	opts, err := parseOptions(os.Args[1:])
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			os.Exit(0)
		}
		log.Printf("siso-bep: %v", err)
		os.Exit(2)
	}
	os.Exit(run(opts))
}

func run(opts *options) int {
	ctx := context.Background()
	args, ids := prepareSisoArgs(opts.command)
	outDir := sisoOutDir(args)

	inv := &invocation{
		id:      ids.invocationID,
		buildID: ids.jobID,
		outDir:  outDir,
		command: opts.command,
		started: time.Now(),
	}
	inv.collectEnvironment(ctx, opts.metadata)

	var rep *reporter
	if opts.besBackend != "" {
		r, err := newReporter(ctx, opts, inv)
		if err != nil {
			log.Printf("siso-bep: BES disabled: %v", err)
		} else {
			rep = r
			defer rep.close()
			if opts.resultsURL != "" {
				_, _ = fmt.Fprintf(os.Stderr, "siso-bep: results at %s%s\n", opts.resultsURL, inv.id)
			}
		}
	}
	return runBuild(ctx, opts, args, inv, rep)
}

// runBuild runs the command and, when rep is non-nil, reports it.
func runBuild(ctx context.Context, opts *options, args []string, inv *invocation, rep *reporter) int {
	var fifo string
	if rep != nil && !opts.noFrontend {
		dir, err := os.MkdirTemp("", "siso-bep-")
		if err == nil {
			defer func() { _ = os.RemoveAll(dir) }()
			fifo = filepath.Join(dir, "frontend")
			if err := syscall.Mkfifo(fifo, 0o600); err != nil {
				log.Printf("siso-bep: no frontend stream: %v", err)
				fifo = ""
			} else {
				args = insertSisoFlags(args, "--frontend_file="+fifo)
			}
		}
	}

	cmd := exec.CommandContext(ctx, args[0], args[1:]...) //nolint:gosec // G204: running the user's build command is the point
	// The build runs in its own process group so the wrapper can forward
	// SIGINT and SIGTERM to it and everything it spawns, then stay alive to
	// report the interrupted build. Outside the terminal's foreground group
	// the build can't read the terminal, so it gets no stdin; Siso doesn't
	// read it.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// The console is buffered for Progress events only when reporting;
	// otherwise output goes straight to the terminal.
	console := newConsole(os.Stdout, os.Stderr, rep != nil)
	cmd.Stdout = console.stdout
	cmd.Stderr = console.stderr

	signals := make(chan os.Signal, 1)
	notifySignals(signals)
	defer signal.Stop(signals)

	if err := cmd.Start(); err != nil {
		log.Printf("siso-bep: %v", err)
		if rep != nil {
			rep.finishBuild(ctx, inv, nil, buildResult{exitCode: 2, startErr: err})
		}
		return 2
	}

	var edges *edgeTracker
	frontendDone := make(chan struct{})
	if fifo != "" {
		edges = newEdgeTracker(console.stdout, console.stderr)
		go func() {
			defer close(frontendDone)
			edges.read(fifo)
		}()
	} else {
		close(frontendDone)
	}
	if rep != nil {
		rep.startStreaming(inv, console)
	}

	var received atomic.Value
	waited := make(chan struct{})
	forwardDone := make(chan struct{})
	go func() {
		defer close(forwardDone)
		for {
			select {
			case sig := <-signals:
				received.Store(sig)
				if s, ok := sig.(syscall.Signal); ok {
					_ = syscall.Kill(-cmd.Process.Pid, s)
				}
			case <-waited:
				return
			}
		}
	}()

	waitErr := cmd.Wait()
	close(waited)
	<-forwardDone
	signal.Stop(signals)
	result := buildResult{exitCode: exitCode(waitErr), interrupted: signaled(waitErr)}
	if sig, ok := received.Load().(syscall.Signal); ok {
		result.interrupted = true
		if result.exitCode == 0 {
			result.exitCode = 128 + int(sig)
		}
	}
	if fifo != "" {
		waitFrontend(fifo, frontendDone)
	}
	if rep != nil {
		rep.finishBuild(ctx, inv, edges, result)
	}
	return result.exitCode
}

// notifySignals registers the signals forwarded to the build. Tests replace
// it to deliver signals without signaling the test process.
var notifySignals = func(c chan<- os.Signal) { signal.Notify(c, os.Interrupt, syscall.SIGTERM) }

type buildResult struct {
	exitCode    int
	interrupted bool
	startErr    error
}

// bepExitCode is the result in Bazel's terms, used for both the Finished
// event and InvocationAttemptFinished so Hermetiq stores one exit code.
func (r buildResult) bepExitCode() (name string, code int32, status buildpb.BuildStatus_Result) {
	switch {
	case r.interrupted:
		return "INTERRUPTED", 8, buildpb.BuildStatus_CANCELLED //nolint:misspell // the proto enum's name
	case r.exitCode != 0:
		return "BUILD_FAILURE", 1, buildpb.BuildStatus_COMMAND_FAILED
	default:
		return "SUCCESS", 0, buildpb.BuildStatus_COMMAND_SUCCEEDED
	}
}

// exitCode is the build's exit status, with 128+signal for a build killed by
// a signal, as a shell reports it.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	exitErr, ok := errors.AsType[*exec.ExitError](err)
	if !ok {
		return 1
	}
	if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return exitErr.ExitCode()
}

func signaled(err error) bool {
	exitErr, ok := errors.AsType[*exec.ExitError](err)
	if !ok {
		return false
	}
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	return ok && status.Signaled()
}

// unblockFIFO opens and closes the write end, so a reader still waiting to
// open the FIFO (Siso never opened it, say because it failed early) returns.
func unblockFIFO(path string) {
	f, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0) //nolint:gosec // G304: our own FIFO
	if err == nil {
		_ = f.Close()
	}
}

// waitFrontend waits for the frontend reader goroutine to finish, retrying
// unblockFIFO in case the build exited before the reader entered open(2).
func waitFrontend(path string, done <-chan struct{}) {
	unblockFIFO(path)
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			unblockFIFO(path)
		case <-deadline:
			log.Printf("siso-bep: frontend stream did not close")
			return
		}
	}
}

type sisoIDs struct {
	invocationID string
	jobID        string
}

// prepareSisoArgs reuses -build_id and -job_id when the caller passed them,
// and otherwise adds them. Siso sends -build_id as the REAPI
// tool_invocation_id and -job_id as correlated_invocations_id.
func prepareSisoArgs(command []string) ([]string, sisoIDs) {
	args := append([]string(nil), command...)
	ids := sisoIDs{
		invocationID: flagValue(args, "build_id"),
		jobID:        flagValue(args, "job_id"),
	}
	if ids.invocationID == "" {
		ids.invocationID = uuid.NewString()
		args = insertSisoFlags(args, "--build_id="+ids.invocationID)
	}
	if ids.jobID == "" {
		ids.jobID = uuid.NewString()
		args = insertSisoFlags(args, "--job_id="+ids.jobID)
	}
	return args, ids
}

// insertSisoFlags puts flags where Siso parses them: right after the "ninja"
// subcommand, or after argv[0] for wrappers such as autoninja. Go's flag
// package stops at the first target, so appending them would turn them into
// targets. Callers pass flags with two dashes: autoninja treats any argument
// starting with -j as its jobs flag and -t as a tool, so it would rewrite
// -job_id=X into --remote_jobs=ob_id=X and Siso would reject it.
func insertSisoFlags(args []string, flags ...string) []string {
	if len(args) == 0 {
		return append([]string(nil), flags...)
	}
	at := 1
	if !strings.Contains(filepath.Base(args[0]), "autoninja") {
		// The subcommand can follow Siso's own flags and their values
		// (siso -log_dir /tmp ninja ...), so look for it up to -C or --.
		for i := 1; i < len(args); i++ {
			a := args[i]
			if a == "ninja" {
				at = i + 1
				break
			}
			if a == "--" || strings.HasPrefix(a, "-C") {
				break
			}
		}
	}
	out := make([]string, 0, len(args)+len(flags))
	out = append(out, args[:at]...)
	out = append(out, flags...)
	return append(out, args[at:]...)
}

// flagValue finds -name=value, --name=value, -name value or --name value.
// For single-letter flags such as -C it also matches -Cvalue. When a flag
// appears more than once, the last value wins.
func flagValue(args []string, name string) string {
	var val string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			break
		}
		trimmed := strings.TrimLeft(a, "-")
		if trimmed == a || len(a)-len(trimmed) > 2 {
			continue
		}
		if v, ok := strings.CutPrefix(trimmed, name+"="); ok {
			val = v
			continue
		}
		if trimmed == name && i+1 < len(args) {
			val = args[i+1]
			i++
			continue
		}
		if len(name) == 1 && len(a) > 2 && strings.HasPrefix(a, "-"+name) {
			val = a[2:]
		}
	}
	return val
}

func sisoOutDir(args []string) string {
	if dir := flagValue(args, "C"); dir != "" {
		return dir
	}
	return "."
}
