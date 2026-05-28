# Zyra

Zyra is a Zig 0.16 web framework skeleton built around `std.Io` + `zio`, with
module boundaries intentionally aligned with Hical:

- `HttpServer` top-level facade
- `Router` with static and `{param}` routes
- `MiddlewarePipeline`
- `HttpRequest` / `HttpResponse`
- request-scoped arena allocation via `MemoryPool`
- `zio` runtime/network backend while protocol code uses `std.Io`

Run:

```bash
zig build run
```
