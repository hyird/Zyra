# AGENTS.md

Zyra：基于 `std.Io` + `zio` 运行时构建的 Zig 0.16 Web 框架。单一模块
（`zyra`）加上一个示例可执行文件。完整的公共 API 列表见 `README.md`
（它是权威的功能参考——请保持同步）。

## 命令

- `zig build run` — 在 3000 端口运行示例服务器（`examples/basic.zig`）
- `zig build test` — 运行所有单元测试
- `zig build -Doptimize=ReleaseFast` — 发布构建（CI 基准测试使用）

测试通过 `src/zyra.zig` 的 `test {}` 块聚合，该块会导入每个模块。
**新增的 `src/core/*.zig` 模块的测试不会运行，除非你在该块中添加
`_ = newmod;`**（并在其上方加一个 `pub const` 导出）。`build.zig` 中没有
配置按文件运行的测试器。

要求 Zig 严格为 0.16.0（见 `build.zig.zon` 中的 `minimum_zig_version`）。

## 架构

- `src/zyra.zig` — 单一公共模块；重新导出所有内容。所有新的公共
  类型/命名空间都必须在此处导出。
- `src/core/` — 实现代码，每个关注点一个文件（`server`、`router`、
  `middleware`、`http`、`session`、`websocket`、`ws_hub`、`cors`、`log`、
  `openapi`、`schema`、`typed_route`、`multipart`、`static_files`、
  `header_map`、`memory_pool`）。
- `src/io/zio_backend.zig` — 唯一直接接触 `zio` 的地方。它的职责是
  生成一个 `std.Io` 实现。**所有其他代码必须使用 `std.Io`
  （`std.Io.net`/`Reader`/`Writer`），绝不能直接调用 zio API。**

关键约定：
- 并发原语使用 `std.Io.*`：`std.Io.Mutex`、`std.Io.Clock`、
  `std.Io.Group`、`io.random`。不要在请求/运行时路径中使用
  `std.Thread`/`std.time` 的等价物。
- 许多运行时方法接收一个显式的 `io: std.Io` 参数（sessions、ws_hub、
  logging 时钟）。应将其逐层传递，而不是捕获全局变量。
- 请求作用域的内存分配通过 `MemoryPool` 使用 arena；每个请求的分配
  在请求结束时释放。
- 架构有意镜像 “Hical”（一个 C++ 框架）以进行基准对比——扩展时请
  保留模块边界和 API 形状。

## 故意未实现

SSL/TLS、数据库模块，以及 WebSocket 的 `permessage-deflate`。在完全
实现之前，不要将它们桩化或暴露为公共 API。

## CI / 基准测试

`.github/workflows/benchmark.yml` 会构建 Zyra 和一个 C++ Hical 服务器，
并比较 `wrk` 的吞吐量。基准测试输出（`benchmarks/*.json`）已被 gitignore。
`benchmark/hical/` 存放用于对比的 C++ 服务器（CMake/Ninja），不属于
Zig 构建的一部分。
