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
						list.Set(i, protoreflect.ValueOfString(strings.ToValidUTF8(s, "\ufffd")))
					}
				} else if fd.Kind() == protoreflect.MessageKind || fd.Kind() == protoreflect.GroupKind {
					sanitizeMessage(list.Get(i).Message())
				}
			}
		case fd.IsMap():
			mp := v.Map()
			keyIsString := fd.MapKey().Kind() == protoreflect.StringKind
			kind := fd.MapValue().Kind()
			isString := kind == protoreflect.StringKind
			isMessage := kind == protoreflect.MessageKind || kind == protoreflect.GroupKind
			type badKeyEntry struct {
				oldKey protoreflect.MapKey
				newKey protoreflect.MapKey
				val    protoreflect.Value
			}
			var badKeys []badKeyEntry
			mp.Range(func(k protoreflect.MapKey, mv protoreflect.Value) bool {
				switch {
				case isString:
					if s := mv.String(); !utf8.ValidString(s) {
						mv = protoreflect.ValueOfString(strings.ToValidUTF8(s, "\ufffd"))
						mp.Set(k, mv)
					}
				case isMessage:
					sanitizeMessage(mv.Message())
				}
				if keyIsString {
					if ks := k.String(); !utf8.ValidString(ks) {
						badKeys = append(badKeys, badKeyEntry{
							oldKey: k,
							newKey: protoreflect.ValueOfString(strings.ToValidUTF8(ks, "\ufffd")).MapKey(),
							val:    mv,
						})
					}
				}
				return true
			})
			for _, e := range badKeys {
				mp.Clear(e.oldKey)
				mp.Set(e.newKey, e.val)
			}
		case fd.Kind() == protoreflect.StringKind:
			if s := v.String(); !utf8.ValidString(s) {
				m.Set(fd, protoreflect.ValueOfString(strings.ToValidUTF8(s, "\ufffd")))
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
