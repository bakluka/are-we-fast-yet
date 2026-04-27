package main

import (
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type RateLimit struct {
	PerSecond int64
	Plans     map[string]int64
	windows   sync.Map
}

func (l *RateLimit) Call(req *Request, next Handler) *Response {
	client := req.Headers.Get("x-api-key")
	if client == "" {
		client = req.Client
	}
	limit, ok := l.Plans[client]
	if !ok {
		limit = l.PerSecond
	}
	used := l.window(client).Add(1)
	if used > limit {
		return Text(429).WithHeaders("retry-after", "1")
	}
	return next(req).WithHeaders("x-ratelimit-limit", strconv.FormatInt(limit, 10), "x-ratelimit-remaining", strconv.FormatInt(limit-used, 10))
}

func (l *RateLimit) window(client string) *atomic.Int64 {
	second := time.Now().Unix()
	key := client + "@" + strconv.FormatInt(second, 10)
	if counter, ok := l.windows.Load(key); ok {
		return counter.(*atomic.Int64)
	}
	l.windows.Delete(client + "@" + strconv.FormatInt(second-2, 10))
	counter, _ := l.windows.LoadOrStore(key, new(atomic.Int64))
	return counter.(*atomic.Int64)
}
