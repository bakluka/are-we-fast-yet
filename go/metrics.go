package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

var buckets = []float64{0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, math.Inf(1)}

type Metrics struct {
	responses [5]atomic.Int64
	latency   [10]atomic.Int64
}

func (m *Metrics) Call(req *Request, next Handler) *Response {
	if req.Path == "/metrics" {
		return m.report()
	}
	started := time.Now()
	resp := next(req)
	elapsed := float64(time.Since(started).Nanoseconds()) / 1e6
	m.responses[resp.Status/100-1].Add(1)
	for i, b := range buckets {
		if elapsed <= b {
			m.latency[i].Add(1)
			break
		}
	}
	return resp
}

func (m *Metrics) report() *Response {
	var b strings.Builder
	for i := range m.responses {
		fmt.Fprintf(&b, "gateway_responses_total{class=\"%dxx\"} %d\n", i+1, m.responses[i].Load())
	}
	var seen int64
	for i, bucket := range buckets {
		seen += m.latency[i].Load()
		le := strconv.FormatFloat(bucket, 'g', -1, 64)
		if math.IsInf(bucket, 1) {
			le = "+Inf"
		}
		fmt.Fprintf(&b, "gateway_request_duration_ms_bucket{le=\"%s\"} %d\n", le, seen)
	}
	resp := Text(200)
	return resp.WithBody([]byte(b.String()))
}
