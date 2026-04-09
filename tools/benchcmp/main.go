package main

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/google/cel-go/cel"
)

type benchCase struct {
	name       string
	source     string
	goSource   string
	iterations int
}

var cases = []benchCase{
	{
		name:       "scalar-mix",
		source:     "((int('42') + 8) * 3) > 100 && bool('True') && string(123u) == '123'",
		iterations: 20000,
	},
	{
		name:       "macro-pipeline",
		source:     "[1, 2, 3, 4, 5, 6].filter(x, x % 2 == 0).map(x, x * x)",
		iterations: 10000,
	},
	{
		name:       "quoted-field",
		source:     "{'content-type': 'application/json', 'content-length': 145}.`content-type` == 'application/json'",
		goSource:   "{'content-type': 'application/json', 'content-length': 145}['content-type'] == 'application/json'",
		iterations: 25000,
	},
}

func main() {
	fmt.Println("cel-go comparison harness")
	fmt.Println("case compile_ns_per_iter eval_ns_per_iter compile_allocs_per_run eval_allocs_per_run")
	for _, c := range cases {
		if err := runCase(c); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}

func runCase(c benchCase) error {
	source := c.source
	if c.goSource != "" {
		source = c.goSource
	}

	env, err := cel.NewEnv()
	if err != nil {
		return fmt.Errorf("%s: create env: %w", c.name, err)
	}

	const compileRuns = 1000
	compileStart := time.Now()
	for i := 0; i < compileRuns; i++ {
		ast, iss := env.Compile(source)
		if iss.Err() != nil {
			return fmt.Errorf("%s: compile: %w", c.name, iss.Err())
		}
		if _, err := env.Program(ast); err != nil {
			return fmt.Errorf("%s: program: %w", c.name, err)
		}
	}
	compilePerRun := time.Since(compileStart).Nanoseconds() / int64(compileRuns)

	ast, iss := env.Compile(source)
	if iss.Err() != nil {
		return fmt.Errorf("%s: compile for eval: %w", c.name, iss.Err())
	}
	prg, err := env.Program(ast)
	if err != nil {
		return fmt.Errorf("%s: program for eval: %w", c.name, err)
	}

	evalStart := time.Now()
	for i := 0; i < c.iterations; i++ {
		if _, _, err := prg.Eval(map[string]any{}); err != nil {
			return fmt.Errorf("%s: eval: %w", c.name, err)
		}
	}
	evalPerIter := time.Since(evalStart).Nanoseconds() / int64(c.iterations)

	compileAllocs := testing.AllocsPerRun(100, func() {
		ast, iss := env.Compile(source)
		if iss.Err() != nil {
			panic(iss.Err())
		}
		if _, err := env.Program(ast); err != nil {
			panic(err)
		}
	})

	evalAllocs := testing.AllocsPerRun(100, func() {
		if _, _, err := prg.Eval(map[string]any{}); err != nil {
			panic(err)
		}
	})

	fmt.Printf(
		"%s %d %d %.2f %.2f\n",
		c.name,
		compilePerRun,
		evalPerIter,
		compileAllocs,
		evalAllocs,
	)
	return nil
}
