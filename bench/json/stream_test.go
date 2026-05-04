//go:build goexperiment.jsonv2

package trim

import (
	"bytes"
	"encoding/json/jsontext"
	"slices"
	"testing"
)

func stream(payload []byte) []byte {
	dec := jsontext.NewDecoder(bytes.NewReader(payload))
	var out bytes.Buffer
	enc := jsontext.NewEncoder(&out)
	dec.ReadToken()
	enc.WriteToken(jsontext.BeginArray)
	for dec.PeekKind() == '{' {
		dec.ReadToken()
		enc.WriteToken(jsontext.BeginObject)
		for dec.PeekKind() != '}' {
			name, _ := dec.ReadToken()
			if !slices.Contains(fields, name.String()) {
				dec.SkipValue()
				continue
			}
			enc.WriteToken(name)
			value, _ := dec.ReadValue()
			enc.WriteValue(value)
		}
		dec.ReadToken()
		enc.WriteToken(jsontext.EndObject)
	}
	enc.WriteToken(jsontext.EndArray)
	return out.Bytes()
}

func BenchmarkJsontextStream(b *testing.B) {
	for b.Loop() {
		stream(doc)
	}
}
