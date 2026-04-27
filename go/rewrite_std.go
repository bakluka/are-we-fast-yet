//go:build !goexperiment.jsonv2

package main

import (
	"encoding/json"
	"slices"
)

func (rw *Rewrite) transform(body []byte, fields []string) ([]byte, error) {
	var doc any
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, err
	}
	if items, ok := doc.([]any); ok && fields != nil {
		for i, item := range items {
			object, _ := item.(map[string]any)
			picked := make(map[string]any, len(fields))
			for _, f := range fields {
				if v, ok := object[f]; ok {
					picked[f] = v
				}
			}
			items[i] = picked
		}
	}
	return json.Marshal(rw.reshape(doc))
}

func (rw *Rewrite) reshape(node any) any {
	switch n := node.(type) {
	case map[string]any:
		out := make(map[string]any, len(n))
		for key, value := range n {
			if s, ok := value.(string); ok && slices.Contains(rw.Redact, key) {
				out[camelize(key)] = mask(s)
			} else {
				out[camelize(key)] = rw.reshape(value)
			}
		}
		return out
	case []any:
		out := make([]any, len(n))
		for i, value := range n {
			out[i] = rw.reshape(value)
		}
		return out
	default:
		return node
	}
}
