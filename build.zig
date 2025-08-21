const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pjbot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const options = b.addOptions();
    exe.root_module.addOptions("build_options", options);

    const kiesel = b.dependency("kiesel", .{
        .target = target,
        .optimize = optimize,
        .@"enable-intl" = false,
        .@"enable-temporal" = false,
        .@"version-string" = @as([]const u8, "0.1.0"),
    });
    exe.root_module.addImport("kiesel", kiesel.module("kiesel"));
    exe.root_module.addImport("ptk", kiesel.builder.dependency("parser_toolkit", .{}).module("parser-toolkit"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
