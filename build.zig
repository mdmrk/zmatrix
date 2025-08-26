const std = @import("std");

fn getVersion(b: *std.Build) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "date", "+%Y%m%d" },
    });
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    const date = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const git_result = try std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
    });
    defer b.allocator.free(git_result.stdout);
    defer b.allocator.free(git_result.stderr);

    const zon = @import("build.zig.zon");
    const version = zon.version;

    const commit = std.mem.trim(u8, git_result.stdout, &std.ascii.whitespace);
    return b.fmt("{s}-{s}-{s}", .{ version, date, commit });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = getVersion(b) catch |err| {
        std.log.err("Failed to get version info: {}", .{err});
        return;
    };
    const exe = b.addExecutable(.{
        .name = "zmatrix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zmatrix.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseFast,
        }),
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("zmatrix_options", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
