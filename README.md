# cel.zig

A Zig implementation of the [Common Expression Language](https://cel.dev/) (CEL).

**2,454/2,454 conformance tests passing · Full cel-go parity · 5-21x faster · Zero hidden allocations**

![Zig 0.16](https://img.shields.io/badge/zig-0.16--dev-f7a41d?logo=zig)
![Conformance](https://img.shields.io/badge/conformance-2%2C454%2F2%2C454-brightgreen)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

## Why CEL? Why Zig?

[CEL](https://cel.dev/) is a lightweight expression language designed for security, policy, and configuration. It's used across the cloud-native ecosystem: Kubernetes (validation rules, admission policies, CRD defaulting), Istio (authorization policies), Tekton (pipeline conditions), Google Cloud IAM (policy bindings), Firebase (security rules), Envoy (RBAC filters), and many others. Implementations exist in [Go](https://github.com/google/cel-go), [C++](https://github.com/google/cel-cpp), [Rust](https://github.com/clarkmcc/cel-rust), [Java](https://github.com/google/cel-java), and [Python](https://github.com/cloud-custodian/cel-python).

This implementation brings CEL to Zig with explicit allocator control, zero hidden heap allocations, and predictable performance. Compiled programs are immutable and safe for concurrent evaluation. Scalar expressions evaluate with a single heap allocation vs cel-go's 3-5, and compilation is 5-21x faster.

## Features

- Parse, type-check, compile, and evaluate as separate steps
- Explicit allocator control with zero hidden allocations
- Immutable compiled programs safe for concurrent evaluation
- Reusable `EvalScratch` for allocation-free steady-state evaluation
- Cost budget and deadline enforcement
- Partial evaluation with residualization and expression unparsing
- Constant folding optimizer
- Exhaustive evaluation mode with decorator hooks
- Comptime struct context for zero-boilerplate evaluation
- Custom type adapters with field access via vtable

### Extension Libraries

Beyond the CEL standard library:

| Library | Functions |
|---------|-----------|
| **strings** | charAt, indexOf, lastIndexOf, lowerAscii, upperAscii, replace, split, substring, trim, join, reverse, quote |
| **math** | abs, ceil, floor, round, sign, sqrt, trunc, greatest, least, isNaN, isInf, isFinite, bitAnd/Or/Xor/Not, bitShiftLeft/Right |
| **lists** | sort, sortBy, flatten, slice, distinct, reverse, range, zip, first, last, sum, min, max, indexOf, lastIndexOf, isSorted |
| **sets** | contains, equivalent, intersects |
| **regex** | find, findAll, replace, replaceN, extract |
| **json** | marshal, unmarshal |
| **maps** | merge |
| **format** | named and positional format strings |
| **hash** | fnv64a, md5, sha256 |
| **network** | IP/CIDR parsing, containment |
| **semver** | parse, compare, validate |
| **url** | parse, component access |
| **jsonpatch** | RFC 6902 patch application |
| **encoders** | base64 encode/decode |
| **protos** | message construction, field presence, well-known types, proto2 extensions |
| **comprehensions** | two-variable transform macros (transformList, transformMap, transformMapEntry) |

## Quick Start

```sh
zig fetch --save git+https://github.com/cel-zig/cel.zig
```

```zig
const cel = @import("cel");

var env = try cel.Env.init(allocator, &.{
    cel.variable("method", cel.StringType),
    cel.variable("path", cel.StringType),
});
defer env.deinit();

var program = try env.compile("method == 'POST' && path.contains('/api/')");
defer program.deinit();

var result = try program.evaluate(allocator, .{
    .method = "POST",
    .path = "/api/v1/pods",
}, .{});
defer result.deinit(allocator);
// result.bool == true
```

## API

### Environment

```zig
var env = try cel.Env.init(allocator, &.{
    // Message types
    cel.message("Request", &.{
        cel.field("method", cel.StringType),
        cel.field("path", cel.StringType),
        cel.field("headers", cel.MapType(cel.StringType, cel.StringType)),
    }),

    // Variables
    cel.variable("request", cel.ObjectType("Request")),
    cel.variable("items", cel.ListType(cel.StringType)),
    cel.variable("config", cel.MapType(cel.StringType, cel.IntType)),

    // Libraries
    cel.withLibrary(cel.strings),
    cel.withLibrary(cel.math),
});
defer env.deinit();

var program = try env.compile(source);
defer program.deinit();
```

### Evaluation

```zig
// Comptime struct context
var result = try program.evaluate(allocator, .{ .x = @as(i64, 10) }, .{});

// Runtime activation
var activation = cel.Activation.init(allocator);
try activation.put("x", .{ .int = 10 });
var result = try program.evaluate(allocator, &activation, .{});

// With cost budget / deadline
var result = try program.evaluate(allocator, &activation, .{
    .budget = 1000,
    .deadline_ns = 5_000_000_000,
});
```

### Scratch Evaluation

Reuse internal buffers across evaluations in hot paths:

```zig
var scratch = cel.EvalScratch.init(allocator);
defer scratch.deinit();

var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
defer result.deinit(allocator);

// Zero-copy variant (result valid until next eval call)
const borrowed = try cel.evaluateBorrowedWithScratch(&scratch, &program, &activation);
```

### Custom Type Provider

For types discovered at runtime (OpenAPI schemas, protobuf descriptors, CRDs):

```zig
var tp = try cel.TypeProvider.init(allocator);
_ = try tp.defineMessage("Point", &.{
    .{ .name = "x", .type = cel.IntType },
    .{ .name = "y", .type = cel.IntType },
});

var env = try cel.Env.init(allocator, &.{
    cel.customTypes(tp),
    cel.variable("origin", cel.ObjectType("Point")),
});
defer env.deinit();
```

### Partial Evaluation

```zig
var activation = cel.Activation.init(allocator);
defer activation.deinit();
try activation.addUnknownVariable("x");

var partial = try cel.eval.residual.partialEvaluate(allocator, &program, &activation);
defer partial.deinit();

// partial.residual is the simplified CEL string: "x > 0 && x < 100"
```

### Expression Unparsing

```zig
const source = try cel.unparseProgram(allocator, &program);
defer allocator.free(source);
```

### Accessing Internals

All internal modules are accessible through namespaced imports:

```zig
const cel = @import("cel");

const ast = cel.parse.ast;       // AST types and walker
const lexer = cel.parse.lexer;   // tokenizer
const partial = cel.eval.partial; // partial evaluation primitives
const protobuf = cel.library.protobuf;
const TypeRef = cel.types.TypeRef;
```

## Protobuf

Descriptor-driven protobuf support:

- Message types and field selection with proto2/proto3 presence semantics
- Well-known types: `Any`, `Struct`, `Value`, `ListValue`, `Timestamp`, `Duration`
- Wrapper types: `BoolValue`, `Int32Value`, `Int64Value`, `UInt32Value`, `UInt64Value`, `FloatValue`, `DoubleValue`, `StringValue`, `BytesValue`
- Proto2 extensions via `proto.hasExt` and `proto.getExt`

## Benchmarks

Compared against cel-go v0.27 on the same expressions and inputs (Apple M-series, single core):

| Expression | Compile (ns) | Eval (ns/iter) | Compile speedup | Eval speedup |
|------------|-------------:|---------------:|----------------:|-------------:|
| scalar-mix | 8,259 | 42 | **6.6x** | **4.9x** |
| macro-pipeline | 3,556 | 191 | **21x** | **10.9x** |
| quoted-field | 2,274 | 39 | **16x** | **6.1x** |

5-21x faster compilation. 5-11x faster evaluation. Scalar expressions evaluate with 1 heap allocation vs cel-go's 3-5.

Compile is measured once per expression. Eval is the median of 10,000 iterations using `EvalScratch` for buffer reuse.

```sh
zig build perf    # run benchmarks locally
```

## Building

Requires Zig 0.16 and libc.

```sh
zig build              # build library and perf binary
zig test src/cel.zig -lc  # run unit tests
zig build test         # run all tests including fuzz and perf regression
zig build test-conformance  # run upstream CEL conformance suite (requires Go)
zig build perf         # run benchmarks
```

### Examples

```sh
zig build example                 # basic usage
zig build example-typed           # comptime struct context
zig build example-protobuf        # protobuf messages
zig build example-custom-library  # building your own extension library
```

## Project Structure

```
src/
  cel.zig        # public API
  parse.zig      # parse/    index (lexer, parser, AST, unparser)
  checker.zig    # checker/  index (type checker, macro expansion)
  compiler.zig   # compiler/ index (compilation, optimization)
  env.zig        # env/      index (environment, types, values)
  eval.zig       # eval/     index (evaluator, activation, cost, residual)
  library.zig    # library/  index (stdlib + all extensions)
  types.zig      # type system re-exports (TypeRef, Value, TypeProvider)
  util.zig       # util/     index (diagnostics, formatting)
test/
  conformance.zig      # upstream CEL spec conformance (2,454 cases)
  differential.zig     # cel-go differential tests
  fuzz.zig             # lexer/parser/evaluator fuzz harness
  perf.zig             # benchmarks with allocation tracking
  perf_regression.zig  # performance regression tests
```

## License

See [LICENSE](./LICENSE).

