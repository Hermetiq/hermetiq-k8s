package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"time"

	buildpb "google.golang.org/genproto/googleapis/devtools/build/v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"

	bes "github.com/Hermetiq/hermetiq-k8s/tools/siso-bep/pb/build_event_stream"
)

// publisher sends one invocation's events to a Build Event Service. It is best
// effort: a BES failure is logged and never fails or blocks the build beyond
// the final flush timeout.
//
// The tool stream keeps every event until the server acknowledges it. After a
// stream error it reconnects and resends the unacknowledged events with their
// original sequence numbers, as Bazel does. The buffering approach follows
// BuildBuddy's build_event_publisher (MIT licensed).
type publisher struct {
	client       buildpb.PublishBuildEventClient
	md           metadata.MD
	projectID    string
	buildID      string
	invocationID string

	mu      sync.Mutex
	acked   int64 // events acknowledged so far, to tell a stream that made progress
	pending []*buildpb.PublishBuildToolEventStreamRequest
	nextSeq int64
	closed  bool
	cancel  context.CancelFunc
	wake    chan struct{}
	done    chan error
}

const maxReconnects = 10

// reconnectBackoff is multiplied by the attempt number. Tests shorten it.
var reconnectBackoff = time.Second

func newPublisher(client buildpb.PublishBuildEventClient, md metadata.MD, projectID, buildID, invocationID string) *publisher {
	return &publisher{
		client:       client,
		md:           md,
		projectID:    projectID,
		buildID:      buildID,
		invocationID: invocationID,
		nextSeq:      1,
		wake:         make(chan struct{}, 1),
		done:         make(chan error, 1),
	}
}

func (p *publisher) streamID(component buildpb.StreamId_BuildComponent) *buildpb.StreamId {
	return &buildpb.StreamId{BuildId: p.buildID, InvocationId: p.invocationID, Component: component}
}

// lifecycle publishes InvocationAttemptStarted (sequence 1) or
// InvocationAttemptFinished (sequence 2). bep-nats creates the invocation row
// from the started event before it returns.
func (p *publisher) lifecycle(ctx context.Context, seq int64, at time.Time, event *buildpb.BuildEvent) error {
	event.EventTime = timestamppb.New(at)
	req := &buildpb.PublishLifecycleEventRequest{
		BuildEvent: &buildpb.OrderedBuildEvent{
			StreamId:       p.streamID(buildpb.StreamId_CONTROLLER),
			SequenceNumber: seq,
			Event:          event,
		},
		ProjectId: p.projectID,
	}
	var err error
	for attempt := range 3 {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return fmt.Errorf("%w (last error: %w)", ctx.Err(), err)
			case <-time.After(time.Duration(attempt) * reconnectBackoff):
			}
		}
		callCtx, cancel := context.WithTimeout(metadata.NewOutgoingContext(ctx, p.md), 30*time.Second)
		_, err = p.client.PublishLifecycleEvent(callCtx, req)
		cancel()
		if err == nil {
			return nil
		}
	}
	return err
}

func invocationStarted() *buildpb.BuildEvent {
	return &buildpb.BuildEvent{Event: &buildpb.BuildEvent_InvocationAttemptStarted_{
		InvocationAttemptStarted: &buildpb.BuildEvent_InvocationAttemptStarted{AttemptNumber: 1},
	}}
}

// invocationFinished carries the same Bazel exit code as the Finished event;
// bep-nats applies it after Finished, so a raw process code (130 for Ctrl-C)
// would overwrite INTERRUPTED.
func invocationFinished(result buildResult) *buildpb.BuildEvent {
	_, code, status := result.bepExitCode()
	return &buildpb.BuildEvent{Event: &buildpb.BuildEvent_InvocationAttemptFinished_{
		InvocationAttemptFinished: &buildpb.BuildEvent_InvocationAttemptFinished{
			InvocationStatus: &buildpb.BuildStatus{Result: status, BuildToolExitCode: wrapperspb.Int32(code)},
		},
	}}
}

// send queues a Bazel build event on the tool stream. A zero at means now.
// Hermetiq uses event times for target durations, so post-build events carry
// the time the step actually happened.
func (p *publisher) send(event *bes.BuildEvent, at time.Time) error {
	sanitizeUTF8(event)
	packed, err := anypb.New(event)
	if err != nil {
		return fmt.Errorf("pack build event: %w", err)
	}
	if at.IsZero() {
		at = time.Now()
	}
	p.enqueue(&buildpb.BuildEvent{EventTime: timestamppb.New(at), Event: &buildpb.BuildEvent_BazelEvent{BazelEvent: packed}})
	return nil
}

func (p *publisher) enqueue(event *buildpb.BuildEvent) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	p.pending = append(p.pending, &buildpb.PublishBuildToolEventStreamRequest{
		OrderedBuildEvent: &buildpb.OrderedBuildEvent{
			StreamId:       p.streamID(buildpb.StreamId_TOOL),
			SequenceNumber: p.nextSeq,
			Event:          event,
		},
		ProjectId: p.projectID,
	})
	p.nextSeq++
	p.signal()
}

func (p *publisher) signal() {
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// start runs the tool stream in the background until finish is called.
func (p *publisher) start(ctx context.Context) {
	runCtx, cancel := context.WithCancel(ctx)
	p.mu.Lock()
	p.cancel = cancel
	p.mu.Unlock()
	go func() { p.done <- p.run(runCtx) }()
}

// finish queues ComponentStreamFinished and waits, until ctx is done, for
// every event to be acknowledged.
func (p *publisher) finish(ctx context.Context) error {
	defer func() {
		p.mu.Lock()
		cancel := p.cancel
		p.mu.Unlock()
		if cancel != nil {
			cancel()
		}
	}()
	p.enqueue(&buildpb.BuildEvent{
		EventTime: timestamppb.Now(),
		Event: &buildpb.BuildEvent_ComponentStreamFinished{
			ComponentStreamFinished: &buildpb.BuildEvent_BuildComponentStreamFinished{
				Type: buildpb.BuildEvent_BuildComponentStreamFinished_FINISHED,
			},
		},
	})
	p.mu.Lock()
	p.closed = true
	p.signal()
	p.mu.Unlock()
	select {
	case err := <-p.done:
		return err
	case <-ctx.Done():
		return fmt.Errorf("waiting for BES acknowledgements: %w", ctx.Err())
	}
}

// run keeps a stream open until every event is acknowledged. maxReconnects
// counts consecutive failures: a stream that got any acknowledgement resets
// it, so a long build survives periodic stream resets. After giving up it
// drops the queue, since nothing will send it.
func (p *publisher) run(ctx context.Context) error {
	err := p.runStreams(ctx)
	if err != nil {
		p.mu.Lock()
		p.closed = true
		dropped := len(p.pending)
		p.pending = nil
		p.mu.Unlock()
		if dropped > 0 {
			err = fmt.Errorf("%w (%d events not sent)", err, dropped)
		}
	}
	return err
}

func (p *publisher) runStreams(ctx context.Context) error {
	var lastErr error
	for attempt := 0; attempt <= maxReconnects; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if attempt > 0 {
			log.Printf("siso-bep: reconnecting to BES (attempt %d): %v", attempt, lastErr)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt) * reconnectBackoff):
			}
		}
		p.mu.Lock()
		ackedBefore := p.acked
		p.mu.Unlock()
		finished, err := p.runStream(ctx)
		if finished {
			return nil
		}
		lastErr = err
		p.mu.Lock()
		progressed := p.acked > ackedBefore
		p.mu.Unlock()
		if progressed {
			attempt = 0
		}
	}
	return fmt.Errorf("giving up on BES after %d reconnects: %w", maxReconnects, lastErr)
}

// runStream sends on one stream. It returns true once the stream is closed and
// every event has been acknowledged.
func (p *publisher) runStream(ctx context.Context) (bool, error) {
	streamCtx, cancel := context.WithCancel(metadata.NewOutgoingContext(ctx, p.md))
	defer cancel()
	stream, err := p.client.PublishBuildToolEventStream(streamCtx)
	if err != nil {
		return false, err
	}
	recvDone := make(chan error, 1)
	go func() {
		for {
			resp, err := stream.Recv()
			if err != nil {
				if errors.Is(err, io.EOF) {
					err = nil
				}
				recvDone <- err
				return
			}
			p.ack(resp.GetSequenceNumber())
		}
	}()

	var sentThrough int64
	for {
		p.mu.Lock()
		var batch []*buildpb.PublishBuildToolEventStreamRequest
		for _, req := range p.pending {
			if req.GetOrderedBuildEvent().GetSequenceNumber() > sentThrough {
				batch = append(batch, req)
			}
		}
		allQueued := p.closed
		p.mu.Unlock()

		for _, req := range batch {
			if err := stream.Send(req); err != nil {
				return false, fmt.Errorf("send event %d: %w", req.GetOrderedBuildEvent().GetSequenceNumber(), err)
			}
			sentThrough = req.GetOrderedBuildEvent().GetSequenceNumber()
		}
		if allQueued && len(batch) == 0 {
			if err := stream.CloseSend(); err != nil {
				return false, err
			}
			if err := <-recvDone; err != nil {
				return false, err
			}
			p.mu.Lock()
			unacked := len(p.pending)
			p.mu.Unlock()
			if unacked > 0 {
				return false, fmt.Errorf("stream closed with %d unacknowledged events", unacked)
			}
			return true, nil
		}
		if len(batch) > 0 {
			continue
		}
		select {
		case <-p.wake:
		case err := <-recvDone:
			if err == nil {
				err = errors.New("server closed the stream early")
			}
			return false, err
		case <-ctx.Done():
			return false, ctx.Err()
		}
	}
}

// ack drops every pending event up to and including seq.
func (p *publisher) ack(seq int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	i := 0
	for i < len(p.pending) && p.pending[i].GetOrderedBuildEvent().GetSequenceNumber() <= seq {
		i++
	}
	p.acked += int64(i)
	p.pending = p.pending[i:]
}
