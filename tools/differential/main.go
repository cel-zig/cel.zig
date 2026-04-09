package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/google/cel-go/cel"
)

type Input struct {
	Expr string `json:"expr"`
}

type Output struct {
	Kind  string  `json:"kind"`
	Bool  *bool   `json:"bool,omitempty"`
	Int   *int64  `json:"int,omitempty"`
	Uint  *uint64 `json:"uint,omitempty"`
	Error *string `json:"error,omitempty"`
}

func main() {
	var in Input
	if len(os.Args) > 1 {
		in.Expr = os.Args[1]
	} else {
		inBytes, err := io.ReadAll(os.Stdin)
		if err != nil {
			fail(err)
		}
		if err := json.Unmarshal(inBytes, &in); err != nil {
			fail(err)
		}
	}

	env, err := cel.NewEnv()
	if err != nil {
		fail(err)
	}

	ast, iss := env.Compile(in.Expr)
	if iss.Err() != nil {
		msg := iss.Err().Error()
		emit(Output{Kind: "error", Error: &msg})
		return
	}

	prg, err := env.Program(ast)
	if err != nil {
		fail(err)
	}

	out, _, err := prg.Eval(map[string]any{})
	if err != nil {
		msg := err.Error()
		emit(Output{Kind: "error", Error: &msg})
		return
	}

	switch v := out.Value().(type) {
	case bool:
		emit(Output{Kind: "bool", Bool: &v})
	case int64:
		emit(Output{Kind: "int", Int: &v})
	case uint64:
		emit(Output{Kind: "uint", Uint: &v})
	default:
		msg := fmt.Sprintf("unsupported differential result type %T", v)
		emit(Output{Kind: "error", Error: &msg})
	}
}

func emit(out Output) {
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
