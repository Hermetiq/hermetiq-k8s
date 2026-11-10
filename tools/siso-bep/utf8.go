package main

import (
	"strings"
	"unicode/utf8"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// sanitizeUTF8 replaces invalid UTF-8 in every string field of m. proto3
// refuses to encode invalid UTF-8, and compiler output, which ends up in
// Progress and failure messages, can contain any bytes; one bad byte would
// otherwise drop the whole event.
func sanitizeUTF8(m proto.Message) {
	sanitizeMessage(m.ProtoReflect())
}

func sanitizeMessage(m protoreflect.Message) {
	m.Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		switch {
		case fd.IsList():
			list := v.List()
			for i := range list.Len() {
				if fd.Kind() == protoreflect.StringKind {
					if s := list.Get(i).String(); !utf8.ValidString(s) {
						list.Set(i, protoreflect.ValueOfString(strings.ToValidUTF8(s, "�")))
					}
				} else if fd.Kind() == protoreflect.MessageKind || fd.Kind() == protoreflect.GroupKind {
					sanitizeMessage(list.Get(i).Message())
				}
			}
		case fd.IsMap():
			mp := v.Map()
			mp.Range(func(k protoreflect.MapKey, mv protoreflect.Value) bool {
				switch fd.MapValue().Kind() {
				case protoreflect.StringKind:
					if s := mv.String(); !utf8.ValidString(s) {
						mp.Set(k, protoreflect.ValueOfString(strings.ToValidUTF8(s, "�")))
					}
				case protoreflect.MessageKind, protoreflect.GroupKind:
					sanitizeMessage(mv.Message())
				}
				return true
			})
		case fd.Kind() == protoreflect.StringKind:
			if s := v.String(); !utf8.ValidString(s) {
				m.Set(fd, protoreflect.ValueOfString(strings.ToValidUTF8(s, "�")))
			}
		case fd.Kind() == protoreflect.MessageKind || fd.Kind() == protoreflect.GroupKind:
			sanitizeMessage(v.Message())
		}
		return true
	})
}

// completeRunes splits b before a multi-byte character that is cut off at
// its end, so the rest can be sent with the next chunk.
func completeRunes(b []byte) (complete, rest []byte) {
	for i := len(b) - 1; i >= 0 && i >= len(b)-utf8.UTFMax; i-- {
		if utf8.RuneStart(b[i]) {
			if !utf8.FullRune(b[i:]) {
				return b[:i], b[i:]
			}
			break
		}
	}
	return b, nil
}
