pub const check = @import("checker/check.zig");
pub const bindings = @import("checker/bindings.zig");
pub const check_macro = @import("checker/check_macro.zig");
pub const validate = @import("checker/validate.zig");

pub const Error = check.Error;

test {
    _ = check;
    _ = check_macro;
    _ = validate;
}
