const std = @import("std");
const cel = @import("cel");

const NsTimer = struct {
    start_ns: u64,

    pub fn start() NsTimer {
        return .{ .start_ns = std.c.mach_absolute_time() };
    }

    pub fn read(self: NsTimer) u64 {
        return std.c.mach_absolute_time() - self.start_ns;
    }
};

const PosixWriter = struct {
    pub const Error = error{};

    pub fn writeAll(_: PosixWriter, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.c.write(1, bytes[off..].ptr, bytes.len - off);
            if (rc < 0) return;
            off += @intCast(rc);
        }
    }

    pub fn print(self: PosixWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [4096]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
        return self.writeAll(output);
    }
};

const PerfCase = struct {
    name: []const u8,
    source: []const u8,
    iterations: usize = 10_000,
    setup: ?*const fn (allocator: std.mem.Allocator, environment: *cel.Env, activation: *cel.Activation) anyerror!void = null,
};

const Stats = struct {
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    current_in_use: usize = 0,
    peak_in_use: usize = 0,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    stats: Stats = .{},

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn reset(self: *CountingAllocator) void {
        self.stats = .{};
    }

    fn recordAlloc(self: *CountingAllocator, len: usize) void {
        self.stats.alloc_calls += 1;
        self.stats.bytes_allocated += len;
        self.stats.current_in_use += len;
        self.stats.peak_in_use = @max(self.stats.peak_in_use, self.stats.current_in_use);
    }

    fn recordFree(self: *CountingAllocator, len: usize) void {
        self.stats.free_calls += 1;
        self.stats.bytes_freed += len;
        self.stats.current_in_use -= len;
    }

    fn adjustCurrent(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            const extra = new_len - old_len;
            self.stats.bytes_allocated += extra;
            self.stats.current_in_use += extra;
            self.stats.peak_in_use = @max(self.stats.peak_in_use, self.stats.current_in_use);
        } else {
            const freed = old_len - new_len;
            self.stats.bytes_freed += freed;
            self.stats.current_in_use -= freed;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.recordAlloc(len);
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            self.stats.resize_calls += 1;
            self.adjustCurrent(memory.len, new_len);
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.stats.remap_calls += 1;
        self.adjustCurrent(memory.len, new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.recordFree(memory.len);
    }
};

const perf_cases = [_]PerfCase{
    .{
        .name = "scalar-mix",
        .source = "((int('42') + 8) * 3) > 100 && bool('True') && string(123u) == '123'",
        .iterations = 20_000,
    },
    .{
        .name = "macro-pipeline",
        .source = "[1, 2, 3, 4, 5, 6].filter(x, x % 2 == 0).map(x, x * x)",
        .iterations = 10_000,
    },
    .{
        .name = "quoted-field",
        .source = "{'content-type': 'application/json', 'content-length': 145}.`content-type` == 'application/json'",
        .iterations = 25_000,
    },
};

pub fn main() !void {
    const case_filter: ?[]const u8 = if (std.c.getenv("CEL_PERF_CASE")) |ptr| std.mem.sliceTo(ptr, 0) else null;
    const borrowed_eval = if (std.c.getenv("CEL_PERF_BORROWED")) |ptr| !std.mem.eql(u8, std.mem.sliceTo(ptr, 0), "0") else false;
    const repeat_count: usize = if (std.c.getenv("CEL_PERF_REPEAT")) |ptr| std.fmt.parseInt(usize, std.mem.sliceTo(ptr, 0), 10) catch 1 else 1;

    const stdout = PosixWriter{};
    stdout.writeAll("cel.zig perf harness\n") catch {};
    stdout.writeAll(
        "case parse_ns check_ns compile_ns eval_ns_per_iter parse_allocs check_allocs compile_allocs eval_allocs parse_peak check_peak compile_peak eval_peak\n",
    ) catch {};

    var repeat_index: usize = 0;
    while (repeat_index < repeat_count) : (repeat_index += 1) {
        for (perf_cases) |case| {
            if (case_filter) |filter| {
                if (!std.mem.eql(u8, filter, case.name)) continue;
            }
            try runCase(stdout, case, borrowed_eval);
        }
    }

    // --- Cost calibration ---
    try runCostCalibration(stdout);

    // --- Env/overlay benchmarks ---
    try runEnvBenchmarks(stdout);

    // --- Memory tracking ---
    try runMemoryBenchmarks(stdout);
}

fn runCase(writer: anytype, case: PerfCase, borrowed_eval: bool) !void {
    var environment = try cel.Env.initDefault(std.heap.page_allocator);
    defer environment.deinit();

    var activation = cel.Activation.init(std.heap.page_allocator);
    defer activation.deinit();

    if (case.setup) |setup| {
        try setup(std.heap.page_allocator, &environment, &activation);
    }

    var parse_counter = CountingAllocator.init(std.heap.page_allocator);
    var timer = NsTimer.start();
    var parsed_only = try cel.parseExpr(parse_counter.allocator(), case.source);
    const parse_ns = timer.read();
    parsed_only.deinit();

    const parsed_for_check = try cel.parseExpr(std.heap.page_allocator, case.source);
    var check_counter = CountingAllocator.init(std.heap.page_allocator);
    timer = NsTimer.start();
    var checked_program = try cel.compileParsed(check_counter.allocator(), &environment, parsed_for_check);
    const check_ns = timer.read();
    checked_program.deinit();

    var compile_counter = CountingAllocator.init(std.heap.page_allocator);
    timer = NsTimer.start();
    var program = try cel.compile(compile_counter.allocator(), &environment, case.source);
    const compile_ns = timer.read();

    var eval_counter = CountingAllocator.init(std.heap.page_allocator);
    {
        var scratch = cel.EvalScratch.init(eval_counter.allocator());
        defer scratch.deinit();
        timer = NsTimer.start();
        var i: usize = 0;
        while (i < case.iterations) : (i += 1) {
            if (borrowed_eval) {
                const result = try cel.evaluateBorrowedWithScratch(&scratch, &program, &activation);
                std.mem.doNotOptimizeAway(result);
            } else {
                var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
                std.mem.doNotOptimizeAway(result);
                result.deinit(eval_counter.allocator());
            }
        }
    }
    const total_eval_ns = timer.read();

    program.deinit();

    if (parse_counter.stats.current_in_use != 0) {
        return error.ParseAllocatorLeak;
    }
    if (check_counter.stats.current_in_use != 0) {
        return error.CheckAllocatorLeak;
    }
    if (compile_counter.stats.current_in_use != 0) {
        return error.CompileAllocatorLeak;
    }
    if (eval_counter.stats.current_in_use != 0) {
        return error.EvalAllocatorLeak;
    }

    try writer.print(
        "{s} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            case.name,
            parse_ns,
            check_ns,
            compile_ns,
            @divTrunc(total_eval_ns, case.iterations),
            parse_counter.stats.alloc_calls,
            check_counter.stats.alloc_calls,
            compile_counter.stats.alloc_calls,
            eval_counter.stats.alloc_calls,
            parse_counter.stats.peak_in_use,
            check_counter.stats.peak_in_use,
            compile_counter.stats.peak_in_use,
            eval_counter.stats.peak_in_use,
        },
    );
}

// =========================================================================
// Cost calibration: measure actual runtime cost of different CEL operations
// and compare against the static cost model.
// =========================================================================

const CostCase = struct {
    name: []const u8,
    source: []const u8,
    iterations: usize = 50_000,
    needs_vars: bool = false,
};

const cost_cases = [_]CostCase{
    .{ .name = "literal", .source = "42" },
    .{ .name = "ident", .source = "x", .needs_vars = true },
    .{ .name = "binary_lit", .source = "1 + 2" },
    .{ .name = "binary_var", .source = "x + y", .needs_vars = true },
    .{ .name = "list_create_3", .source = "[1, 2, 3]" },
    .{ .name = "map_create_2", .source = "{'a': 1, 'b': 2}" },
    .{ .name = "fn_call", .source = "size('hello')" },
    .{ .name = "regex_match", .source = "'hello'.matches('h.*o')" },
    .{ .name = "comprehension_100", .source = "[1,2,3,4,5,6,7,8,9,10].map(x, x * x)", .iterations = 10_000 },
};

fn runCostCalibration(writer: anytype) !void {
    return runCostCalibrationCases(writer, &cost_cases);
}

fn runCostCalibrationCases(writer: anytype, cases: []const CostCase) !void {
    writer.writeAll("\n=== cost calibration ===\n") catch {};
    writer.writeAll("operation ns_per_eval static_min static_max ratio\n") catch {};

    var environment = try cel.Env.initDefault(std.heap.page_allocator);
    defer environment.deinit();

    const b = environment.types.builtins;
    try environment.addVarTyped("x", b.int_type);
    try environment.addVarTyped("y", b.int_type);

    var activation = cel.Activation.init(std.heap.page_allocator);
    defer activation.deinit();
    try activation.put("x", .{ .int = 10 });
    try activation.put("y", .{ .int = 20 });

    // First, measure baseline (literal) to compute ratios
    var baseline_ns: u64 = 1; // fallback

    for (cases, 0..) |case, case_idx| {
        var program = try cel.compile(std.heap.page_allocator, &environment, case.source);
        defer program.deinit();

        const estimate = cel.estimateCost(&program);

        var eval_counter = CountingAllocator.init(std.heap.page_allocator);
        {
            var scratch = cel.EvalScratch.init(eval_counter.allocator());
            defer scratch.deinit();
            const timer = NsTimer.start();
            var i: usize = 0;
            while (i < case.iterations) : (i += 1) {
                var result = try cel.evaluateWithScratch(&scratch, &program, &activation);
                std.mem.doNotOptimizeAway(result);
                result.deinit(eval_counter.allocator());
            }
            const total_ns = timer.read();
            const ns_per_eval = @divTrunc(total_ns, case.iterations);

            if (case_idx == 0) {
                baseline_ns = @max(ns_per_eval, 1);
            }

            // ratio = ns_per_eval / baseline_ns, printed as X.Xx
            // Use fixed-point: multiply by 10 then format
            const ratio_x10 = @divTrunc(ns_per_eval * 10, baseline_ns);
            const ratio_whole = @divTrunc(ratio_x10, 10);
            const ratio_frac = ratio_x10 % 10;

            try writer.print("{s} {d} {d} {d} {d}.{d}x\n", .{
                case.name,
                ns_per_eval,
                estimate.min,
                estimate.max,
                ratio_whole,
                ratio_frac,
            });
        }
    }
}

// =========================================================================
// Env/overlay benchmarks
// =========================================================================

fn runEnvBenchmarks(writer: anytype) !void {
    return runEnvBenchmarksIterations(writer, 1_000);
}

fn runEnvBenchmarksIterations(writer: anytype, iterations: usize) !void {
    writer.writeAll("\n=== env benchmarks ===\n") catch {};
    writer.writeAll("operation ns allocs peak_bytes\n") catch {};

    // Env.init time
    {
        var counter = CountingAllocator.init(std.heap.page_allocator);
        const timer = NsTimer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var environment = try cel.Env.initDefault(counter.allocator());
            environment.deinit();
        }
        const total_ns = timer.read();
        try writer.print("env_init {d} {d} {d}\n", .{
            @divTrunc(total_ns, iterations),
            @divTrunc(counter.stats.alloc_calls, iterations),
            counter.stats.peak_in_use,
        });
    }

    // Env.extend time (overlay creation)
    {
        var base_env = try cel.Env.initDefault(std.heap.page_allocator);
        defer base_env.deinit();

        var counter = CountingAllocator.init(std.heap.page_allocator);
        const timer = NsTimer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var child = try base_env.extend(counter.allocator());
            child.deinit();
        }
        const total_ns = timer.read();
        try writer.print("env_extend {d} {d} {d}\n", .{
            @divTrunc(total_ns, iterations),
            @divTrunc(counter.stats.alloc_calls, iterations),
            counter.stats.peak_in_use,
        });
    }

    // TypeProvider shared vs separate
    {
        // Shared: multiple envs referencing one TypeProvider
        var shared_provider = try cel.TypeProvider.init(std.heap.page_allocator);
        defer shared_provider.deinit();

        var counter_shared = CountingAllocator.init(std.heap.page_allocator);
        const timer_shared = NsTimer.start();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var env_shared = cel.Env.initWithProvider(counter_shared.allocator(), &shared_provider);
            env_shared.deinit();
        }
        const shared_ns = timer_shared.read();
        try writer.print("type_provider_shared {d} {d} {d}\n", .{
            @divTrunc(shared_ns, iterations),
            @divTrunc(counter_shared.stats.alloc_calls, iterations),
            counter_shared.stats.peak_in_use,
        });

        // Separate: each env owns its own TypeProvider
        var counter_separate = CountingAllocator.init(std.heap.page_allocator);
        const timer_separate = NsTimer.start();
        i = 0;
        while (i < iterations) : (i += 1) {
            var env_sep = try cel.Env.initDefault(counter_separate.allocator());
            env_sep.deinit();
        }
        const separate_ns = timer_separate.read();
        try writer.print("type_provider_separate {d} {d} {d}\n", .{
            @divTrunc(separate_ns, iterations),
            @divTrunc(counter_separate.stats.alloc_calls, iterations),
            counter_separate.stats.peak_in_use,
        });
    }
}

// =========================================================================
// Memory tracking: measure retained memory for core objects
// =========================================================================

fn runMemoryBenchmarks(writer: anytype) !void {
    writer.writeAll("\n=== memory retained ===\n") catch {};
    writer.writeAll("object bytes allocs\n") catch {};

    // Memory retained by a compiled Program
    {
        var env_alloc = try cel.Env.initDefault(std.heap.page_allocator);
        defer env_alloc.deinit();
        const b = env_alloc.types.builtins;
        try env_alloc.addVarTyped("x", b.int_type);
        try env_alloc.addVarTyped("y", b.int_type);

        var counter = CountingAllocator.init(std.heap.page_allocator);
        var program = try cel.compile(counter.allocator(), &env_alloc, "x + y > 10 && [1,2,3].exists(e, e > 1)");
        const retained = counter.stats.current_in_use;
        const allocs = counter.stats.alloc_calls;
        program.deinit();

        try writer.print("program {d} {d}\n", .{ retained, allocs });
    }

    // Memory retained by an Env
    {
        var counter = CountingAllocator.init(std.heap.page_allocator);
        var environment = try cel.Env.initDefault(counter.allocator());
        const b = environment.types.builtins;
        try environment.addVarTyped("x", b.int_type);
        try environment.addVarTyped("y", b.int_type);
        try environment.addVarTyped("name", b.string_type);
        const retained = counter.stats.current_in_use;
        const allocs = counter.stats.alloc_calls;
        environment.deinit();

        try writer.print("env {d} {d}\n", .{ retained, allocs });
    }

    // Memory retained by a TypeProvider
    {
        var counter = CountingAllocator.init(std.heap.page_allocator);
        const provider = try cel.TypeProvider.init(counter.allocator());
        const retained = counter.stats.current_in_use;
        const allocs = counter.stats.alloc_calls;
        _ = provider;
        // Note: we intentionally leak here to measure retained; provider.deinit()
        // would zero out current_in_use. The page_allocator backing doesn't care.

        try writer.print("type_provider {d} {d}\n", .{ retained, allocs });
    }
}

const TestWriter = struct {
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *TestWriter, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    fn writeAll(self: *TestWriter, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.buffer.appendSlice(std.testing.allocator, bytes);
    }

    fn print(self: *TestWriter, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        var buf: [4096]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        try self.writeAll(out);
    }

    fn contains(self: *const TestWriter, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.buffer.items, needle) != null;
    }
};

test "CountingAllocator tracks alloc and reset" {
    var counter = CountingAllocator.init(std.testing.allocator);
    const alloc = counter.allocator();

    var bytes = try alloc.alloc(u8, 16);
    bytes = try alloc.realloc(bytes, 32);
    alloc.free(bytes);

    try std.testing.expect(counter.stats.alloc_calls >= 1);
    try std.testing.expect(counter.stats.bytes_allocated >= 16);
    try std.testing.expectEqual(@as(usize, 0), counter.stats.current_in_use);

    counter.reset();
    try std.testing.expectEqual(Stats{}, counter.stats);
}

test "runCase smoke" {
    var writer = TestWriter{};
    defer writer.deinit(std.testing.allocator);

    try runCase(&writer, .{
        .name = "smoke",
        .source = "1 + 1 == 2",
        .iterations = 1,
    }, false);

    try std.testing.expect(writer.contains("smoke"));
}

test "runCostCalibrationCases smoke" {
    var writer = TestWriter{};
    defer writer.deinit(std.testing.allocator);

    const cases = [_]CostCase{
        .{ .name = "literal", .source = "42", .iterations = 1 },
        .{ .name = "ident", .source = "x", .iterations = 1, .needs_vars = true },
    };
    try runCostCalibrationCases(&writer, &cases);
    try std.testing.expect(writer.contains("cost calibration"));
    try std.testing.expect(writer.contains("literal"));
}

test "runEnvBenchmarksIterations smoke" {
    var writer = TestWriter{};
    defer writer.deinit(std.testing.allocator);

    try runEnvBenchmarksIterations(&writer, 1);
    try std.testing.expect(writer.contains("env benchmarks"));
    try std.testing.expect(writer.contains("env_init"));
}

test "runMemoryBenchmarks smoke" {
    var writer = TestWriter{};
    defer writer.deinit(std.testing.allocator);

    try runMemoryBenchmarks(&writer);
    try std.testing.expect(writer.contains("memory retained"));
    try std.testing.expect(writer.contains("program"));
}
