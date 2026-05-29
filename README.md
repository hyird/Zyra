# Zyra

Zyra 是一个基于 `std.Io` + `zio` 构建的 Zig 0.16 Web 框架骨架，其模块
边界有意与 Hical 保持一致：

- `HttpServer` 顶层门面
- 支持静态路由和 `{param}` 路由的 `Router`
- `MiddlewarePipeline`（中间件管线）
- `HttpRequest` / `HttpResponse`
- 基于 `std.http.Server` 的 HTTP/1.1 解析与响应写入
- 通过 `MemoryPool` 实现的请求作用域 arena 分配
- 使用 `zio` 作为运行时/网络后端，而协议代码使用 `std.Io`
- 受 Hical 启发的 Web API 辅助函数，涵盖路由、路由组、请求、响应、
  查询/表单/cookie 解析以及服务器限制

运行：

```bash
zig build run
```

已实现的、面向 Web 的 Hical 风格 API 表面包括：

- 路由方法：`get`、`post`、`put`、`patch`、`delete`/`del`、`head`、`options`
- `Router.group()` / `RouteGroup` 前缀路由，支持组级中间件
  （`use`/`useBeforeAfter`）；组的 before/after 钩子以洋葱式仅围绕该组
  的路由运行，并被嵌套组继承
- 请求辅助函数：`header`、`query`、`queryParam`、`queryParams`、`cookie`、
  `cookies`、`formParam`、`formParams`、`body`、`contentType`、`readJson`、
  `jsonResponse`，路径参数（字符串用 `param`；带类型的用 `paramInt`、
  `paramFloat`、`paramBool`），以及字符串属性
- 响应辅助函数：`statusCode`、`setStatus`、`header`、`setHeader`、
  `setBody`、`bodyText`、`jsonValue`、`setJsonBody`、`badRequest`、`redirect`、
  `setCookie`，以及 416 范围错误工厂
- 服务器限制设置器：请求体/请求头大小和最大连接数
- 中间件：通过 `MiddlewarePipeline` 实现的同步洋葱模型
  （`use`/`useOnion`/`useBeforeAfter`），包含 `MiddlewareHandler`、
  `BeforeHandler`、`AfterHandler` 和 `Next`
- multipart：通过 `multipart.parse` 实现的 RFC 7578 表单解析，包含
  `getFile`、`getField` 和 `extractBoundary`。`multipart.cachedParse(req)`
  在请求上缓存解析结果（通过指针属性），同一请求内重复调用直接复用，
  不重复解析
- 静态文件：`StaticFiles` 服务，支持 MIME 类型、ETag/`If-None-Match`
  （304）、字节范围请求（206/416）以及路径穿越防护。文件内容以固定
  大小的分块从磁盘流式传输（`HttpResponse.FileBody` + `respondWithIo`），
  因此大文件以恒定内存发送。`StaticFiles.initCached(allocator, ...)` 启用
  一个有界（4096 项）、带 TTL（默认 60s）、由 `std.Io.Mutex` 保护的
  路径解析缓存，按 LRU 淘汰，使重复请求跳过 `path.join` + `stat`
- OpenAPI：`OpenApiDocument` 根据已注册的操作构建 OpenAPI 3.0.3 的
  JSON 文档（路径参数会自动呈现）。在注册路由后调用
  `server.enableOpenApi(.{ .title = ... })` 即可自动收集所有路由，并在
  `/openapi.json` 提供该文档。`addJsonOperation(Request, Response, method, path, .{})`
  在编译期将 Zig 的请求和响应类型反射为内联 JSON Schema（`void` 表示
  没有请求体）。反射器（`schema.writeSchema`）会映射 bool/int/float/string、
  可选类型（`nullable`）、切片/数组、枚举（`string` + `enum`）以及嵌套
  结构体（`object` + `properties`/`required`）
- 带类型的路由：通过 `server.postJson`/`getJson`/`putJson`/`patchJson`/
  `deleteJson`（或 `routeJson(method, ...)`）注册形如
  `fn(*HttpRequest, Body) E!Response`（或 `fn(*HttpRequest) E!Response`）的
  处理函数。一个编译期的 trampoline（跳板）会将 JSON 请求体解析为
  `Body`（JSON 格式错误时返回 `400`），调用处理函数，并将返回值序列化
  为 JSON 响应（`void` 产生一个空的 `200`）。被反射的 `Body`/`Response`
  类型在调用 `enableOpenApi` 时会自动馈入 OpenAPI schema。该 trampoline
  是一个具体的 `fn(*HttpRequest) anyerror!HttpResponse`，因此除了手写处理
  函数本就会做的请求体解析/序列化之外，没有额外的运行时分派开销
- 声明式路由注册：`meta_routes.registerRoutes(router, Handlers)` 在编译期
  读取 `Handlers.routes`（一个 `RouteDef` 数组），将其展开为普通的
  `Router.route` 调用，一次性注册全部路由（`registerGroupRoutes` 注册到
  `RouteGroup` 上以应用组中间件）。这是 Hical `HICAL_ROUTES` 宏的类型
  安全 Zig 等价物，无运行时反射开销
- WebSocket：RFC 6455 帧编解码器（`websocket.Frame` 带掩码的
  编码/解码）和握手密钥派生（`websocket.computeAcceptKey`）。通过
  `server.ws(path, handler)` 注册处理函数；服务器会执行升级并用一个
  `WebSocketSession`（`send`/`sendBinary`/`receive`/`close`）运行处理函数
- CORS：`Cors`/`CorsOptions` 上下文洋葱中间件。可配置
  `allowed_origins`/`allowed_methods`/`allowed_headers`、`expose_headers`、
  `allow_credentials` 和 `max_age_seconds`；预检请求会以 `204` 及正确的
  `Access-Control-*`/`Vary` 头进行响应。通过 `cors.attach(server)` 或
  `server.useOnionCtx(&cors, Cors.handle)` 注册
- 会话：`Session`/`SessionManager`，包含 `create`/`find`/`destroy`/
  `regenerate`/`gc`/`count`；ID 由 `io.random` 生成。`SessionMiddleware` 会将
  当前的 `*Session` 附加到请求上（通过 `session.fromRequest(req)` 读取）。
  所有会话操作都接收 `io: std.Io` 参数并通过 `std.Io.Mutex` 加锁；过期
  使用 `std.Io.Clock`
- WebSocket 集线器：`WsHub` 在一个传输无关的 `Sink` 之后跟踪活跃连接，
  包含 `add`/`remove`/`join`/`leave`/`broadcast`/`broadcastBinary`/
  `broadcastAll`/`sendTo`/`roomSize`/`connectionCount`。所有方法都接收
  `io: std.Io` 参数并通过 `std.Io.Mutex` 同步
- 日志：结构化的 `Logger`（`Level`/`Field`/`Sink`、`writerSink`），外加一个
  `LogMiddleware` 上下文洋葱，记录方法/路径/状态以及请求耗时（耗时来自
  `req.io`，通过 `std.Io.Clock`）。`FileSink` 通过 `std.Io.File` 的定位写入
  将日志行写入文件（默认截断，或用 `.{ .truncate = false }` 追加）。
  `AsyncFileSink` 是异步批处理文件 Sink（双缓冲 + 后台 fiber）：前端
  `write` 仅在 `std.Io.Mutex` 保护下追加到内存缓冲，由 `start(io)` 启动的
  后台 fiber 按 `flush_interval_ms` 定期交换缓冲并批量写盘；积压超过
  `backpressure_limit` 时丢弃日志并由 `droppedCount()` 计数，`stop(io)`
  排空并汇合后台 fiber。
  `LogChannel`/`LogChannelRegistry` 提供命名通道，其级别可原子地、在运行时
  调整；`LogAdmin` 是一个上下文洋葱，暴露 `GET`/`PUT {prefix}/log-level`
  （默认 `/admin`）以在运行时检查和更改通道级别，并可选用 `AdminAuthCheck`
  进行访问控制
- 请求头容器：`HeaderMap`，一个由分配器支持、大小写不敏感的多值
  请求头存储（`set`/`insert`/`erase`/`find`/`findAll`/`contains`/`count`/
  `reserve`/`clear`）；借用 name/value 切片
- 路由：路径参数（`:name`/`{name}`）和通配符 catch-all（`*`、`*name`、
  `{*name}`），它将整个尾部路径段绑定到一个捕获；通配符必须是最后
  一段
- 空闲超时：`ServerOptions.idle_timeout_ms` 限定在保活连接上等待下一个
  请求的时长（0 表示禁用）。它通过 zio 在事件循环内的 recv+定时器完成
  竞速实现，因此在 epoll/io_uring 就绪模型下都能正确触发，且不需要额外
  的协程
- 优雅关闭：`server.requestShutdown(io)`（线程安全）会通知 accept 循环
  停止接收新连接；随后 `start` 会在返回前通过 `Io.Group.await` 排空进行中
  的处理函数。`server.isAccepting()` 报告是否仍在接收新连接

尚未实现：SSL/TLS 和数据库模块，以及 WebSocket 的 `permessage-deflate`
压缩。在它们完全实现之前，这些特性都不会被暴露。
