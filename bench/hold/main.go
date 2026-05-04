package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

func main() {
	n := flag.Int("n", 1000, "connections to open and hold")
	addr := flag.String("addr", "127.0.0.1:8080", "proxy address")
	path := flag.String("path", "/raw/x", "request sent once on every connection")
	flag.Parse()
	conns := make([]net.Conn, *n)
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256)
	for i := range conns {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			c, err := net.Dial("tcp", *addr)
			if err != nil {
				log.Fatal(err)
			}
			fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: x\r\n\r\n", *path)
			r := bufio.NewReader(c)
			res, err := http.ReadResponse(r, nil)
			if err != nil {
				log.Fatal(err)
			}
			io.Copy(io.Discard, res.Body)
			conns[i] = c
		}()
	}
	wg.Wait()
	fmt.Println("holding", *n)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
}
