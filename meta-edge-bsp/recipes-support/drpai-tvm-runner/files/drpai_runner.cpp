// SPDX-License-Identifier: Apache-2.0
//
// Model-agnostic DRP-AI inference runner / benchmark for RZ/V2L.
//
// Loads any DRP-AI-compiled model directory (deploy.so/json/params), reads the
// input tensor shape+dtype from the runtime (no baked model identity), feeds a
// synthetic input, and times runtime.Run() over N iterations. Reports the
// latency distribution and a mac_nmlint IRQ delta as the NPU-execution witness.
// Optional --profile dumps the runtime's own per-operator table + CSV.
//
// Measures inference only (Run()); model load and host<->device copies are
// reported separately. Run() executes the whole graph = DRP-AI subgraph plus
// any CPU-fallback ops compiled into it, so the figure is end-to-end model
// inference, not an NPU-only slice.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <numeric>
#include <string>
#include <tuple>
#include <vector>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/drpai.h>

#include "MeraDrpRuntimeWrapper.h"

using clk = std::chrono::steady_clock;

static double ms_between(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

// drp_reserved base, needed by LoadModel. Same path the tutorial app uses.
static uint64_t get_drpai_start_addr() {
    int fd = open("/dev/drpai0", O_RDWR);
    if (fd < 0) { perror("[ERROR] open /dev/drpai0"); return 0; }
    drpai_data_t d{};
    int ret = ioctl(fd, DRPAI_GET_DRPAI_AREA, &d);
    close(fd);
    if (ret < 0) { perror("[ERROR] ioctl DRPAI_GET_DRPAI_AREA"); return 0; }
    return d.address;
}

// Sum the per-CPU counts of the DRP-AI AI-MAC normal-completion IRQ.
// Advances by a fixed amount per NPU inference; static when nothing runs.
static long read_mac_nmlint() {
    FILE* f = fopen("/proc/interrupts", "r");
    if (!f) return -1;
    char line[4096];
    long sum = -1;
    while (fgets(line, sizeof(line), f)) {
        if (!strstr(line, "mac_nmlint")) continue;
        sum = 0;
        // Fields after the "NN:" label are per-CPU counts until the first
        // non-numeric token (the irqchip name). Sum the leading integers.
        char* p = strchr(line, ':');
        if (!p) break;
        p++;
        char* tok = strtok(p, " \t");
        while (tok) {
            char* end = nullptr;
            long v = strtol(tok, &end, 10);
            if (end == tok || *end != '\0') break;  // hit a non-integer column
            sum += v;
            tok = strtok(nullptr, " \t");
        }
        break;
    }
    fclose(f);
    return sum;
}

struct Stats { double min, median, mean, p95, stddev; };

static Stats compute(std::vector<double> v) {
    Stats s{};
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    s.min = v.front();
    s.median = v[n / 2];
    s.p95 = v[std::min(n - 1, static_cast<size_t>(std::ceil(0.95 * n)) - 1)];
    s.mean = std::accumulate(v.begin(), v.end(), 0.0) / n;
    double acc = 0.0;
    for (double x : v) acc += (x - s.mean) * (x - s.mean);
    s.stddev = std::sqrt(acc / n);
    return s;
}

int main(int argc, char** argv) {
    std::string model_dir;
    int iters = 50, warmup = 5;
    bool profile = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-n" && i + 1 < argc) iters = std::atoi(argv[++i]);
        else if (a == "-w" && i + 1 < argc) warmup = std::atoi(argv[++i]);
        else if (a == "--profile") profile = true;
        else if (a[0] != '-') model_dir = a;
    }
    if (model_dir.empty()) {
        fprintf(stderr, "usage: drpai-runner <model_dir> [-n iters] [-w warmup] [--profile]\n");
        return 2;
    }

    uint64_t addr = get_drpai_start_addr();
    if (addr == 0) return 1;

    MeraDrpRuntimeWrapper runtime;
    auto tl0 = clk::now();
    // LoadModel throws (tvm::runtime::InternalError) on a bad/missing model dir
    // rather than returning false; catch it for a clean message instead of abort.
    try {
        if (!runtime.LoadModel(model_dir, addr)) {
            fprintf(stderr, "[ERROR] LoadModel returned false for %s\n", model_dir.c_str());
            return 1;
        }
    } catch (const std::exception& e) {
        fprintf(stderr, "[ERROR] LoadModel failed for %s: %s\n", model_dir.c_str(), e.what());
        return 1;
    }
    double load_ms = ms_between(tl0, clk::now());

    // Bind a synthetic input per model input tensor (values are data-independent
    // for NPU timing; zeros suffice).
    //
    // GetInputInfo is unsupported in the Mera1.x runtime mode used here: it returns
    // an empty list, so the loop below binds nothing and Run() executes on whatever
    // buffer the runtime allocated. That is acceptable for timing and fatal for
    // anything else, so say so instead of proceeding silently.
    auto inputs = runtime.GetInputInfo();
    if (inputs.empty()) {
        fprintf(stderr,
                "\n[WARNING] input is NOT bound: the runtime did not describe its input\n"
                "          tensors (GetInputInfo unsupported in this runtime mode).\n"
                "          Run() executes on an unspecified buffer.\n"
                "          Latency and NPU-placement figures below remain VALID -- the\n"
                "          workload is data-independent. Any output VALUE is meaningless.\n"
                "          For real input and decoded output, use drpai-classify.\n\n");
    }
    std::vector<std::vector<uint8_t>> bufs;
    bufs.reserve(inputs.size());
    for (size_t i = 0; i < inputs.size(); ++i) {
        auto [name, size, dt] = inputs[i];
        bufs.emplace_back(size, 0);
        printf("  input[%zu] name=%s bytes=%zu dtype=%d\n",
               i, name.c_str(), size, static_cast<int>(dt));
        if (dt == InOutDataType::FLOAT32)
            runtime.SetInput(static_cast<int>(i), reinterpret_cast<const float*>(bufs[i].data()));
        else if (dt == InOutDataType::FLOAT16)
            runtime.SetInput(static_cast<int>(i), reinterpret_cast<const uint16_t*>(bufs[i].data()));
        else {
            fprintf(stderr, "[ERROR] unsupported input dtype %d\n", static_cast<int>(dt));
            return 1;
        }
    }

    // Warmup (discarded) then timed iterations around Run() only.
    long irq0 = read_mac_nmlint();
    std::vector<double> lat;
    lat.reserve(iters);
    for (int i = 0; i < warmup + iters; ++i) {
        auto a = clk::now();
        runtime.Run();
        auto b = clk::now();
        if (i >= warmup) lat.push_back(ms_between(a, b));
    }
    long irq1 = read_mac_nmlint();

    Stats st = compute(lat);
    long irq_delta = (irq0 >= 0 && irq1 >= 0) ? irq1 - irq0 : -1;

    printf("\n=== %s ===\n", model_dir.c_str());
    printf("  load: %.1f ms   warmup: %d   iters: %d\n", load_ms, warmup, iters);
    printf("  Run() latency ms:  min %.2f  median %.2f  mean %.2f  p95 %.2f  stddev %.2f\n",
           st.min, st.median, st.mean, st.p95, st.stddev);
    // Steps-per-run is model-dependent (the AI-MAC may fire once or more per
    // inference); the witness is that the delta scales with the run count, not a
    // fixed multiple. A zero delta means the NPU never ran (silent CPU fallback).
    long total_runs = static_cast<long>(warmup) + iters;
    double per_run = total_runs ? static_cast<double>(irq_delta) / total_runs : 0.0;
    printf("  mac_nmlint IRQ: before=%ld after=%ld delta=%ld over %ld runs (%.2f/run) -- NPU %s\n",
           irq0, irq1, irq_delta, total_runs, per_run,
           irq_delta > 0 ? "confirmed" : "NOT stepping (CPU fallback?)");

    if (profile) {
        // ProfileRun appends its own ".txt"/".csv" to these base names.
        std::string tbl = "/tmp/drpai_profile_table";
        std::string csv = "/tmp/drpai_profile";
        runtime.ProfileRun(tbl, csv);
        printf("  profile written: %s.txt , %s.csv\n", tbl.c_str(), csv.c_str());
    }
    return 0;
}
