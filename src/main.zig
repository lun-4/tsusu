const std = @import("std");

const daemon = @import("daemon.zig");

pub const Context = struct {
    allocator: *std.mem.Allocator,
    args_it: std.process.ArgIterator,
    tries: usize = 0,

    pub fn init(allocator: *std.mem.Allocator, args_it: std.process.ArgIterator) Context {
        return Context{
            .allocator = allocator,
            .args_it = args_it,
        };
    }

    pub fn checkDaemon(self: *Context) anyerror!i32 {
        if (self.tries >= 3) return error.SpawnFail;
        self.tries += 1;

        // we check if the tsusu daemon is available under the unix socket
        // on ~/.local/share/tsusu.sock, if not, we
        const home = std.os.getenv("HOME").?;
        var sockpath: [108]u8 = undefined;
        std.mem.secureZero(u8, &sockpath);

        var path = try std.fs.path.resolve(self.allocator, [_][]const u8{
            home,
            ".local/share/tsusu.sock",
        });

        std.mem.copy(u8, &sockpath, path);

        std.debug.warn("sockpath: {}\n", path);
        return std.os.open(path, std.os.O_RDONLY, 0) catch |err| {
            if (err == error.FileNotFound) {
                try spawnDaemon(sockpath);
            } else {
                return err;
            }

            // wait 500ms until doing it again
            std.time.sleep(500 * std.time.millisecond);
            return try self.checkDaemon();
        };
    }
};

fn spawnDaemon(sockpath: [108]u8) !void {
    var pid = try std.os.fork();

    if (pid < 0) {
        return error.ForkFail;
    }

    if (pid > 0) {
        return;
    }

    // TODO setsid
    // TODO umask

    try daemon.main(sockpath);
}

pub fn main() anyerror!void {
    // every time we start, we check if we have a daemon running.
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = std.process.args();
    _ = args_it.skip();

    var ctx = Context.init(allocator, args_it);
    const sock = try ctx.checkDaemon();

    //const mode = try (args_it.next(allocator) orelse "list");
}
