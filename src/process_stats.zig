const std = @import("std");

pub const Stats = struct {
    cpu_usage: u64
};

pub const StatsOptions = struct {};

pub const StatsFile = struct {
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

// TODO convert to Stats struct as we need to syscall to get _SC_CLK_TCK
pub fn fetchProcessStats(pid: std.os.pid_t, options: StatsOptions) !Stats {
    const clock_ticks = 100;

    var uptime_file = try std.fs.cwd().openFile("/proc/uptime", .{ .read = true, .write = false });
    defer uptime_file.close();

    var uptime_buffer: [64]u8 = undefined;
    const uptime_str = try uptime_file.inStream().readUntilDelimiterOrEof(&uptime_buffer, ' ');
    const uptime_float = try std.fmt.parseFloat(f64, uptime_str.?);
    const uptime = @floatToInt(u64, uptime_float);

    // pids are usually 5 digit, so we can keep a lot of space for them
    var path_buffer: [64]u8 = undefined;
    const stat_path = try std.fmt.bufPrint(&path_buffer, "/proc/{}/stat", .{pid});

    // Calculate CPU usage
    const stats1 = try readStatsFile(stat_path);

    const utime = stats1.utime;
    const stime = stats1.stime;
    const cstime = stats1.cstime;
    const starttime = stats1.starttime;

    const total_time = utime + stime + cstime;
    const seconds = uptime - (starttime / clock_ticks);
    const cpu_usage: f64 = @as(f64, 100) *
        ((@intToFloat(f64, total_time) / @intToFloat(f64, clock_ticks)) / @intToFloat(f64, seconds));

    return Stats{ .cpu_usage = @floatToInt(u64, std.math.floor(cpu_usage)) };
}
