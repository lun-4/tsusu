// Port of zRc to my local zig version.
// Original by suirad, https://github.com/suirad/zRc

const std = @import("std");
const assert = std.debug.assert;

pub fn Rc(comptime T: type) type {
    return struct {
        const refSize = u16;
        refs: std.atomic.Int(refSize),
        ptr: ?*T,
        allocator: *std.mem.Allocator,

        pub const Self = @This();

        pub fn init(alloc: *std.mem.Allocator) !Self {
            var data = try alloc.create(T);
            return Self{
                .refs = std.atomic.Int(refSize).init(1),
                .ptr = data,
                .allocator = alloc,
            };
        }

        pub fn incRef(self: *Self) *Self {
            if (self.ptr != null) {
                _ = self.refs.incr();
            }
            return self;
        }

        pub fn decRef(self: *Self) void {
            if (self.ptr != null) {
                const val = self.refs.decr();
                if (val == 1) {
                    self.deinit();
                }
            }
        }

        pub fn deinit(self: *Self) void {
            self.refs.set(0);

            // pointer may want to do its own stuff
            if (self.ptr) |ptr| {
                // TODO only call if @hasDecl(T, "deinit") returns true
                ptr.deinit();
                self.allocator.destroy(self.ptr);
            }

            self.ptr = null;
        }

        pub fn countRef(self: *Self) refSize {
            return self.refs.get();
        }
    };
}

test "Rc all functions" {
    var all = std.heap.page_allocator;

    var rcint = try Rc(i32).init(all);
    assert(rcint.ptr != null);

    // reference adjustments
    _ = rcint.incRef();
    assert(rcint.countRef() == 2);
    rcint.decRef();

    // assignment
    rcint.ptr.?.* = 0;
    assert(rcint.ptr.?.* == 0);

    // auto free
    rcint.decRef();
    assert(rcint.ptr == null);
}

test "Rc auto-free" {
    var all = std.heap.page_allocator;

    var rcint = try Rc(u32).init(all);
    assert(rcint.ptr != null);

    rcint.ptr.?.* = 1;

    assert(freefn(&rcint) == 1);
    assert(rcint.ptr == null);
}

fn freefn(data: *Rc(u32)) u32 {
    defer data.decRef();
    return data.ptr.?.*;
}

test "Threaded Rc" {
    var all = std.heap.page_allocator;

    var context = try Rc(Ctx).init(all);
    context.ptr.?.val = 5;

    var threads: [10]*std.Thread = undefined;
    for (threads) |*t| {
        t.* = try std.Thread.spawn(context.incRef(), worker);
    }

    context.decRef();

    for (threads) |t|
        t.wait();

    assert(context.ptr == null);
}

const Ctx = struct {
    val: u32,
};

fn worker(ctx: *Rc(Ctx)) void {
    defer ctx.decRef();
    if (ctx.ptr.?.val != 5) {
        @panic("Nope");
    }
}

// This is an extension from the original zRc.
/// Heap-aware Rc. Will destroy itself when the counter hits 1.
pub fn HeapRc(comptime T: type) type {
    return struct {
        const refSize = u16;
        refs: std.atomic.Int(refSize),
        ptr: ?*T,
        allocator: *std.mem.Allocator,

        pub const Self = @This();

        pub fn init(alloc: *std.mem.Allocator) !*Self {
            var self = try alloc.create(Self);
            var data = try alloc.create(T);
            self.* = Self{
                .refs = std.atomic.Int(refSize).init(1),
                .ptr = data,
                .allocator = alloc,
            };

            return self;
        }

        pub fn incRef(self: *Self) *Self {
            if (self.ptr != null) {
                const val = self.refs.incr();
                std.debug.warn("incref'd, val={}\n", .{val});
            }
            return self;
        }

        pub fn decRef(self: *Self) void {
            if (self.ptr != null) {
                const val = self.refs.decr();
                std.debug.warn("decref'd, val={}\n", .{val});
                if (val == 1) {
                    self.deinit();
                }
            }
        }

        pub fn deinit(self: *Self) void {
            self.refs.set(0);

            // pointer may want to do its own stuff
            if (self.ptr) |ptr| {
                // TODO only call if @hasDecl(T, "deinit") returns true
                ptr.deinit();
                self.allocator.destroy(self.ptr);
            }

            self.ptr = null;
            self.allocator.destroy(self);
        }

        pub fn countRef(self: *Self) refSize {
            return self.refs.get();
        }
    };
}
