# Hical benchmark

This benchmark builds a tiny Hical HTTP server and measures `GET /` with `wrk`.

Local run on Linux:

```bash
sudo apt-get install -y cmake ninja-build g++ libboost-all-dev libssl-dev zlib1g-dev wrk
cmake -S benchmark/hical -B build/hical -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/hical
./build/hical/hical_benchmark_server --port 3000 --threads 2
wrk -t2 -c100 -d10s http://127.0.0.1:3000/
```

The GitHub Actions workflow writes the result to the job summary and uploads
`benchmarks/hical-latest.json` as an artifact.
