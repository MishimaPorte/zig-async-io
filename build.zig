const std = @import("std");

const BuildError = error{
    BadBuildConfig,
};

fn setParam(key: []const u8, value: []const u8, opts: *std.Build.Step.Options) !void {
    if (std.mem.eql(u8, key, "max_channels_per_connection")) {
        const val = try std.fmt.parseInt(usize, value, 0);
        opts.addOption(usize, "max_channels_per_connection", val);
    } else if (std.mem.eql(u8, key, "max_frame_size")) {
        const val = try std.fmt.parseInt(usize, value, 0);
        opts.addOption(usize, "max_frame_size", val);
    } else if (std.mem.eql(u8, key, "heartbeat_rate")) {
        const val = try std.fmt.parseInt(usize, value, 0);
        opts.addOption(usize, "heartbeat_rate", val);
    } else if (std.mem.eql(u8, key, "debug_mode")) {
        opts.addOption(bool, "debug_mode", std.mem.eql(u8, value, "true"));
    } else if (std.mem.eql(u8, key, "workerthreadcount")) {
        const val = try std.fmt.parseInt(usize, value, 0);
        opts.addOption(usize, "workerthreadcount", val);
    } else @panic("bad argument in bad config");
}

fn parseBuildConfigIntoOpts(opts: *std.Build.Step.Options, allocator: std.mem.Allocator) !void {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, "build.conf", 100000);
    var iter = std.mem.splitScalar(u8, file_bytes, '\n');
    while (true) {
        const param_line = iter.next() orelse unreachable;
        if (std.mem.eql(u8, param_line, "")) return;

        var field = std.mem.splitScalar(u8, param_line, '=');
        const name = field.first();
        const val = field.next() orelse return BuildError.BadBuildConfig;
        try setParam(name, val, opts);
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "asuramq",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("__Build_Config", opts: {
        const opts = b.addOptions();
        try parseBuildConfigIntoOpts(opts, b.allocator);
        break :opts opts;
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
