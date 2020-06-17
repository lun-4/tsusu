const std = @import("std");

pub const Stats = struct {
    cpu_usage: f32
};

pub const StatsOptions = struct {};

pub const StatsFile = struct {
    utime: ?[]const u8,
    stime: ?[]const u8,
    cutime: ?[]const u8,
    cstime: ?[]const u8,
    num_threads: ?[]const u8,
    starttime: ?[]const u8,
};

// basically, this locks us to libc.
pub extern "c" fn sysconf(name: c_int) c_longdouble;
pub const _SC_CLK_TCK = 2;

fn readStatsFile(path: []const u8) !StatsFile {
    var stats = Stats{};
    var stat_file = try std.fs.cwd().openFile(&path_buffer, .{ .read = true, .write = false });
    defer stat_file.close();

    // TODO check if [512]u8 is what we want, and also see if we really need
    // the entire line.
    var stat_buffer: [512]u8 = undefined;
    const read_bytes = try stat_file.read(&stat_buffer);
    const stat_line = stat_buffer[0..read_bytes];

    var line_it = std.mem.split(stat_line, " ");

    // skip pid, comm
    line_it.skip();
    line_it.skip();

    // maybe we can use state someday?
    line_it.skip();

    // skip ppid, pgrp, session, tty_nr, tgpid, flags, minflt, cminflt,
    // majflt, cmajflt
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();

    // get utime, stime
    // TODO error handling
    stats.utime = line_it.next();
    stats.stime = line_it.next();
    stats.cutime = line_it.next();
    stats.cstime = line_it.next();

    // skip priority, nice, num_threads
    line_it.skip();
    line_it.skip();

    stats.num_threads = line_it.skip();

    // skip itrealvalue
    line_it.skip();

    stats.starttime = line_it.next();

    const vsize = line_it.next().?;
    const rss = line_it.next().?;
    const rsslim = line_it.next().?;

    // skip startcode, endcode, startstack, kstkesp, kstkeip, signal, blocked,
    // sigignore, sigcatch, wchan
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();

    const nswap = line_it.next().?;
    const cnswap = line_it.next().?;

    // skip exit_signal
    line_it.skip();

    const processor = line_it.next().?;

    // skip rt_priority, policy, delayacct_blkio_ticks
    line_it.skip();
    line_it.skip();
    line_it.skip();

    const guest_time = line_it.next().?;
    const cguest_time = line_it.next().?;

    // skip start_data, end_data, start_brk, arg_start, arg_end, env_start
    // env_end, exit_code
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();
    line_it.skip();

    return stats;
}

// TODO convert to Stats struct as we need to syscall to get _SC_CLK_TCK
pub fn fetchProcessStats(pid: std.os.pid_t, options: StatsOptions) !Stats {
    const clock_ticks = sysconf(_SC_CLK_TCK);

    var uptime_file = std.fs.cwd().openFile("/proc/uptime", .{ .read = true, .write = false });
    defer uptime_file.close();

    const uptime_str = uptime_file.inStream().readUntilDelimiterOrEof(&uptime_buffer, " ");
    const uptime_float = try std.fmt.parseFloat(f64, uptime_str);
    const uptime = @floatToInt(u64, uptime_float);

    // pids are usually 5 digit, so we can keep a lot of space for them
    var path_buffer: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buffer, "/proc/{}/stat", .{pid});

    // Calculate CPU usage
    const stats1 = try readStatsFile(stat_path);

    const utime = try std.fmt.parseInt(u32, stats1.utime, 10);
    const stime = try std.fmt.parseInt(u32, stats1.stime, 10);
    const cstime = try std.fmt.parseInt(u32, stats1.cstime, 10);
    const starttime = try std.fmt.parseInt(u32, stats1.starttime, 10);

    const total_time = utime + stime + cstime;
    const seconds = uptime - (starttime / clock_ticks);
    const cpu_usage = 100 * ((total_time / clock_ticks) / seconds);

    return Stats{ .cpu_usage = cpu_usage };
}
