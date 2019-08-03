const std = @import("std");

pub fn main() void {
    std.debug.warn("daemon\n");
    std.time.sleep(6 * std.time.second);
}
