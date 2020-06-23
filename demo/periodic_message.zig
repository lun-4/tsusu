const std = @import("std");

pub fn main() !void {
    var i: usize = 0;
    var stdout = std.io.getStdOut();
    while (true) {
        if (i % 2 == 0)
            std.debug.warn("i = {}\n", .{i})
        else
            stdout.outStream().print("i = {}\n", .{i}) catch {};

        i += 1;
        std.time.sleep(1 * std.time.ns_per_s);
    }
}
