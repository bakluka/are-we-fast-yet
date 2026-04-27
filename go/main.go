package main

import (
	"log"
	"net"
	"time"
)

func upstreams(ports ...int) []*Upstream {
	out := make([]*Upstream, len(ports))
	for i, p := range ports {
		out[i] = NewUpstream(p)
	}
	return out
}

func main() {
	routes := []*Route{
		{Prefix: "/api", Upstreams: upstreams(9001, 9002), Layers: []Layer{
			&RateLimit{PerSecond: 1_000_000, Plans: map[string]int64{"free": 1_000}},
			&Rewrite{Redact: []string{"email"}},
		}},
		{Prefix: "/static", Upstreams: upstreams(9003, 9004), Layers: []Layer{&Cache{TTL: time.Second}}},
		{Prefix: "/", Upstreams: upstreams(9003, 9004)},
	}
	app := NewApp(routes, &Metrics{})
	ln, err := net.Listen("tcp", ":8080")
	if err != nil {
		log.Fatal(err)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go serve(app, conn)
	}
}

func serve(app *App, conn net.Conn) {
	defer conn.Close()
	client, _, _ := net.SplitHostPort(conn.RemoteAddr().String())
	stream := NewStream(conn)
	for {
		req, err := stream.ReadRequest(client)
		if err != nil {
			return
		}
		resp := app.Call(req)
		if stream.Write(resp.Head(), resp.Body) != nil || !req.KeepAlive() {
			return
		}
	}
}
