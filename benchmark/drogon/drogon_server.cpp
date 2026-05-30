#include <drogon/drogon.h>

#include <charconv>
#include <cstdint>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <system_error>

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
    uint16_t port = 3002;
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
            std::cout << "Usage: drogon_benchmark_server [--port PORT] [--threads N]\n";
            return 0;
        }
        else
        {
            std::cerr << "Unknown argument: " << arg << '\n';
            return 2;
        }
    }

    drogon::app().setLogLevel(trantor::Logger::kWarn);
    drogon::app().setThreadNum(threads);
    drogon::app().addListener("127.0.0.1", port);
    drogon::app().registerHandler(
        "/",
        [](const drogon::HttpRequestPtr&, std::function<void(const drogon::HttpResponsePtr&)>&& callback) {
            auto response = drogon::HttpResponse::newHttpResponse();
            response->setContentTypeCode(drogon::CT_TEXT_PLAIN);
            response->setBody("Hello from Drogon\n");
            callback(response);
        },
        {drogon::Get});

    std::cout << "Drogon benchmark server listening on http://127.0.0.1:" << port
              << " with " << threads << " IO thread(s)\n";
    drogon::app().run();
    return 0;
}
