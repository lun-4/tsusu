// CPU/RAM statistics given the PID of a process.

// This uses procfs heavily, and while procfs lives in memory and works,
// maybe it isn't the most scalable solution. We could peek into netlink, but
// that can be done later.

const std = @import("std");

pub const Stats = struct {
    cpu_usage: f64, memory_usage: u64
};

const StatsFile = struct {
    utime: u32,
    stime: u32,
    cstime: u32,
    starttime: u32,
};

// TODO port this from musl
//pub extern "c" fn sysconf(name: c_int) c_longdouble;
//pub const _SC_CLK_TCK = 2;

fn readStatsFile(path: []const u8) !StatsFile {
    var stat_file = try std.fs.cwd().openFile(path, .{ .read = true, .write = false });
    defer stat_file.close();

    // TODO check if [512]u8 is what we want, and also see if we really need
    // the entire line.
    var stat_buffer: [512]u8 = undefined;
    const read_bytes = try stat_file.read(&stat_buffer);
    const stat_line = stat_buffer[0..read_bytes];

    var line_it = std.mem.split(stat_line, " ");

    // skip pid, comm
    _ = line_it.next();
    _ = line_it.next();

    // maybe we can use state someday?
    _ = line_it.next();

    // skip ppid, pgrp, session, tty_nr, tgpid, flags, minflt, cminflt,
    // majflt, cmajflt
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();

    // get utime, stime
    // TODO error handling
    const utime = line_it.next();
    const stime = line_it.next();
    const cutime = line_it.next();
    const cstime = line_it.next();

    // skip priority, nice, num_threads, itrealvalue
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();

    const starttime = line_it.next();

    const vsize = line_it.next().?;
    const rss = line_it.next().?;
    const rsslim = line_it.next().?;

    // skip startcode, endcode, startstack, kstkesp, kstkeip, signal, blocked,
    // sigignore, sigcatch, wchan
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();

    const nswap = line_it.next().?;
    const cnswap = line_it.next().?;

    // skip exit_signal
    _ = line_it.next();

    const processor = line_it.next().?;

    // skip rt_priority, policy, delayacct_blkio_ticks
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();

    const guest_time = line_it.next().?;
    const cguest_time = line_it.next().?;

    // skip start_data, end_data, start_brk, arg_start, arg_end, env_start
    // env_end, exit_code
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();
    _ = line_it.next();

    return StatsFile{
        .utime = try std.fmt.parseInt(u32, utime.?, 10),
        .stime = try std.fmt.parseInt(u32, stime.?, 10),
        .cstime = try std.fmt.parseInt(u32, cstime.?, 10),
        .starttime = try std.fmt.parseInt(u32, starttime.?, 10),
    };
}

fn fetchUptime() !u64 {
    var uptime_file = try std.fs.cwd().openFile("/proc/uptime", .{ .read = true, .write = false });
    defer uptime_file.close();

    var uptime_buffer: [64]u8 = undefined;
    const uptime_str = try uptime_file.inStream().readUntilDelimiterOrEof(&uptime_buffer, ' ');
    const uptime_float = try std.fmt.parseFloat(f64, uptime_str.?);
    return @floatToInt(u64, uptime_float);
}

/// Fetch total memory in kilobytes of the system.
fn fetchTotalMemory() !u64 {
    var meminfo_file = try std.fs.cwd().openFile("/proc/meminfo", .{ .read = true, .write = false });
    defer meminfo_file.close();

    while (true) {
        var line_buffer: [128]u8 = undefined;
        const line_opt = try meminfo_file.inStream().readUntilDelimiterOrEof(&line_buffer, '\n');
        if (line_opt) |line| {
            var it = std.mem.tokenize(line, " ");
            const line_header = it.next().?;
            if (!std.mem.eql(u8, line_header, "MemTotal:")) {
                continue;
            }

            const mem_total_str = it.next().?;
            return try std.fmt.parseInt(u64, mem_total_str, 10);
        } else {
            // reached eof
            break;
        }
    }

    unreachable;
}

pub const StatmFile = struct {
    resident: u64,
    data_and_stack: u64,
};

fn readStatmFile(statm_path: []const u8) !StatmFile {
    var statm = try std.fs.cwd().openFile(statm_path, .{ .read = true, .write = false });
    defer statm.close();

    // TODO check if [512]u8 is what we want
    var statm_buffer: [512]u8 = undefined;
    const read_bytes = try statm.read(&statm_buffer);
    const statm_line = statm_buffer[0..read_bytes];

    var it = std.mem.split(statm_line, " ");

    _ = it.next();
    const rss_str = it.next().?;
    const resident = try std.fmt.parseInt(u64, rss_str, 10);
    _ = it.next();
    _ = it.next();
    _ = it.next();
    const data_and_stack = try std.fmt.parseInt(u64, it.next().?, 10);

    return StatmFile{
        .resident = resident,
        .data_and_stack = data_and_stack,
    };
}

pub const ProcessStats = struct {
    clock_ticks: u64,

    pub fn init() @This() {
        return .{
            // TODO: write sysconf(_SC_CLK_TCK). this is hardcoded for my machine
            .clock_ticks = 100,
        };
    }

    pub fn fetchCPUStats(self: @This(), pid: std.os.pid_t) !f64 {
        // Always refetch uptime on every cpu stat fetch.
        const uptime = try fetchUptime();

        // pids are usually 5 digit, so we can keep a lot of space for them
        var path_buffer: [64]u8 = undefined;
        const stat_path = try std.fmt.bufPrint(&path_buffer, "/proc/{}/stat", .{pid});
        const stats1 = try readStatsFile(stat_path);

        const utime = stats1.utime;
        const stime = stats1.stime;
        const cstime = stats1.cstime;
        const starttime = stats1.starttime;

        const total_time = utime + stime + cstime;
        const seconds = uptime - (starttime / self.clock_ticks);

        return @as(f64, 100) *
            ((@intToFloat(f64, total_time) / @intToFloat(f64, self.clock_ticks)) / @intToFloat(f64, seconds));
    }

    pub fn fetchMemoryUsage(self: @This(), pid: std.os.pid_t) !u64 {
        var path_buffer: [64]u8 = undefined;
        // calculate ram usage
        const statm_path = try std.fmt.bufPrint(&path_buffer, "/proc/{}/statm", .{pid});
        const statm_data = try readStatmFile(statm_path);
        return statm_data.resident + statm_data.data_and_stack;
    }

    pub fn fetchAllStats(self: @This(), pid: std.os.pid_t) !Stats {
        return Stats{
            .cpu_usage = try self.fetchCPUStats(pid),
            .memory_usage = try self.fetchMemoryUsage(pid),
        };
    }
};
