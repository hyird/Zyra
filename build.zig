const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });

    const zyra_mod = b.addModule("zyra", .{
        .root_source_file = b.path("src/zyra.zig"),
        .target = target,
        .optimize = optimize,
    });
    zyra_mod.addImport("zio", zio_dep.module("zio"));
    zyra_mod.addImport("httpx", httpx_dep.module("httpx"));

    // 所有示例程序：每个对应一个可执行文件和一个 `run-<名字>` 步骤，
    // 其中 basic 额外绑定到默认的 `run` 步骤。
    const Example = struct {
        name: []const u8,
        src: []const u8,
        step: []const u8,
        desc: []const u8,
    };
    const examples = [_]Example{
        .{ .name = "zyra-demo", .src = "examples/basic.zig", .step = "run", .desc = "运行最小示例服务器" },
        .{ .name = "zyra-routing", .src = "examples/routing.zig", .step = "run-routing", .desc = "运行路由示例（参数/路由组/声明式路由）" },
        .{ .name = "zyra-static", .src = "examples/static.zig", .step = "run-static", .desc = "运行带缓存的静态文件示例" },
        .{ .name = "zyra-json", .src = "examples/json_api.zig", .step = "run-json", .desc = "运行带类型 JSON API + OpenAPI 示例" },
        .{ .name = "zyra-middleware", .src = "examples/middleware.zig", .step = "run-middleware", .desc = "运行中间件/CORS/会话示例" },
        .{ .name = "zyra-logging", .src = "examples/logging.zig", .step = "run-logging", .desc = "运行异步文件日志 + 请求日志示例" },
    };
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("zyra", zyra_mod);
        exe.root_module.addImport("zio", zio_dep.module("zio"));
        exe.root_module.addImport("httpx", httpx_dep.module("httpx"));
        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        if (b.args) |args| run_exe.addArgs(args);
        const run_step = b.step(example.step, example.desc);
        run_step.dependOn(&run_exe.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zyra.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zio", zio_dep.module("zio"));
    tests.root_module.addImport("httpx", httpx_dep.module("httpx"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
