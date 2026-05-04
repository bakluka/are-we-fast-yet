package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type user struct {
	ID        int               `json:"id"`
	Name      string            `json:"name"`
	Email     string            `json:"email"`
	Avatar    string            `json:"avatar"`
	Bio       string            `json:"bio"`
	CreatedAt string            `json:"created_at"`
	Tags      []string          `json:"tags"`
	Address   map[string]string `json:"address"`
	Score     float64           `json:"score"`
	Active    bool              `json:"active"`
}

func document(n int) []byte {
	users := make([]user, n)
	for i := range users {
		users[i] = user{
			ID:        i,
			Name:      fmt.Sprintf("User %d", i),
			Email:     fmt.Sprintf("user%d@example.com", i),
			Avatar:    fmt.Sprintf("https://cdn.example.com/a/%d.png", i),
			Bio:       strings.Repeat("x", 120),
			CreatedAt: "2026-10-03T10:00:00Z",
			Tags:      []string{"ruby", "go", "ractor"},
			Address:   map[string]string{"street": fmt.Sprintf("%d Main St", i), "city": "Zagreb", "zip": "10000"},
			Score:     float64(i) * 1.5,
			Active:    i%2 == 0,
		}
	}
	b, _ := json.Marshal(users)
	return b
}

func response(contentType string, body []byte) []byte {
	head := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n", contentType, len(body))
	return append([]byte(head), body...)
}

var (
	apiResponse []byte
	rawResponse []byte
	filler      = bytes.Repeat([]byte("r"), 1<<20)
	served      atomic.Int64
)

func param(target []byte, name string) int {
	i := bytes.Index(target, []byte(name+"="))
	if i < 0 {
		return 0
	}
	v := target[i+len(name)+1:]
	if j := bytes.IndexAny(v, "& "); j >= 0 {
		v = v[:j]
	}
	n, _ := strconv.Atoi(string(v))
	return n
}

func serve(c net.Conn) {
	defer c.Close()
	r := bufio.NewReaderSize(c, 16<<10)
	w := bufio.NewWriterSize(c, 32<<10)
	for {
		line, err := r.ReadSlice('\n')
		if err != nil {
			return
		}
		parts := bytes.SplitN(line, []byte(" "), 3)
		if len(parts) < 3 {
			return
		}
		target := append([]byte(nil), parts[1]...)
		length, closing := 0, false
		for {
			h, err := r.ReadSlice('\n')
			if err != nil {
				return
			}
			if len(h) <= 2 {
				break
			}
			if len(h) > 15 && bytes.EqualFold(h[:15], []byte("content-length:")) {
				length, _ = strconv.Atoi(string(bytes.TrimSpace(h[15:])))
			}
			if len(h) > 11 && bytes.EqualFold(h[:11], []byte("connection:")) {
				closing = bytes.EqualFold(bytes.TrimSpace(h[11:]), []byte("close"))
			}
		}
		if length > 0 {
			if _, err := io.CopyN(io.Discard, r, int64(length)); err != nil {
				return
			}
		}
		if bytes.Equal(target, []byte("/__count")) {
			w.Write(response("text/plain", strconv.AppendInt(nil, served.Load(), 10)))
		} else {
			served.Add(1)
			if ms := param(target, "delay"); ms > 0 {
				time.Sleep(time.Duration(ms) * time.Millisecond)
			}
			switch kb := min(param(target, "kb"), 1024); {
			case bytes.HasPrefix(target, []byte("/api")):
				w.Write(apiResponse)
			case kb > 0:
				w.Write(response("text/plain", filler[:kb<<10]))
			default:
				w.Write(rawResponse)
			}
		}
		if r.Buffered() == 0 || closing {
			if w.Flush() != nil || closing {
				return
			}
		}
	}
}

func main() {
	ports := flag.String("ports", "9001,9002", "comma separated ports to listen on")
	items := flag.Int("items", 32, "objects in the /api document")
	raw := flag.Int("raw", 1024, "bytes in the /raw body")
	flag.Parse()
	apiResponse = response("application/json", document(*items))
	rawResponse = response("text/plain", bytes.Repeat([]byte("r"), *raw))
	log.Printf("api %d bytes, raw %d bytes", len(apiResponse), len(rawResponse))
	for _, p := range strings.Split(*ports, ",") {
		ln, err := net.Listen("tcp", "127.0.0.1:"+p)
		if err != nil {
			log.Fatal(err)
		}
		go func() {
			for {
				c, err := ln.Accept()
				if err != nil {
					log.Fatal(err)
				}
				go serve(c)
			}
		}()
	}
	select {}
}
