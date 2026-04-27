package main

import "strings"

type Handler func(*Request) *Response

type Layer interface {
	Call(req *Request, next Handler) *Response
}

type Route struct {
	Prefix    string
	Upstreams []*Upstream
	Layers    []Layer
}

func (r *Route) Match(req *Request) bool { return strings.HasPrefix(req.Path, r.Prefix) }

type Endpoint struct {
	route    *Route
	balancer *Balancer
}

func (e *Endpoint) call(req *Request, layers []Layer) *Response {
	if len(layers) == 0 {
		return e.balancer.Call(req)
	}
	return layers[0].Call(req, func(r *Request) *Response { return e.call(r, layers[1:]) })
}

type App struct {
	endpoints []*Endpoint
	metrics   *Metrics
}

func NewApp(routes []*Route, metrics *Metrics) *App {
	app := &App{metrics: metrics}
	for _, r := range routes {
		app.endpoints = append(app.endpoints, &Endpoint{r, NewBalancer(r.Upstreams)})
	}
	return app
}

func (a *App) Call(req *Request) *Response {
	return a.metrics.Call(req, a.route)
}

func (a *App) route(req *Request) *Response {
	for _, e := range a.endpoints {
		if e.route.Match(req) {
			return e.call(req, e.route.Layers)
		}
	}
	return Text(404)
}
