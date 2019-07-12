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

        //const sockfd = try std.os.socket(std.os.AF_UNIX);
        const sockfd = try std.os.socket(std.os.AF_UNIX, std.os.SOCK_STREAM, 0);

        var addr = std.os.sockaddr{
            .un = std.os.sockaddr_un{
                .family = std.os.AF_UNIX,
                .path = [_]u8{0} ** 108,
            },
        };

        std.mem.copy(u8, &addr.un.path, sockpath);

        std.os.connect(
            sockfd,
            &addr,
            @intCast(u32, std.mem.len(u8, &sockpath) + 2),
        ) catch |err| {
            try spawnDaemon(sockpath);

            // assuming spawning doesn't take more than 500ms.
            std.time.sleep(500 * std.time.millisecond);
            return try self.checkDaemon();
        };

        return sockfd;
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
    defer std.os.close(sock);

    std.debug.warn("SOCK FD: {}\n", sock);

    //const mode = try (args_it.next(allocator) orelse "list");
}
