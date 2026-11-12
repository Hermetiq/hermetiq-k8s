package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"google.golang.org/protobuf/encoding/protowire"
)

// Siso's -frontend_file writes the Android/Soong ninja frontend protocol:
// varint length-delimited ninja.Status messages. Only the fields used here are
// decoded, so this file avoids vendoring the Soong proto. Field numbers come
// from Siso's toolsupport/soongutil/proto/frontend.proto.
const (
	statusTotalEdges   = 1
	statusEdgeStarted  = 4
	statusEdgeFinished = 5
	statusMessage      = 6

	totalEdgesCount = 1

	edgeStartedID      = 1
	edgeStartedTime    = 2
	edgeStartedOutputs = 4
	edgeStartedDesc    = 5
	edgeStartedCommand = 6

	edgeFinishedID       = 1
	edgeFinishedTime     = 2
	edgeFinishedStatus   = 3
	edgeFinishedOutput   = 4
	edgeFinishedCanceled = 15

	messageLevel = 1
	messageText  = 2
)

// Message levels from frontend.proto.
const (
	messageInfo    = 0
	messageWarning = 1
	messageError   = 2
	messageDebug   = 3
)

// maxFrontendMessageBytes bounds one message so a corrupt stream can't make
// the reader allocate without limit. Failed-step output is the largest field.
const maxFrontendMessageBytes = 64 << 20

type edgeStarted struct {
	ID      uint64
	StartMs uint64
	Outputs []string
	Desc    string
	Command string
}

type edgeFinished struct {
	ID       uint64
	EndMs    uint64
	Status   int64
	Output   string
	Canceled bool
}

type frontendMessage struct {
	Level uint64
	Text  string
}

type frontendEvent struct {
	TotalEdges uint64
	Started    *edgeStarted
	Finished   *edgeFinished
	Message    *frontendMessage
}

// readFrontend decodes the stream until EOF and calls handle for each message
// that carries a field this wrapper uses.
func readFrontend(r io.Reader, handle func(frontendEvent)) error {
	br := bufio.NewReader(r)
	for {
		size, err := binary.ReadUvarint(br)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read frontend message size: %w", err)
		}
		if size > maxFrontendMessageBytes {
			return fmt.Errorf("frontend message of %d bytes exceeds limit", size)
		}
		msg := make([]byte, size)
		if _, readErr := io.ReadFull(br, msg); readErr != nil {
			return fmt.Errorf("read frontend message: %w", readErr)
		}
		event, err := decodeStatus(msg)
		if err != nil {
			return err
		}
		if event.TotalEdges > 0 || event.Started != nil || event.Finished != nil || event.Message != nil {
			handle(event)
		}
	}
}

func decodeStatus(b []byte) (frontendEvent, error) {
	var event frontendEvent
	err := eachField(b, func(num protowire.Number, typ protowire.Type, v []byte, _ uint64) error {
		if typ != protowire.BytesType {
			return nil
		}
		switch int(num) {
		case statusTotalEdges:
			return eachField(v, func(n protowire.Number, _ protowire.Type, _ []byte, x uint64) error {
				if int(n) == totalEdgesCount {
					event.TotalEdges = x
				}
				return nil
			})
		case statusEdgeStarted:
			started, err := decodeEdgeStarted(v)
			event.Started = started
			return err
		case statusEdgeFinished:
			finished, err := decodeEdgeFinished(v)
			event.Finished = finished
			return err
		case statusMessage:
			m := &frontendMessage{}
			event.Message = m
			return eachField(v, func(n protowire.Number, _ protowire.Type, b []byte, x uint64) error {
				switch int(n) {
				case messageLevel:
					m.Level = x
				case messageText:
					m.Text = string(b)
				}
				return nil
			})
		}
		return nil
	})
	return event, err
}

func decodeEdgeStarted(b []byte) (*edgeStarted, error) {
	e := &edgeStarted{}
	err := eachField(b, func(num protowire.Number, _ protowire.Type, v []byte, x uint64) error {
		switch int(num) {
		case edgeStartedID:
			e.ID = x
		case edgeStartedTime:
			e.StartMs = x
		case edgeStartedOutputs:
			e.Outputs = append(e.Outputs, string(v))
		case edgeStartedDesc:
			e.Desc = string(v)
		case edgeStartedCommand:
			e.Command = string(v)
		}
		return nil
	})
	return e, err
}

func decodeEdgeFinished(b []byte) (*edgeFinished, error) {
	e := &edgeFinished{}
	err := eachField(b, func(num protowire.Number, _ protowire.Type, v []byte, x uint64) error {
		switch int(num) {
		case edgeFinishedID:
			e.ID = x
		case edgeFinishedTime:
			e.EndMs = x
		case edgeFinishedStatus:
			e.Status = protowire.DecodeZigZag(x)
		case edgeFinishedOutput:
			e.Output = string(v)
		case edgeFinishedCanceled:
			e.Canceled = x != 0
		}
		return nil
	})
	return e, err
}

// eachField walks one protobuf message. Varint fields arrive in x; bytes
// fields in v. Other wire types are skipped.
func eachField(b []byte, fn func(num protowire.Number, typ protowire.Type, v []byte, x uint64) error) error {
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return fmt.Errorf("frontend message: %w", protowire.ParseError(n))
		}
		b = b[n:]
		var (
			v []byte
			x uint64
		)
		switch typ {
		case protowire.VarintType:
			x, n = protowire.ConsumeVarint(b)
		case protowire.BytesType:
			v, n = protowire.ConsumeBytes(b)
		case protowire.Fixed32Type, protowire.Fixed64Type, protowire.StartGroupType, protowire.EndGroupType:
			n = protowire.ConsumeFieldValue(num, typ, b)
		default:
			n = protowire.ConsumeFieldValue(num, typ, b)
		}
		if n < 0 {
			return fmt.Errorf("frontend message field %d: %w", num, protowire.ParseError(n))
		}
		b = b[n:]
		if err := fn(num, typ, v, x); err != nil {
			return err
		}
	}
	return nil
}
