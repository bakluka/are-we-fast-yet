package main

import (
	"net"
	"strconv"
	"sync/atomic"
)

const via = "1.1 gateway"

type Upstream struct {
	Port     int
	inflight atomic.Int64
	idle     chan *Stream
}

func NewUpstream(port int) *Upstream { return &Upstream{Port: port, idle: make(chan *Stream, 4096)} }

func (u *Upstream) Load() int64 { return u.inflight.Load() }

func (u *Upstream) Call(req *Request) (resp *Response) {
	u.inflight.Add(1)
	defer u.inflight.Add(-1)
	stream, err := u.checkout()
	if err != nil {
		return Text(502)
	}
	forwarded := req.WithHeaders(req.Headers.Without(hopByHop...).With("x-forwarded-for", req.Client, "via", via))
	if err := stream.Write(forwarded.Head(), forwarded.Body); err != nil {
		stream.conn.Close()
		return Text(502)
	}
	resp, err = stream.ReadResponse()
	if err != nil {
		stream.conn.Close()
		return Text(502)
	}
	u.checkin(stream)
	resp.Headers = resp.Headers.Without(hopByHop...).With("via", via)
	return resp
}

func (u *Upstream) checkout() (*Stream, error) {
	select {
	case s := <-u.idle:
		return s, nil
	default:
		conn, err := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(u.Port))
		if err != nil {
			return nil, err
		}
		return NewStream(conn), nil
	}
}

func (u *Upstream) checkin(s *Stream) {
	select {
	case u.idle <- s:
	default:
		s.conn.Close()
	}
}

type Balancer struct{ upstreams []*Upstream }

func NewBalancer(upstreams []*Upstream) *Balancer { return &Balancer{upstreams} }

func (b *Balancer) Call(req *Request) *Response {
	best := b.upstreams[0]
	for _, u := range b.upstreams[1:] {
		if u.Load() < best.Load() {
			best = u
		}
	}
	return best.Call(req)
}
