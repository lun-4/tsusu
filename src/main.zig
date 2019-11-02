const std = @import("std");

const daemon = @import("daemon.zig");

const fs = std.fs;
const os = std.os;
const mem = std.mem;

fn connectUnixSocket(path: []const u8) !fs.File {
    const opt_non_block = if (std.io.mode == .evented) os.SOCK_NONBLOCK else 0;
    const sockfd = try os.socket(
        os.AF_UNIX,
        os.SOCK_STREAM | os.SOCK_CLOEXEC | opt_non_block,
        0,
    );
    errdefer os.close(sockfd);

    var sock_addr = os.sockaddr_un{
        .family = os.AF_UNIX,
        .path = undefined,
    };

    if (path.len > sock_addr.path.len) return error.NameTooLong;
    mem.copy(u8, &sock_addr.path, path);

    const size = @intCast(u32, @sizeOf(os.sockaddr_un) - sock_addr.path.len + path.len);
    try os.connect(sockfd, @ptrCast(*os.sockaddr, &sock_addr), size);

    return fs.File.openHandle(sockfd);
}

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

    pub fn checkDaemon(self: *Context) anyerror!std.fs.File {
        if (self.tries >= 3) return error.SpawnFail;
        self.tries += 1;

        return connectUnixSocket(
            "/home/luna/.local/share/tsusu.sock",
        ) catch |err| {
            try spawnDaemon();

            // assuming spawning doesn't take more than 500ms.
            std.time.sleep(500 * std.time.millisecond);
            return try self.checkDaemon();
        };
    }
};

fn spawnDaemon() !void {
    var pid = try std.os.fork();

    if (pid < 0) {
        return error.ForkFail;
    }

    if (pid > 0) {
        return;
    }

    // TODO setsid
    // TODO umask

    try daemon.main();
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
    defer sock.close();

    std.debug.warn("sock fd from client connected: {}\n", sock.handle);

    //const mode = try (args_it.next(allocator) orelse "list");
}
