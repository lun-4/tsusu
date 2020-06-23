const std = @import("std");

pub fn main() !void {
    var i: usize = 0;
    while (true) {
        std.debug.warn("i = {}\n", .{i});
        std.time.sleep(1 * std.time.ns_per_s);
    }
}
