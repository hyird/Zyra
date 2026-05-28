#include "core/HttpRequest.h"
#include "core/HttpResponse.h"
#include "core/HttpServer.h"

#include <charconv>
#include <cstdint>
#include <iostream>
#include <string_view>
#include <stdexcept>
#include <system_error>
#include <thread>

namespace
{
    uint16_t parsePort(std::string_view value)
    {
        unsigned parsed = 0;
        auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
        if (ec != std::errc{} || ptr != value.data() + value.size() || parsed == 0 || parsed > 65535)
        {
            throw std::invalid_argument("invalid --port value");
        }
        return static_cast<uint16_t>(parsed);
    }

    size_t parseThreads(std::string_view value)
    {
        size_t parsed = 0;
        auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
        if (ec != std::errc{} || ptr != value.data() + value.size() || parsed == 0)
        {
            throw std::invalid_argument("invalid --threads value");
        }
        return parsed;
    }
}

int main(int argc, char** argv)
{
    uint16_t port = 3000;
    size_t threads = 2;

    for (int i = 1; i < argc; ++i)
    {
        std::string_view arg(argv[i]);
        if (arg == "--port" && i + 1 < argc)
        {
            port = parsePort(argv[++i]);
        }
        else if (arg == "--threads" && i + 1 < argc)
        {
            threads = parseThreads(argv[++i]);
        }
        else if (arg == "--help" || arg == "-h")
        {
            std::cout << "Usage: hical_benchmark_server [--port PORT] [--threads N]\n";
            return 0;
        }
        else
        {
            std::cerr << "Unknown argument: " << arg << '\n';
            return 2;
        }
    }

    hical::HttpServer server(port, threads);
    server.setIdleTimeout(30.0);
    server.setMaxConnections(20000);

    server.router().get("/", [](const hical::HttpRequest&) -> hical::HttpResponse {
        hical::HttpResponse response;
        response.setBody("Hello from Hical\n", "text/plain");
        return response;
    });

    server.router().get("/json", [](const hical::HttpRequest&) -> hical::HttpResponse {
        return hical::HttpResponse::json({{"message", "Hello from Hical"}, {"framework", "hical"}});
    });

    std::cout << "Hical benchmark server listening on http://127.0.0.1:" << port
              << " with " << threads << " IO thread(s)\n";
    server.start();
    return 0;
}
