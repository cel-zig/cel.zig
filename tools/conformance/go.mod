module celzig/conformance

go 1.23.0

require (
	cel.dev/expr v0.0.0
	google.golang.org/protobuf v1.36.10
)

replace cel.dev/expr => ../../.cache/cel-spec
