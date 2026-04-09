package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"time"
	"unsafe"

	"github.com/google/cel-go/cel"
)

type probeCase struct {
	name   string
	source string
}

var probeCases = []probeCase{
	{
		name:   "scalar-mix",
		source: "((int('42') + 8) * 3) > 100 && bool('True') && string(123u) == '123'",
	},
	{
		name:   "macro-pipeline",
		source: "[1, 2, 3, 4, 5, 6].filter(x, x % 2 == 0).map(x, x * x)",
	},
	{
		name:   "quoted-field",
		source: "{'content-type': 'application/json', 'content-length': 145}['content-type'] == 'application/json'",
	},
}

func findProbeCase(name string) (probeCase, bool) {
	for _, c := range probeCases {
		if c.name == name {
			return c, true
		}
	}
	return probeCase{}, false
}

func main() {
	if len(os.Args) != 3 {
		fmt.Println("usage: go run million_probe.go <case-name> <count>")
		os.Exit(2)
	}

	c, ok := findProbeCase(os.Args[1])
	if !ok {
		fmt.Printf("unknown case: %s\n", os.Args[1])
		os.Exit(2)
	}

	count, err := strconv.Atoi(os.Args[2])
	if err != nil || count <= 0 {
		fmt.Printf("invalid count: %s\n", os.Args[2])
		os.Exit(2)
	}

	env, err := cel.NewEnv()
	if err != nil {
		panic(err)
	}

	programs := make([]cel.Program, 0, count)
	var before runtime.MemStats
	runtime.GC()
	runtime.GC()
	runtime.ReadMemStats(&before)

	start := time.Now()
	for i := 0; i < count; i++ {
		ast, iss := env.Compile(c.source)
		if iss.Err() != nil {
			panic(iss.Err())
		}
		prg, err := env.Program(ast)
		if err != nil {
			panic(err)
		}
		programs = append(programs, prg)
	}
	compileNS := time.Since(start).Nanoseconds()

	runtime.GC()
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)

	heapAllocDelta := int64(after.HeapAlloc) - int64(before.HeapAlloc)
	heapInuseDelta := int64(after.HeapInuse) - int64(before.HeapInuse)
	heapObjectsDelta := int64(after.HeapObjects) - int64(before.HeapObjects)

	fmt.Printf("case %s\n", c.name)
	fmt.Printf("count %d\n", count)
	fmt.Printf("compile_ns_total %d\n", compileNS)
	fmt.Printf("compile_ns_per_expr %d\n", compileNS/int64(count))
	fmt.Printf("heap_alloc_delta %d\n", heapAllocDelta)
	fmt.Printf("heap_alloc_per_expr %d\n", heapAllocDelta/int64(count))
	fmt.Printf("heap_inuse_delta %d\n", heapInuseDelta)
	fmt.Printf("heap_inuse_per_expr %d\n", heapInuseDelta/int64(count))
	fmt.Printf("heap_objects_delta %d\n", heapObjectsDelta)
	var zero cel.Program
	fmt.Printf("program_iface_holder_bytes %d\n", int64(cap(programs))*int64(unsafe.Sizeof(zero)))

	runtime.KeepAlive(programs)
	runtime.KeepAlive(env)
}
