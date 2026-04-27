package main

import (
	"sync"
	"time"
)

type cacheEntry struct {
	response *Response
	expires  time.Time
}

type Cache struct {
	TTL     time.Duration
	entries sync.Map
}

func (c *Cache) Call(req *Request, next Handler) *Response {
	if req.Verb != "GET" {
		return next(req)
	}
	now := time.Now()
	key := req.Target()
	if e, ok := c.entries.Load(key); ok && now.Before(e.(*cacheEntry).expires) {
		return e.(*cacheEntry).response.WithHeaders("x-cache", "hit")
	}
	resp := next(req)
	if resp.OK() {
		c.entries.Store(key, &cacheEntry{resp, now.Add(c.TTL)})
	}
	return resp.WithHeaders("x-cache", "miss")
}
