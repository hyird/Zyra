# Zyra

Zyra is a Zig 0.16 web framework skeleton built around `std.Io` + `zio`, with
module boundaries intentionally aligned with Hical:

- `HttpServer` top-level facade
- `Router` with static and `{param}` routes
- `MiddlewarePipeline`
- `HttpRequest` / `HttpResponse`
- `std.http.Server` HTTP/1.1 parsing and response writing
- request-scoped arena allocation via `MemoryPool`
- `zio` runtime/network backend while protocol code uses `std.Io`
- Hical-inspired web API helpers for routes, route groups, requests, responses,
  query/form/cookie parsing, and server limits

Run:

```bash
zig build run
```

Implemented web-facing Hical-style API surface includes:

- route methods: `get`, `post`, `put`, `patch`, `delete`/`del`, `head`, `options`
- `Router.group()` / `RouteGroup` prefix routing
- request helpers: `header`, `query`, `queryParam`, `queryParams`, `cookie`,
  `cookies`, `formParam`, `formParams`, `body`, `contentType`, `readJson`,
  `jsonResponse`, path params, and string attributes
- response helpers: `statusCode`, `setStatus`, `header`, `setHeader`,
  `setBody`, `bodyText`, `jsonValue`, `setJsonBody`, `badRequest`, `redirect`,
  `setCookie`, and 416 range error factory
- server limit setters for body/header size and max connections
- middleware: synchronous onion model via `MiddlewarePipeline`
  (`use`/`useOnion`/`useBeforeAfter`), with `MiddlewareHandler`, `BeforeHandler`,
  `AfterHandler`, and `Next`
- multipart: RFC 7578 form parsing via `multipart.parse`, with `getFile`,
  `getField`, and `extractBoundary`
- static files: `StaticFiles` serving with MIME types, ETag/`If-None-Match`
  (304), byte-range requests (206/416), and path-traversal protection
- OpenAPI: `OpenApiDocument` builds an OpenAPI 3.0.3 JSON document from
  registered operations (path params surfaced automatically)
- WebSocket: RFC 6455 frame codec (`websocket.Frame` encode/decode with
  masking) and handshake key derivation (`websocket.computeAcceptKey`)

Not implemented yet: SSL/TLS and database/logging modules. Idle timeout,
graceful shutdown, and GC interval APIs are intentionally not exposed until they
are fully implemented.
