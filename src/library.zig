pub const stdlib = @import("library/stdlib.zig");
pub const stdlib_ext = @import("library/stdlib_ext.zig");
pub const protobuf = @import("library/protobuf.zig");
pub const cel_regex = @import("library/cel_regex.zig");
pub const cel_time = @import("library/cel_time.zig");
pub const list_ext = @import("library/list_ext.zig");
pub const comprehensions_ext = @import("library/comprehensions_ext.zig");
pub const network_ext = @import("library/network_ext.zig");
pub const hash_ext = @import("library/hash_ext.zig");
pub const json_ext = @import("library/json_ext.zig");
pub const maps_ext = @import("library/maps_ext.zig");
pub const format_ext = @import("library/format_ext.zig");
pub const jsonpatch_ext = @import("library/jsonpatch_ext.zig");
pub const semver_ext = @import("library/semver_ext.zig");
pub const url_ext = @import("library/url_ext.zig");
pub const set_ext = @import("library/set_ext.zig");

test {
    _ = stdlib;
    _ = stdlib_ext;
    _ = protobuf;
    _ = cel_regex;
    _ = cel_time;
    _ = list_ext;
    _ = comprehensions_ext;
    _ = network_ext;
    _ = hash_ext;
    _ = json_ext;
    _ = maps_ext;
    _ = format_ext;
    _ = jsonpatch_ext;
    _ = semver_ext;
    _ = url_ext;
    _ = set_ext;
}
