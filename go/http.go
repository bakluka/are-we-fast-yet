package main

import (
	"bufio"
	"io"
	"net"
	"strconv"
	"strings"
)

var hopByHop = []string{"connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"}

var reasons = map[int]string{200: "OK", 404: "Not Found", 429: "Too Many Requests", 502: "Bad Gateway"}

type Header struct{ Name, Value string }

type Headers []Header

func (h Headers) Get(name string) string {
	for _, f := range h {
		if f.Name == name {
			return f.Value
		}
	}
	return ""
}

func (h Headers) With(pairs ...string) Headers {
	out := append(Headers(nil), h...)
	for i := 0; i < len(pairs); i += 2 {
		replaced := false
		for j := range out {
			if out[j].Name == pairs[i] {
				out[j].Value, replaced = pairs[i+1], true
			}
		}
		if !replaced {
			out = append(out, Header{pairs[i], pairs[i+1]})
		}
	}
	return out
}

func (h Headers) Without(names ...string) Headers {
	out := make(Headers, 0, len(h))
	for _, f := range h {
		drop := false
		for _, n := range names {
			drop = drop || f.Name == n
		}
		if !drop {
			out = append(out, f)
		}
	}
	return out
}

func (h Headers) ContentLength() int {
	n, _ := strconv.Atoi(h.Get("content-length"))
	return n
}

func (h Headers) appendTo(b []byte) []byte {
	for _, f := range h {
		b = append(append(append(append(b, f.Name...), ": "...), f.Value...), "\r\n"...)
	}
	return b
}

type Request struct {
	Verb, Path, Query string
	Headers           Headers
	Body              []byte
	Client            string
}

func (r *Request) Target() string {
	if r.Query == "" {
		return r.Path
	}
	return r.Path + "?" + r.Query
}

func (r *Request) Params() map[string]string {
	params := map[string]string{}
	for pair := range strings.SplitSeq(r.Query, "&") {
		if k, v, ok := strings.Cut(pair, "="); ok {
			params[k] = v
		}
	}
	return params
}

func (r *Request) KeepAlive() bool { return r.Headers.Get("connection") != "close" }

func (r *Request) Head() []byte {
	b := []byte(r.Verb + " " + r.Target() + " HTTP/1.1\r\n")
	return append(r.Headers.appendTo(b), "\r\n"...)
}

func (r Request) WithHeaders(h Headers) *Request {
	r.Headers = h
	return &r
}

type Response struct {
	Status  int
	Reason  string
	Headers Headers
	Body    []byte
}

func Text(status int) *Response {
	body := []byte(reasons[status] + "\n")
	return &Response{status, reasons[status], Headers{{"content-type", "text/plain"}, {"content-length", strconv.Itoa(len(body))}}, body}
}

func (r *Response) OK() bool { return r.Status == 200 }
func (r *Response) JSON() bool {
	return strings.HasPrefix(r.Headers.Get("content-type"), "application/json")
}

func (r Response) WithHeaders(pairs ...string) *Response {
	r.Headers = r.Headers.With(pairs...)
	return &r
}

func (r Response) WithBody(body []byte) *Response {
	r.Body = body
	r.Headers = r.Headers.With("content-length", strconv.Itoa(len(body)))
	return &r
}

func (r *Response) Head() []byte {
	b := []byte("HTTP/1.1 " + strconv.Itoa(r.Status) + " " + r.Reason + "\r\n")
	return append(r.Headers.appendTo(b), "\r\n"...)
}

type Stream struct {
	conn net.Conn
	r    *bufio.Reader
}

func NewStream(conn net.Conn) *Stream { return &Stream{conn, bufio.NewReaderSize(conn, 8<<10)} }

func (s *Stream) line() (string, error) {
	l, err := s.r.ReadString('\n')
	return strings.TrimRight(l, "\r\n"), err
}

func (s *Stream) headers() (Headers, error) {
	var h Headers
	for {
		l, err := s.line()
		if err != nil {
			return nil, err
		}
		if l == "" {
			return h, nil
		}
		name, value, _ := strings.Cut(l, ":")
		h = append(h, Header{strings.ToLower(name), strings.TrimSpace(value)})
	}
}

func (s *Stream) body(h Headers) ([]byte, error) {
	b := make([]byte, h.ContentLength())
	_, err := io.ReadFull(s.r, b)
	return b, err
}

func (s *Stream) ReadRequest(client string) (*Request, error) {
	l, err := s.line()
	if err != nil {
		return nil, err
	}
	verb, rest, _ := strings.Cut(l, " ")
	target, _, _ := strings.Cut(rest, " ")
	path, query, _ := strings.Cut(target, "?")
	h, err := s.headers()
	if err != nil {
		return nil, err
	}
	body, err := s.body(h)
	return &Request{verb, path, query, h, body, client}, err
}

func (s *Stream) ReadResponse() (*Response, error) {
	l, err := s.line()
	if err != nil {
		return nil, err
	}
	_, rest, _ := strings.Cut(l, " ")
	code, reason, _ := strings.Cut(rest, " ")
	status, _ := strconv.Atoi(code)
	h, err := s.headers()
	if err != nil {
		return nil, err
	}
	body, err := s.body(h)
	return &Response{status, reason, h, body}, err
}

func (s *Stream) Write(head, body []byte) error {
	_, err := (&net.Buffers{head, body}).WriteTo(s.conn)
	return err
}
