const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const zyra_mod = b.addModule("zyra", .{
        .root_source_file = b.path("src/zyra.zig"),
        .target = target,
        .optimize = optimize,
    });
    zyra_mod.addImport("zio", zio_dep.module("zio"));

    const demo = b.addExecutable(.{
        .name = "zyra-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("zyra", zyra_mod);
    demo.root_module.addImport("zio", zio_dep.module("zio"));
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| run_demo.addArgs(args);
    const run_step = b.step("run", "Run the basic Zyra demo server");
    run_step.dependOn(&run_demo.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zyra.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zio", zio_dep.module("zio"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
