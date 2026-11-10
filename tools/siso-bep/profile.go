package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// Siso writes siso_trace.json, but in its own event vocabulary. Hermetiq's
// profile analytics (timeline, insights, phase breakdowns) expect Bazel's
// --profile JSON, so the wrapper builds a Bazel-shaped trace from
// siso_metrics.json instead:
//
//   - one "action processing" event per step, with args.mnemonic, args.target
//     and out, laid out on evaluator lanes so concurrent steps don't overlap;
//   - remote phase events inside each remote step (queue, input fetch,
//     execution, output upload) and cache-check events for cache lookups;
//   - "critical path component" events along Siso's prev chain;
//   - build phase markers and an "action count" counter.
//
// Category and marker names are the ones bep-nats/bep/profile_analytics.go
// and profile_parser.go recognize.

type traceEvent struct {
	Cat  string         `json:"cat,omitempty"`
	Name string         `json:"name"`
	Ph   string         `json:"ph"`
	Pid  int            `json:"pid"`
	Tid  int            `json:"tid"`
	Ts   int64          `json:"ts"`
	Dur  int64          `json:"dur,omitempty"`
	S    string         `json:"s,omitempty"`
	Out  string         `json:"out,omitempty"`
	Args map[string]any `json:"args,omitempty"`
}

type traceProfile struct {
	OtherData   map[string]string `json:"otherData"`
	TraceEvents []traceEvent      `json:"traceEvents"`
}

const (
	tracePid         = 1
	mainThreadTid    = 0
	criticalPathTid  = 1
	firstLaneTid     = 10
	categoryAction   = "action processing"
	categoryCritical = "critical path component"
)

func micros(nanos int64) int64 { return nanos / int64(time.Microsecond) }

// stepSpan is a step's interval in microseconds since the build start.
func stepSpan(s *stepMetric) (start, dur int64) {
	begin, end := s.activeInterval()
	start, dur = micros(begin), micros(end-begin)
	phases := micros(s.CacheNanos)
	if s.ranRemotely() {
		phases += micros(s.QueueNanos) + micros(s.InputFetchNanos) + micros(s.ExecNanos) + micros(s.OutputUploadNano)
	}
	// The parser drops events with ts or dur of zero, and drops phase events
	// that extend past their enclosing action's span.
	return max(start, 1), max(dur, phases, 1)
}

func stepDescription(s *stepMetric) string {
	out := firstOutput(s)
	if out == "" {
		out = s.label()
	}
	return fmt.Sprintf("%s %s", s.mnemonic(), out)
}

// buildProfile returns the gzipped Bazel-format trace for the build.
func buildProfile(inv *invocation, start time.Time, m *sisoMetrics) ([]byte, error) {
	steps := make([]*stepMetric, 0, len(m.Steps))
	for i := range m.Steps {
		steps = append(steps, &m.Steps[i])
	}
	sort.SliceStable(steps, func(i, j int) bool {
		a, _ := stepSpan(steps[i])
		b, _ := stepSpan(steps[j])
		return a < b
	})

	wall := max(micros(m.wallTime().Nanoseconds()), 1)
	events := []traceEvent{
		threadName(mainThreadTid, "Main Thread"),
		threadName(criticalPathTid, "Critical Path"),
	}

	// Greedy lane assignment: reuse the first lane that is free.
	var laneEnds []int64
	firstStart := wall
	for _, s := range steps {
		ts, dur := stepSpan(s)
		wall = max(wall, ts+dur)
		firstStart = min(firstStart, ts)
		lane := -1
		for i, end := range laneEnds {
			if end <= ts {
				lane = i
				break
			}
		}
		if lane < 0 {
			lane = len(laneEnds)
			laneEnds = append(laneEnds, 0)
			events = append(events, threadName(firstLaneTid+lane, fmt.Sprintf("skyframe-evaluator-%d", lane)))
		}
		laneEnds[lane] = ts + dur
		tid := firstLaneTid + lane
		events = append(events, traceEvent{
			Cat: categoryAction, Name: stepDescription(s), Ph: "X", Pid: tracePid, Tid: tid,
			Ts: ts, Dur: dur, Out: firstOutput(s),
			Args: map[string]any{"mnemonic": s.mnemonic(), "target": s.label(), "target_label": s.label()},
		})
		events = append(events, stepPhaseEvents(s, tid)...)
	}

	events = append(events, criticalPathEvents(m.Steps)...)
	events = append(events, actionCountEvents(steps)...)
	for _, marker := range []struct {
		name string
		ts   int64
	}{
		{"Launch Blaze", 0},
		{"Initialize command", 0},
		{"Analyze dependencies", 1},
		{"Execute build", firstStart},
		{"Complete build", wall},
		{"Finish", wall},
	} {
		events = append(events, traceEvent{
			Cat: "build phase marker", Name: marker.name, Ph: "i", S: "g",
			Pid: tracePid, Tid: mainThreadTid, Ts: marker.ts,
		})
	}

	profile := traceProfile{
		OtherData: map[string]string{
			"bazel_version":      inv.toolVersion(),
			"build_id":           inv.id,
			"output_base":        inv.workspaceDir,
			"date":               start.UTC().Format(time.RFC3339Nano),
			"profile_finish_ts":  fmt.Sprint(wall * 1000),
			"siso_bep_generated": "from siso_metrics.json",
		},
		TraceEvents: events,
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if err := json.NewEncoder(zw).Encode(profile); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func threadName(tid int, name string) traceEvent {
	return traceEvent{Name: "thread_name", Ph: "M", Pid: tracePid, Tid: tid, Args: map[string]any{"name": name}}
}

// stepPhaseEvents splits a remote step the way Bazel's profile does. Siso
// reports each phase's duration but not its start, so phases are laid out in
// order from the action start.
func stepPhaseEvents(s *stepMetric, tid int) []traceEvent {
	var out []traceEvent
	ts, _ := stepSpan(s)
	add := func(cat string, cur, dur int64) int64 {
		if dur <= 0 {
			return cur
		}
		out = append(out, traceEvent{Cat: cat, Name: cat, Ph: "X", Pid: tracePid, Tid: tid, Ts: cur, Dur: dur})
		return cur + dur
	}
	if s.CacheNanos > 0 {
		ts = add("remote action cache check", ts, micros(s.CacheNanos))
	}
	if !s.ranRemotely() {
		return out
	}
	queueDur := micros(s.QueueNanos)
	fetchDur := micros(s.InputFetchNanos)
	execDur := micros(s.ExecNanos)
	uploadDur := micros(s.OutputUploadNano)
	if remoteDur := queueDur + fetchDur + execDur + uploadDur; remoteDur > 0 {
		out = append(out, traceEvent{
			Cat: "remote action execution", Name: "remote action execution", Ph: "X", Pid: tracePid, Tid: tid,
			Ts: ts, Dur: remoteDur,
		})
	}
	ts = add("remote execution queuing time", ts, queueDur)
	ts = add("remote execution file fetching", ts, fetchDur)
	ts = add("remote execution process wall time", ts, execDur)
	add("remote execution upload time", ts, uploadDur)
	return out
}

func criticalPathEvents(steps []stepMetric) []traceEvent {
	chain := criticalPath(steps)
	out := make([]traceEvent, 0, len(chain))
	for _, s := range chain {
		ts, dur := stepSpan(s)
		out = append(out, traceEvent{
			Cat: categoryCritical, Name: "action '" + stepDescription(s) + "'", Ph: "X",
			Pid: tracePid, Tid: criticalPathTid, Ts: ts, Dur: dur,
		})
	}
	return out
}

// actionCountEvents samples how many steps, and how many local steps, run at
// each step boundary.
func actionCountEvents(steps []*stepMetric) []traceEvent {
	type edge struct {
		ts    int64
		delta int
		local bool
	}
	edges := make([]edge, 0, 2*len(steps))
	for _, s := range steps {
		ts, dur := stepSpan(s)
		local := s.strategy() == "local"
		edges = append(edges, edge{ts, 1, local}, edge{ts + dur, -1, local})
	}
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].ts != edges[j].ts {
			return edges[i].ts < edges[j].ts
		}
		return edges[i].delta < edges[j].delta
	})
	var out []traceEvent
	running, local := 0, 0
	for i, e := range edges {
		running += e.delta
		if e.local {
			local += e.delta
		}
		if i+1 < len(edges) && edges[i+1].ts == e.ts {
			continue
		}
		out = append(out, traceEvent{
			Name: "action count", Ph: "C", Pid: tracePid, Tid: mainThreadTid, Ts: max(e.ts, 1),
			Args: map[string]any{"action": running, "local action": local},
		})
	}
	return out
}
