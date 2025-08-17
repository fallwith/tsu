const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const strip = b.option(bool, "strip", "Strip debug symbols from executable") orelse false;
    const enable_lto = b.option(bool, "lto", "Enable link-time optimization") orelse false;

    const exe = b.addExecutable(.{
        .name = "tsu",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = false,
    });
    
    if (enable_lto) {
        exe.want_lto = true;
    }

    b.installArtifact(exe);
    
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}