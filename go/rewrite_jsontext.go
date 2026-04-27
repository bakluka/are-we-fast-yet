//go:build goexperiment.jsonv2

package main

import (
	"bytes"
	"encoding/json/jsontext"
	"slices"
)

func (rw *Rewrite) transform(body []byte, fields []string) ([]byte, error) {
	dec := jsontext.NewDecoder(bytes.NewReader(body))
	var out bytes.Buffer
	enc := jsontext.NewEncoder(&out)
	var err error
	if dec.PeekKind() == '[' {
		err = rw.array(dec, enc, fields)
	} else {
		err = rw.value(dec, enc, nil)
	}
	return bytes.TrimSpace(out.Bytes()), err
}

func (rw *Rewrite) array(dec *jsontext.Decoder, enc *jsontext.Encoder, fields []string) error {
	if _, err := dec.ReadToken(); err != nil {
		return err
	}
	enc.WriteToken(jsontext.BeginArray)
	for dec.PeekKind() != ']' {
		if err := rw.value(dec, enc, fields); err != nil {
			return err
		}
	}
	dec.ReadToken()
	return enc.WriteToken(jsontext.EndArray)
}

func (rw *Rewrite) value(dec *jsontext.Decoder, enc *jsontext.Encoder, fields []string) error {
	switch dec.PeekKind() {
	case '{':
		dec.ReadToken()
		enc.WriteToken(jsontext.BeginObject)
		for dec.PeekKind() != '}' {
			name, err := dec.ReadToken()
			if err != nil {
				return err
			}
			key := name.String()
			if fields != nil && !slices.Contains(fields, key) {
				if err := dec.SkipValue(); err != nil {
					return err
				}
				continue
			}
			enc.WriteToken(jsontext.String(camelize(key)))
			if slices.Contains(rw.Redact, key) && dec.PeekKind() == '"' {
				v, err := dec.ReadToken()
				if err != nil {
					return err
				}
				enc.WriteToken(jsontext.String(mask(v.String())))
				continue
			}
			if err := rw.value(dec, enc, nil); err != nil {
				return err
			}
		}
		dec.ReadToken()
		return enc.WriteToken(jsontext.EndObject)
	case '[':
		return rw.array(dec, enc, nil)
	default:
		v, err := dec.ReadValue()
		if err != nil {
			return err
		}
		return enc.WriteValue(v)
	}
}
