package main

import (
	"os"
	"testing"
)

func benchmarkRewrite(b *testing.B, fields []string) {
	doc, err := os.ReadFile("../bench/json/doc.json")
	if err != nil {
		b.Fatal(err)
	}
	rw := &Rewrite{Redact: []string{"email"}}
	for b.Loop() {
		if _, err := rw.transform(doc, fields); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkRewriteFields(b *testing.B) {
	benchmarkRewrite(b, []string{"id", "name", "email", "created_at"})
}

func BenchmarkRewriteDocument(b *testing.B) {
	benchmarkRewrite(b, nil)
}
