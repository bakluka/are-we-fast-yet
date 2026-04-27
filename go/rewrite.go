package main

import (
	"strings"
)

type Rewrite struct{ Redact []string }

func (rw *Rewrite) Call(req *Request, next Handler) *Response {
	resp := next(req)
	if !resp.JSON() {
		return resp
	}
	var fields []string
	if f := req.Params()["fields"]; f != "" {
		fields = strings.Split(f, ",")
	}
	body, err := rw.transform(resp.Body, fields)
	if err != nil {
		return Text(502)
	}
	return resp.WithBody(body)
}

func camelize(key string) string {
	parts := strings.Split(key, "_")
	for i := 1; i < len(parts); i++ {
		if parts[i] != "" {
			parts[i] = strings.ToUpper(parts[i][:1]) + strings.ToLower(parts[i][1:])
		}
	}
	return strings.Join(parts, "")
}

func mask(email string) string {
	name, domain, _ := strings.Cut(email, "@")
	if name == "" {
		return email
	}
	return name[:1] + "***@" + domain
}
