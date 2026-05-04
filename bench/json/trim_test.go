package trim

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/bytedance/sonic"
	goccy "github.com/goccy/go-json"
)

var (
	doc, _ = os.ReadFile("doc.json")
	fields = []string{"id", "name", "email"}
)

func pickAny(items []map[string]any) []map[string]any {
	out := make([]map[string]any, len(items))
	for i, item := range items {
		out[i] = make(map[string]any, len(fields))
		for _, f := range fields {
			if v, ok := item[f]; ok {
				out[i][f] = v
			}
		}
	}
	return out
}

func BenchmarkStdAny(b *testing.B) {
	for b.Loop() {
		var items []map[string]any
		json.Unmarshal(doc, &items)
		json.Marshal(pickAny(items))
	}
}

func BenchmarkStdRaw(b *testing.B) {
	for b.Loop() {
		var items []map[string]json.RawMessage
		json.Unmarshal(doc, &items)
		out := make([]map[string]json.RawMessage, len(items))
		for i, item := range items {
			out[i] = make(map[string]json.RawMessage, len(fields))
			for _, f := range fields {
				if v, ok := item[f]; ok {
					out[i][f] = v
				}
			}
		}
		json.Marshal(out)
	}
}

func BenchmarkSonicAny(b *testing.B) {
	for b.Loop() {
		var items []map[string]any
		sonic.Unmarshal(doc, &items)
		sonic.Marshal(pickAny(items))
	}
}

func BenchmarkGoccyAny(b *testing.B) {
	for b.Loop() {
		var items []map[string]any
		goccy.Unmarshal(doc, &items)
		goccy.Marshal(pickAny(items))
	}
}
