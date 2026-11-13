package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/Hermetiq/hermetiq-k8s/tools/siso-bep/pb/bazel"
	bes "github.com/Hermetiq/hermetiq-k8s/tools/siso-bep/pb/build_event_stream"
)

// configurationID names the single configuration every Siso step uses.
const configurationID = "siso"

func progressID(n int32) *bes.BuildEventId {
	return &bes.BuildEventId{Id: &bes.BuildEventId_Progress{Progress: &bes.BuildEventId_ProgressId{OpaqueCount: n}}}
}

func startedEvent(inv *invocation) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_Started{Started: &bes.BuildEventId_BuildStartedId{}}},
		Children: []*bes.BuildEventId{
			{Id: &bes.BuildEventId_Pattern{Pattern: &bes.BuildEventId_PatternExpandedId{Pattern: inv.targets()}}},
			progressID(0),
		},
		Payload: &bes.BuildEvent_Started{Started: &bes.BuildStarted{
			Uuid:               inv.id,
			StartTime:          timestamppb.New(inv.started),
			BuildToolVersion:   inv.toolVersion(),
			OptionsDescription: strings.Join(inv.sisoFlags(), " "),
			Command:            "build",
			WorkingDirectory:   inv.workingDir,
			WorkspaceDirectory: inv.workspaceDir,
		}},
	}
}

// commandLineEvent sends the canonical command line. Hermetiq reads the
// remote_executor and remote_cache options from it to mark the build as using
// remote execution.
func commandLineEvent(inv *invocation) *bes.BuildEvent {
	options := make([]*bazel.Option, 0, len(inv.sisoFlags())+2)
	for _, f := range inv.sisoFlags() {
		name, value, _ := strings.Cut(strings.TrimLeft(f, "-"), "=")
		options = append(options, &bazel.Option{CombinedForm: f, OptionName: name, OptionValue: value})
	}
	if addr := inv.reapiAddress(); addr != "" {
		options = append(options,
			&bazel.Option{CombinedForm: "--remote_executor=" + addr, OptionName: "remote_executor", OptionValue: addr},
			&bazel.Option{CombinedForm: "--remote_cache=" + addr, OptionName: "remote_cache", OptionValue: addr},
		)
	}
	chunks := func(c ...string) *bazel.CommandLineSection_ChunkList {
		return &bazel.CommandLineSection_ChunkList{ChunkList: &bazel.ChunkList{Chunk: c}}
	}
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_StructuredCommandLine{
			StructuredCommandLine: &bes.BuildEventId_StructuredCommandLineId{CommandLineLabel: "canonical"},
		}},
		Payload: &bes.BuildEvent_StructuredCommandLine{StructuredCommandLine: &bazel.CommandLine{
			CommandLineLabel: "canonical",
			Sections: []*bazel.CommandLineSection{
				{SectionLabel: "executable", SectionType: chunks("siso")},
				{SectionLabel: "command", SectionType: chunks("ninja")},
				{SectionLabel: "command options", SectionType: &bazel.CommandLineSection_OptionList{
					OptionList: &bazel.OptionList{Option: options},
				}},
				{SectionLabel: "residual", SectionType: chunks(inv.targets()...)},
			},
		}},
	}
}

func unstructuredCommandLineEvent(inv *invocation) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_UnstructuredCommandLine{
			UnstructuredCommandLine: &bes.BuildEventId_UnstructuredCommandLineId{},
		}},
		Payload: &bes.BuildEvent_UnstructuredCommandLine{UnstructuredCommandLine: &bes.UnstructuredCommandLine{
			Args: inv.command,
		}},
	}
}

func optionsParsedEvent(inv *invocation) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_OptionsParsed{OptionsParsed: &bes.BuildEventId_OptionsParsedId{}}},
		Payload: &bes.BuildEvent_OptionsParsed{OptionsParsed: &bes.OptionsParsed{
			CmdLine:         inv.sisoFlags(),
			ExplicitCmdLine: inv.sisoFlags(),
			ToolTag:         "siso-bep",
		}},
	}
}

func buildMetadataEvent(inv *invocation) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id:      &bes.BuildEventId{Id: &bes.BuildEventId_BuildMetadata{BuildMetadata: &bes.BuildEventId_BuildMetadataId{}}},
		Payload: &bes.BuildEvent_BuildMetadata{BuildMetadata: &bes.BuildMetadata{Metadata: inv.metadata}},
	}
}

func workspaceStatusEvent(inv *invocation) *bes.BuildEvent {
	items := []*bes.WorkspaceStatus_Item{
		{Key: "BUILD_TIMESTAMP", Value: fmt.Sprint(inv.started.Unix())},
	}
	if inv.user != "" {
		items = append(items, &bes.WorkspaceStatus_Item{Key: "BUILD_USER", Value: inv.user})
	}
	if inv.host != "" {
		items = append(items, &bes.WorkspaceStatus_Item{Key: "BUILD_HOST", Value: inv.host})
	}
	return &bes.BuildEvent{
		Id:      &bes.BuildEventId{Id: &bes.BuildEventId_WorkspaceStatus{WorkspaceStatus: &bes.BuildEventId_WorkspaceStatusId{}}},
		Payload: &bes.BuildEvent_WorkspaceStatus{WorkspaceStatus: &bes.WorkspaceStatus{Item: items}},
	}
}

func configurationEvent(inv *invocation) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_Configuration{Configuration: &bes.BuildEventId_ConfigurationId{Id: configurationID}}},
		Payload: &bes.BuildEvent_Configuration{Configuration: &bes.Configuration{
			Mnemonic:     "siso",
			PlatformName: inv.platformName(),
			Cpu:          inv.cpu(),
		}},
	}
}

func progressEvent(n int32, stdout, stderr string) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id:       progressID(n),
		Children: []*bes.BuildEventId{progressID(n + 1)},
		Payload:  &bes.BuildEvent_Progress{Progress: &bes.Progress{Stdout: stdout, Stderr: stderr}},
	}
}

// targetSummary groups the steps that belong to one target.
type targetSummary struct {
	label   string
	kind    string
	first   time.Time
	last    time.Time
	failed  int
	steps   int
	failure string
}

func (m *stepMetric) endNanos() int64 {
	_, end := m.activeInterval()
	return end
}

func (m *stepMetric) times(buildStart time.Time) (begin, end time.Time) {
	beginNanos, endNanos := m.activeInterval()
	return buildStart.Add(time.Duration(beginNanos)), buildStart.Add(time.Duration(endNanos))
}

// summarizeTargets groups steps by target. Configured and completed events
// carry the target's first step start and last step end as their event times,
// which is how Hermetiq derives per-target duration.
func summarizeTargets(start time.Time, steps []stepMetric, failures map[string]*stepFailure) []*targetSummary {
	byLabel := map[string]*targetSummary{}
	var order []string
	for i := range steps {
		s := &steps[i]
		label := s.label()
		t := byLabel[label]
		begin, end := s.times(start)
		if t == nil {
			t = &targetSummary{label: label, first: begin, last: end}
			byLabel[label] = t
			order = append(order, label)
		}
		t.steps++
		// The step that finishes last names the kind: a link for an
		// executable, a compile for an object file.
		if !end.Before(t.last) || t.kind == "" {
			t.kind = s.mnemonic() + " rule"
		}
		if begin.Before(t.first) {
			t.first = begin
		}
		if end.After(t.last) {
			t.last = end
		}
		if s.Err {
			t.failed++
			if f := lookupFailure(failures, s); f != nil && t.failure == "" {
				t.failure = f.message()
			}
		}
	}
	out := make([]*targetSummary, 0, len(order))
	for _, label := range order {
		out = append(out, byLabel[label])
	}
	return out
}

func targetCompletedID(label string) *bes.BuildEventId {
	return &bes.BuildEventId{Id: &bes.BuildEventId_TargetCompleted{TargetCompleted: &bes.BuildEventId_TargetCompletedId{
		Label:         label,
		Configuration: &bes.BuildEventId_ConfigurationId{Id: configurationID},
	}}}
}

func targetConfiguredEvent(t *targetSummary) *bes.BuildEvent {
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_TargetConfigured{
			TargetConfigured: &bes.BuildEventId_TargetConfiguredId{Label: t.label},
		}},
		Children: []*bes.BuildEventId{targetCompletedID(t.label)},
		Payload:  &bes.BuildEvent_Configured{Configured: &bes.TargetConfigured{TargetKind: t.kind}},
	}
}

func targetCompletedEvent(t *targetSummary) *bes.BuildEvent {
	completed := &bes.TargetComplete{Success: t.failed == 0}
	if t.failed > 0 {
		msg := t.failure
		if msg == "" {
			msg = fmt.Sprintf("%d of %d steps failed", t.failed, t.steps)
		}
		completed.FailureDetail = &bazel.FailureDetail{Message: msg}
	}
	return &bes.BuildEvent{
		Id:      targetCompletedID(t.label),
		Payload: &bes.BuildEvent_Completed{Completed: completed},
	}
}

// actionEvent reports one step. Hermetiq drops successful actions unless the
// project stores them, so by default only failed steps are sent. Hermetiq
// keeps stdout and stderr only as bytestream:// files, so a failed step's
// output goes into the failure message instead.
func actionEvent(start time.Time, s *stepMetric, f *stepFailure) *bes.BuildEvent {
	begin, end := s.times(start)
	action := &bes.ActionExecuted{
		Success:   !s.Err,
		Type:      s.mnemonic(),
		StartTime: timestamppb.New(begin),
		EndTime:   timestamppb.New(end),
	}
	if out := firstOutput(s); out != "" {
		action.PrimaryOutput = &bes.File{Name: out}
	}
	if s.Err {
		action.ExitCode = 1
		msg := "step failed"
		if f != nil {
			action.ExitCode = int32(f.status) //nolint:gosec // G115: exit statuses fit in int32
			action.CommandLine = strings.Fields(f.command)
			msg = f.message()
		}
		action.FailureDetail = &bazel.FailureDetail{Message: msg}
	}
	primary := firstOutput(s)
	if primary == "" {
		primary = s.StepID
	}
	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_ActionCompleted{ActionCompleted: &bes.BuildEventId_ActionCompletedId{
			PrimaryOutput: primary,
			Label:         s.label(),
			Configuration: &bes.BuildEventId_ConfigurationId{Id: configurationID},
		}}},
		Payload: &bes.BuildEvent_Action{Action: action},
	}
}

func firstOutput(s *stepMetric) string {
	if len(s.Outputs) > 0 {
		return s.Outputs[0]
	}
	return ""
}

func lookupFailure(failures map[string]*stepFailure, s *stepMetric) *stepFailure {
	for _, out := range s.Outputs {
		if f := failures[out]; f != nil {
			return f
		}
		if f := failures[strings.TrimPrefix(out, "./")]; f != nil {
			return f
		}
	}
	return nil
}

// runnerCounts maps Siso step kinds onto the runner names Bazel reports, which
// is what Hermetiq's cache and remote-execution summaries count.
type runnerCounts struct {
	total, cacheHits, remote, local, internal, cacheMisses int32
}

func countRunners(steps []stepMetric) runnerCounts {
	var c runnerCounts
	for i := range steps {
		s := &steps[i]
		c.total++
		switch s.strategy() {
		case "remote cache hit":
			c.cacheHits++
		case "remote":
			c.remote++
		case "internal":
			c.internal++
		default:
			c.local++
		}
		// A step with a cache lookup that wasn't a hit is a miss.
		if !s.Cached && s.CacheNanos > 0 {
			c.cacheMisses++
		}
	}
	return c
}

func buildMetricsEvent(start time.Time, m *sisoMetrics) *bes.BuildEvent {
	type mnemonicData struct {
		count       int64
		first, last int64
	}
	byMnemonic := map[string]*mnemonicData{}
	var cpu time.Duration
	firstReady := int64(-1)
	for i := range m.Steps {
		s := &m.Steps[i]
		begin, end := s.activeInterval()
		d := byMnemonic[s.mnemonic()]
		if d == nil {
			d = &mnemonicData{first: begin, last: end}
			byMnemonic[s.mnemonic()] = d
		}
		d.count++
		d.first = min(d.first, begin)
		d.last = max(d.last, end)
		cpu += time.Duration(s.UtimeNanos + s.StimeNanos)
		if s.ranRemotely() {
			cpu += time.Duration(s.ExecNanos)
		}
		if s.ReadyNanos > 0 && (firstReady < 0 || s.ReadyNanos < firstReady) {
			firstReady = s.ReadyNanos
		}
	}
	mnemonics := make([]string, 0, len(byMnemonic))
	for k := range byMnemonic {
		mnemonics = append(mnemonics, k)
	}
	sort.Strings(mnemonics)
	actionData := make([]*bes.BuildMetrics_ActionSummary_ActionData, 0, len(mnemonics))
	epochMs := func(rel int64) int64 { return start.Add(time.Duration(rel)).UnixMilli() }
	for _, k := range mnemonics {
		d := byMnemonic[k]
		actionData = append(actionData, &bes.BuildMetrics_ActionSummary_ActionData{
			Mnemonic:        k,
			ActionsCreated:  d.count,
			ActionsExecuted: d.count,
			FirstStartedMs:  epochMs(d.first),
			LastEndedMs:     epochMs(d.last),
		})
	}

	c := countRunners(m.Steps)
	wall := m.wallTime()
	analysis := time.Duration(max(firstReady, 0))
	targets := map[string]bool{}
	packages := map[string]bool{}
	for i := range m.Steps {
		targets[m.Steps[i].label()] = true
		if pkg, _, ok := strings.Cut(strings.TrimPrefix(m.Steps[i].GNTarget, "//"), ":"); ok && pkg != "" {
			packages[pkg] = true
		}
	}

	return &bes.BuildEvent{
		Id: &bes.BuildEventId{Id: &bes.BuildEventId_BuildMetrics{BuildMetrics: &bes.BuildEventId_BuildMetricsId{}}},
		Payload: &bes.BuildEvent_BuildMetrics{BuildMetrics: &bes.BuildMetrics{
			ActionSummary: &bes.BuildMetrics_ActionSummary{
				ActionsCreated:                    int64(c.total),
				ActionsCreatedNotIncludingAspects: int64(c.total),
				ActionsExecuted:                   int64(c.total),
				ActionData:                        actionData,
				RunnerCount: []*bes.BuildMetrics_ActionSummary_RunnerCount{
					{Name: "total", Count: c.total},
					{Name: "remote cache hit", Count: c.cacheHits, ExecKind: "Remote"},
					{Name: "remote", Count: c.remote, ExecKind: "Remote"},
					{Name: "local", Count: c.local, ExecKind: "Local"},
					{Name: "internal", Count: c.internal},
				},
				ActionCacheStatistics: &bazel.ActionCacheStatistics{
					Hits:   c.cacheHits,
					Misses: c.cacheMisses,
				},
			},
			TargetMetrics: &bes.BuildMetrics_TargetMetrics{
				TargetsConfigured:                    int64(len(targets)),
				TargetsConfiguredNotIncludingAspects: int64(len(targets)),
			},
			PackageMetrics: &bes.BuildMetrics_PackageMetrics{PackagesLoaded: int64(len(packages))},
			TimingMetrics: &bes.BuildMetrics_TimingMetrics{
				WallTimeInMs:           wall.Milliseconds(),
				CpuTimeInMs:            cpu.Milliseconds(),
				AnalysisPhaseTimeInMs:  analysis.Milliseconds(),
				ExecutionPhaseTimeInMs: max(wall-analysis, 0).Milliseconds(),
			},
			CumulativeMetrics: &bes.BuildMetrics_CumulativeMetrics{NumAnalyses: 1, NumBuilds: 1},
		}},
	}
}

func (m *sisoMetrics) wallTime() time.Duration {
	if m.BuildDuration > 0 {
		return m.BuildDuration
	}
	var last int64
	for i := range m.Steps {
		last = max(last, m.Steps[i].endNanos())
	}
	return time.Duration(last)
}

// buildToolLogsEvent sends the logs Hermetiq parses: elapsed time, the
// critical path in Bazel's text format, a process summary and, when uploaded,
// the trace profile.
func buildToolLogsEvent(m *sisoMetrics, profileURI string) *bes.BuildEvent {
	c := countRunners(m.Steps)
	var parts []string
	for _, p := range []struct {
		n    int32
		name string
	}{{c.cacheHits, "remote cache hit"}, {c.remote, "remote"}, {c.local, "local"}, {c.internal, "internal"}} {
		if p.n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", p.n, p.name))
		}
	}
	logs := []*bes.File{
		{Name: "elapsed time", File: &bes.File_Contents{Contents: fmt.Appendf(nil, "%.3f", m.wallTime().Seconds())}},
		{Name: "process stats", File: &bes.File_Contents{Contents: fmt.Appendf(nil, "%d processes: %s.", c.total, strings.Join(parts, ", "))}},
	}
	if cp := criticalPathLog(m.Steps); cp != "" {
		logs = append(logs, &bes.File{Name: "critical path", File: &bes.File_Contents{Contents: []byte(cp)}})
	}
	if profileURI != "" {
		logs = append(logs, &bes.File{Name: "command.profile.gz", File: &bes.File_Uri{Uri: profileURI}})
	}
	return &bes.BuildEvent{
		Id:      &bes.BuildEventId{Id: &bes.BuildEventId_BuildToolLogs{BuildToolLogs: &bes.BuildEventId_BuildToolLogsId{}}},
		Payload: &bes.BuildEvent_BuildToolLogs{BuildToolLogs: &bes.BuildToolLogs{Log: logs}},
	}
}

// criticalPath follows Siso's prev links (the input each step waited on
// last) back from the step that finished last, and returns the chain in build
// order.
func criticalPath(steps []stepMetric) []*stepMetric {
	if len(steps) == 0 {
		return nil
	}
	byID := make(map[string]*stepMetric, len(steps))
	last := &steps[0]
	for i := range steps {
		byID[steps[i].StepID] = &steps[i]
		if steps[i].endNanos() > last.endNanos() {
			last = &steps[i]
		}
	}
	var chain []*stepMetric
	seen := map[string]bool{}
	for s := last; s != nil && !seen[s.StepID]; s = byID[s.Prev] {
		seen[s.StepID] = true
		chain = append(chain, s)
	}
	for i, j := 0, len(chain)-1; i < j; i, j = i+1, j-1 {
		chain[i], chain[j] = chain[j], chain[i]
	}
	return chain
}

// criticalPathLog writes the critical path in Bazel's text format, which
// bep-nats parses into critical path entries.
func criticalPathLog(steps []stepMetric) string {
	chain := criticalPath(steps)
	if len(chain) == 0 {
		return ""
	}
	var total, remote time.Duration
	for _, s := range chain {
		d := s.activeDuration()
		total += d
		if s.ranRemotely() || s.Cached {
			remote += d
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Critical Path: %.2fs, Remote (%.2f%% of the time)\n", total.Seconds(), percent(remote, total))
	for _, s := range chain {
		fmt.Fprintf(&b, "  %.2fs", s.activeDuration().Seconds())
		if s.ranRemotely() {
			fmt.Fprintf(&b, ", Remote (100.00%% of the time): [%s]", stepPhases(s))
		}
		fmt.Fprintf(&b, " action '%s %s'\n", s.mnemonic(), s.label())
	}
	return b.String()
}

func stepPhases(s *stepMetric) string {
	queue := time.Duration(s.QueueNanos)
	fetch := time.Duration(s.InputFetchNanos)
	upload := time.Duration(s.OutputUploadNano)
	process := time.Duration(s.ExecNanos)
	d := max(s.activeDuration(), queue+fetch+upload+process)
	other := max(d-queue-fetch-upload-process, 0)
	return fmt.Sprintf("queue: %.2f%%, fetch: %.2f%%, process: %.2f%%, upload: %.2f%%, other: %.2f%%",
		percent(queue, d), percent(fetch, d), percent(process, d), percent(upload, d), percent(other, d))
}

func percent(part, whole time.Duration) float64 {
	if whole <= 0 {
		return 0
	}
	return 100 * float64(part) / float64(whole)
}

func finishedEvent(at time.Time, result buildResult, failures []*stepFailure) *bes.BuildEvent {
	name, code, _ := result.bepExitCode()
	finished := &bes.BuildFinished{
		ExitCode:   &bes.BuildFinished_ExitCode{Name: name, Code: code},
		FinishTime: timestamppb.New(at),
	}
	if code != 0 {
		msg := fmt.Sprintf("siso exited with code %d", result.exitCode)
		switch {
		case result.startErr != nil:
			msg = result.startErr.Error()
		case len(failures) > 0:
			lines := make([]string, 0, len(failures))
			for _, f := range failures {
				lines = append(lines, f.message())
			}
			msg = strings.Join(lines, "\n\n")
		}
		finished.FailureDetail = &bazel.FailureDetail{Message: truncate(msg, maxFailureMessage)}
	}
	return &bes.BuildEvent{
		Id:          &bes.BuildEventId{Id: &bes.BuildEventId_BuildFinished{BuildFinished: &bes.BuildEventId_BuildFinishedId{}}},
		LastMessage: true,
		Payload:     &bes.BuildEvent_Finished{Finished: finished},
	}
}

const maxFailureMessage = 16 << 10

// truncate cuts s to at most n bytes, on a character boundary.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n] + "\n… (truncated)"
}
