const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cel_mod = b.addModule("cel", .{
        .root_source_file = b.path("src/cel.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cel",
        .root_module = cel_mod,
    });
    b.installArtifact(lib);

    // -----------------------------------------------------------------------
    // Executables
    // -----------------------------------------------------------------------

    const perf_exe = b.addExecutable(.{
        .name = "cel-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/perf.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    perf_exe.root_module.addImport("cel", cel_mod);
    b.installArtifact(perf_exe);

    const example_exe = b.addExecutable(.{
        .name = "cel-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    example_exe.root_module.addImport("cel", cel_mod);

    const typed_example_exe = b.addExecutable(.{
        .name = "cel-example-typed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/typed/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    typed_example_exe.root_module.addImport("cel", cel_mod);

    const protobuf_example_exe = b.addExecutable(.{
        .name = "cel-example-protobuf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protobuf/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    protobuf_example_exe.root_module.addImport("cel", cel_mod);

    const custom_lib_example_exe = b.addExecutable(.{
        .name = "cel-example-custom-library",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/custom_library/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    custom_lib_example_exe.root_module.addImport("cel", cel_mod);

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    // Core library tests (run via root module)
    const unit_tests = b.addTest(.{
        .root_module = cel_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Conformance suite (needs Go tooling to extract test data)
    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    conformance_tests.root_module.addImport("cel", cel_mod);

    const extract_descriptors = b.addSystemCommand(&.{ "go", "run", "." });
    extract_descriptors.setCwd(b.path("tools/conformance"));
    extract_descriptors.addArgs(&.{ "--descriptors-output", "../../.cache/conformance/descriptors.json" });

    const conformance_suites = [_][]const u8{
        "basic",        "bindings_ext",   "encoders_ext", "conversions",
        "fields",       "fp_math",        "integer_math", "lists",
        "logic",        "macros",         "macros2",      "namespace",
        "plumbing",     "string",         "string_ext",   "math_ext",
        "timestamps",   "wrappers",       "dynamic",      "type_deduction",
        "optionals",    "comparisons",    "parse",        "network_ext",
        "enums",        "block_ext",      "proto2",       "proto3",
        "proto2_ext",
    };
    const run_conformance = b.addRunArtifact(conformance_tests);
    run_conformance.step.dependOn(&extract_descriptors.step);
    for (conformance_suites) |suite_name| {
        const extract_suite = b.addSystemCommand(&.{ "go", "run", "." });
        extract_suite.setCwd(b.path("tools/conformance"));
        const input = b.fmt("../../.cache/cel-spec/tests/simple/testdata/{s}.textproto", .{suite_name});
        const output = b.fmt("../../.cache/conformance/{s}.json", .{suite_name});
        extract_suite.addArgs(&.{ "--input", input, "--output", output });
        run_conformance.step.dependOn(&extract_suite.step);
    }

    // Fuzz tests
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    fuzz_tests.root_module.addImport("cel", cel_mod);

    // Perf regression tests
    const perf_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/perf_regression.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    perf_regression_tests.root_module.addImport("cel", cel_mod);

    // Differential tests
    const differential_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    differential_tests.root_module.addImport("cel", cel_mod);

    // -----------------------------------------------------------------------
    // Build steps
    // -----------------------------------------------------------------------

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    test_step.dependOn(&b.addRunArtifact(perf_regression_tests).step);

    const conformance_step = b.step("test-conformance", "Run conformance suite");
    conformance_step.dependOn(&run_conformance.step);

    const differential_step = b.step("test-differential", "Run cel-go differential tests");
    differential_step.dependOn(&b.addRunArtifact(differential_tests).step);

    const perf_step = b.step("perf", "Run perf harness");
    perf_step.dependOn(&b.addRunArtifact(perf_exe).step);

    const example_step = b.step("example", "Run simple usage example");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    const typed_example_step = b.step("example-typed", "Run typed usage example");
    typed_example_step.dependOn(&b.addRunArtifact(typed_example_exe).step);

    const protobuf_example_step = b.step("example-protobuf", "Run protobuf usage example");
    protobuf_example_step.dependOn(&b.addRunArtifact(protobuf_example_exe).step);

    const custom_lib_example_step = b.step("example-custom-library", "Run custom library example");
    custom_lib_example_step.dependOn(&b.addRunArtifact(custom_lib_example_exe).step);
}
