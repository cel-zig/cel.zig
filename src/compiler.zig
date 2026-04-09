pub const compile = @import("compiler/compile.zig");
pub const optimize = @import("compiler/optimize.zig");
pub const prepare = @import("compiler/prepare.zig");
pub const program = @import("compiler/program.zig");
pub const unchecked = @import("compiler/unchecked.zig");

pub const Program = program.Program;

test {
    _ = compile;
    _ = optimize;
    _ = prepare;
    _ = program;
    _ = unchecked;
}
