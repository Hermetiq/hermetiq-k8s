package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// stepMetric is one line of Siso's siso_metrics.json (build/metrics.go in
// Siso). Only the fields this wrapper reports are decoded. Times are
// nanoseconds; *_start_nanos and ready_nanos are relative to the build start.
type stepMetric struct {
	StepID           string   `json:"step_id"`
	BuildID          string   `json:"build_id"`
	Rule             string   `json:"rule"`
	Action           string   `json:"action"`
	Outputs          []string `json:"outputs"`
	GNTarget         string   `json:"gn_target"`
	Prev             string   `json:"prev"`
	Spans            []span   `json:"spans"`
	ExecStartNanos   int64    `json:"exec_start_nanos"`
	Digest           string   `json:"digest"`
	ReadyNanos       int64    `json:"ready_nanos"`
	DurationNanos    int64    `json:"duration_nanos"`
	ActionStartNanos int64    `json:"action_start_nanos"`
	ActionEndNanos   int64    `json:"action_end_nanos"`
	QueueNanos       int64    `json:"queue_nanos"`
	ExecNanos        int64    `json:"exec_nanos"`
	WorkerNanos      int64    `json:"worker_nanos"`
	InputFetchNanos  int64    `json:"input_fetch_nanos"`
	OutputUploadNano int64    `json:"output_upload_nanos"`
	CacheNanos       int64    `json:"cache_nanos"`
	UtimeNanos       int64    `json:"utime_nanos"`
	StimeNanos       int64    `json:"stime_nanos"`
	MaxRSS           int64    `json:"max_rss"`
	Inputs           int64    `json:"inputs"`
	IsRemote         bool     `json:"is_remote"`
	IsLocal          bool     `json:"is_local"`
	Cached           bool     `json:"cached"`
	Fallback         bool     `json:"fallback"`
	NoExec           bool     `json:"no_exec"`
	RemoteRetry      int64    `json:"remote_retry"`
	Err              bool     `json:"err"`
}

// span is one entry of a step's spans list.
type span struct {
	Name    string `json:"name"`
	StartNs int64  `json:"start_ns"`
	DurNs   int64  `json:"duration_ns"`
}

// activeStartNanos is when the step started doing work. action_start_nanos is
// too early for this: a step waits there for one of Siso's --remote_jobs or
// local job slots, and a remote step that hit its deadline waits again for each
// retry. In a large build those waits are most of the interval and would count
// as thousands of concurrent actions. A remote step therefore starts at its last
// execution attempt (not its pre-slot cache check) and a local or fallback step
// starts at exec_start_nanos or its exec-local-run span.
func (m *stepMetric) activeStartNanos() int64 {
	switch {
	case m.ranRemotely():
		for _, sp := range slices.Backward(m.Spans) {
			if sp.Name == "exec-remote-exec-attempt" && sp.StartNs > 0 {
				return sp.StartNs
			}
		}
	case !m.Cached && !m.NoExec:
		if m.ExecStartNanos > m.ActionStartNanos {
			return m.ExecStartNanos
		}
		for _, sp := range slices.Backward(m.Spans) {
			if sp.Name == "exec-local-run" && sp.StartNs > m.ActionStartNanos {
				return sp.StartNs
			}
		}
	}
	if m.ActionStartNanos > 0 {
		return m.ActionStartNanos
	}
	return m.ReadyNanos
}

// activeInterval is the step's working time in nanoseconds since the build
// started.
func (m *stepMetric) activeInterval() (begin, end int64) {
	begin = m.activeStartNanos()
	end = m.ActionEndNanos
	if end <= 0 {
		stepStart := m.ActionStartNanos
		if stepStart <= 0 {
			stepStart = m.ReadyNanos
		}
		end = stepStart + m.DurationNanos
	}
	if end < begin {
		end = begin
	}
	return begin, end
}

func (m *stepMetric) activeDuration() time.Duration {
	begin, end := m.activeInterval()
	return time.Duration(end - begin)
}

// isStep is false for the final whole-build record, which has only build_id,
// duration_nanos and err.
func (m *stepMetric) isStep() bool { return m.StepID != "" }

// strategy names the runner the way Bazel's BuildMetrics runner counts do, so
// the dashboard's cache and remote-execution summaries work unchanged.
//
// Siso sets both is_remote and is_local on a step that fell back to local
// execution, so is_local is checked first: the result came from the local run.
func (m *stepMetric) strategy() string {
	switch {
	case m.Cached:
		return "remote cache hit"
	case m.NoExec:
		return "internal"
	case m.IsLocal:
		return "local"
	case m.IsRemote:
		return "remote"
	default:
		return "local"
	}
}

// ranRemotely reports whether the step's result came from remote execution.
func (m *stepMetric) ranRemotely() bool { return m.strategy() == "remote" }

// label is the step's target. GN builds set gn_target ("base:base"), which
// gets its "//" back. Hand-written ninja files have none, so the first output
// stands in.
func (m *stepMetric) label() string {
	if m.GNTarget != "" {
		return "//" + m.GNTarget
	}
	if len(m.Outputs) > 0 {
		return m.Outputs[0]
	}
	return m.StepID
}

// mnemonic groups steps by what they do. GN gives every action() target its own
// ninja rule ("__base_foo___build_toolchain_linux_clang_x64__rule"), thousands
// in Chromium, so those all count as "action".
func (m *stepMetric) mnemonic() string {
	if strings.HasPrefix(m.Action, "__") {
		return "action"
	}
	if m.Action != "" {
		return m.Action
	}
	return m.Rule
}

// sisoMetrics is the parsed metrics file.
type sisoMetrics struct {
	BuildID       string
	Steps         []stepMetric
	BuildDuration time.Duration
	BuildErr      bool
}

func readSisoMetrics(path string) (*sisoMetrics, error) {
	f, err := os.Open(path) //nolint:gosec // G304: Siso's own output file in the build's out dir
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	out := &sisoMetrics{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
	line := 0
	for sc.Scan() {
		line++
		var m stepMetric
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			return nil, fmt.Errorf("%s line %d: %w", path, line, err)
		}
		if !m.isStep() {
			out.BuildID = m.BuildID
			out.BuildDuration = time.Duration(m.DurationNanos)
			out.BuildErr = m.Err
			continue
		}
		out.Steps = append(out.Steps, m)
	}
	return out, sc.Err()
}

// sisoMetadata is Siso's siso_metadata.json.
type sisoMetadata struct {
	SisoVersion   string    `json:"siso_version"`
	StartTime     time.Time `json:"start_time"`
	BuildID       string    `json:"build_id"`
	Targets       []string  `json:"targets"`
	CommandLine   []string  `json:"command_line_args"`
	ReapiInstance string    `json:"reapi_instance"`
	Machine       struct {
		Platform struct {
			Architecture string `json:"architecture"`
			OS           string `json:"os"`
			OSVersion    string `json:"os_version"`
		} `json:"platform"`
		CPU struct {
			Brand         string `json:"brand"`
			LogicalCores  int    `json:"logical_cores"`
			PhysicalCores int    `json:"physical_cores"`
		} `json:"cpu"`
		Memory struct {
			Total int64 `json:"total"`
		} `json:"memory"`
	} `json:"machine"`
}

func readSisoMetadata(path string) (*sisoMetadata, error) {
	b, err := os.ReadFile(path) //nolint:gosec // G304: Siso's own output file in the build's out dir
	if err != nil {
		return nil, err
	}
	var md sisoMetadata
	if err := json.Unmarshal(b, &md); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &md, nil
}

var (
	sisoFailedHeader = regexp.MustCompile(`^FAILED(?:\[[^\]]*\])?: \S+ "((?:[^"\\]|\\.)*)" (.*)$`)
	sisoOtherHeader  = regexp.MustCompile(`^(?:SUCCESS|FALLBACK|RETRY)(?:\[[^\]]*\])?: \S+ "`)
	sisoExitStatus   = regexp.MustCompile(`exit=(-?\d+)`)
)

// maxSisoOutputBytes bounds what is read from siso_output, which holds only
// failed steps and warnings but has no size limit of its own.
const maxSisoOutputBytes = 64 << 20

// sisoOutputMtimeSlack accounts for coarse kernel filesystem timestamps (for
// example Linux's tick-granular inode mtime), which can round a file written
// just after time.Now() to a few milliseconds before it.
const sisoOutputMtimeSlack = 50 * time.Millisecond

// readSisoFailures parses the FAILED blocks of Siso's siso_output. Siso writes
// the file in every mode, so it still has failed steps when the frontend
// stream doesn't: --quiet, which depot_tools adds under AI agents, takes
// priority over -frontend_file. It returns nil unless the file was written at
// or after since, so an older build's failures aren't reported.
//
//	FAILED: <step id> "./obj/a.o" CXX obj/a.o
//	err: remote-exec <digest> failed: exit=1
//	digest: <digest>
//	build step: cxx "./obj/a.o"
//	siso_rule: cxx
//	/usr/bin/g++ -c a.cc -o obj/a.o
//	stderr:
//	a.cc:1: error: boom
func readSisoFailures(path string, since time.Time) []*stepFailure {
	st, err := os.Stat(path)
	if err != nil || (!since.IsZero() && st.ModTime().Before(since.Add(-sisoOutputMtimeSlack))) {
		return nil
	}
	f, err := os.Open(path) //nolint:gosec // G304: Siso's own output file in the build's out dir
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	var p sisoFailureParser
	sc := bufio.NewScanner(io.LimitReader(f, maxSisoOutputBytes))
	sc.Buffer(make([]byte, 0, 1<<16), 16<<20)
	for sc.Scan() {
		p.feed(sc.Text())
	}
	p.finish()
	return p.failures
}

type sisoFailureParser struct {
	failures []*stepFailure
	current  *stepFailure
	output   []string
	inOutput bool
}

func (p *sisoFailureParser) finish() {
	if p.current != nil {
		p.current.output = strings.TrimSpace(strings.Join(p.output, "\n"))
		p.failures = append(p.failures, p.current)
	}
	p.current, p.output, p.inOutput = nil, nil, false
}

func (p *sisoFailureParser) feed(line string) {
	if strings.HasPrefix(line, "\f") {
		p.finish()
		line = strings.TrimLeft(line, "\f")
		if line == "" {
			return
		}
	}
	if m := sisoFailedHeader.FindStringSubmatch(line); m != nil {
		p.finish()
		outPath := strings.ReplaceAll(strings.TrimPrefix(m[1], "./"), `\"`, `"`)
		p.current = &stepFailure{desc: m[2], outputs: []string{outPath}, status: 1}
		return
	}
	if sisoOtherHeader.MatchString(line) {
		p.finish()
		return
	}
	if p.current == nil {
		return
	}
	p.feedStepLine(line)
}

func (p *sisoFailureParser) feedStepLine(line string) {
	switch {
	case line == "stderr:" || line == "stdout:":
		p.inOutput = true
	case strings.HasPrefix(line, "auxiliary outputs:"):
		p.inOutput = false
	case p.inOutput:
		p.output = append(p.output, line)
	case strings.HasPrefix(line, "err: "):
		p.current.err = strings.TrimPrefix(line, "err: ")
		if m := sisoExitStatus.FindStringSubmatch(line); m != nil {
			if status, parseErr := strconv.ParseInt(m[1], 10, 32); parseErr == nil {
				p.current.status = status
			}
		}
	case strings.HasPrefix(line, "build step: "):
		// Any unlabelled line before "build step:" was a continuation of a
		// multi-line err: message rather than the step's command line.
		if p.current.command != "" {
			if p.current.err != "" {
				p.current.err += "\n" + p.current.command
			}
			p.current.command = ""
		}
	case strings.HasPrefix(line, "digest: "), strings.HasPrefix(line, "siso_rule: "), strings.HasPrefix(line, "stacktrace: "), line == "":
	case p.current.command == "":
		p.current.command = line
	}
}
