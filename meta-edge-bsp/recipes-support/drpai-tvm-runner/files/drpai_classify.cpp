// Real-input DRP-AI classification spike.
//
// Companion to drpai_runner.cpp: that one measures placement and latency with an
// unbound input; this one feeds a real image and decodes a real result. Both are
// recon tools, not the shipped inference path.
//
// The runtime does not expose GetInputInfo in this mode (Mera1.x reports
// "unsupports this function" and returns an empty list), so the input tensor is
// never described by the runtime. What works is the vendor tutorial's sequence:
// the compiled model directory carries its own DRP-AI pre-processing object under
// preprocess/, PreRuntime executes it, and its output buffer is bound with
// SetInput(0, ...). Resize and normalization are baked into that object, so the
// only per-run parameters are properties of the source image.
//
// Input must live in physically contiguous memory: PreRuntime reads it by physical
// address, so the image is staged through u-dma-buf (/dev/udmabuf0), not malloc.

#include <linux/drpai.h>
#include <builtin_fp16.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include "MeraDrpRuntimeWrapper.h"
#include "PreRuntime.h"

namespace {

constexpr uint32_t MEMORY_ALIGNMENT = 0x1000000;  // DRP-AI allocations are 16 MB aligned
constexpr uint32_t BMP_HEADER_SIZE  = 54;         // 14-byte file header + 40-byte v3 info header

unsigned char* img_buffer = nullptr;

double msec_between(const timespec& t0, const timespec& t1)
{
    return (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1000.0 / 1000.0;
}

float float16_to_float32(uint16_t a)
{
    return __extendXfYf2__<uint16_t, uint16_t, 10, float, uint32_t, 23>(a);
}

// DRP-AI reserved region base, via the driver ioctl.
uint32_t get_drpai_start_addr()
{
    int fd = open("/dev/drpai0", O_RDWR);
    if (fd < 0) {
        std::cerr << "[ERROR] open /dev/drpai0: errno=" << errno << "\n";
        return 0;
    }
    drpai_data_t drpai_data{};
    int ret = ioctl(fd, DRPAI_GET_DRPAI_AREA, &drpai_data);
    close(fd);
    if (ret == -1) {
        std::cerr << "[ERROR] DRPAI_GET_DRPAI_AREA: errno=" << errno << "\n";
        return 0;
    }
    return drpai_data.address;
}

// u-dma-buf physical base. Read as 64-bit then truncated: the sysfs value is
// printed full-width while PreRuntime takes a 32-bit address.
uint32_t get_udmabuf_addr()
{
    int fd = open("/sys/class/u-dma-buf/udmabuf0/phys_addr", O_RDONLY);
    if (fd < 0) {
        std::cerr << "[ERROR] open udmabuf phys_addr\n";
        return 0;
    }
    char addr[1024] = {0};
    ssize_t n = read(fd, addr, sizeof(addr) - 1);
    close(fd);
    if (n < 0) {
        std::cerr << "[ERROR] read udmabuf phys_addr\n";
        return 0;
    }
    uint64_t phys = 0;
    if (sscanf(addr, "%lx", &phys) != 1) return 0;
    return static_cast<uint32_t>(phys & 0xFFFFFFFF);
}

struct BmpInfo {
    uint32_t width  = 0;
    uint32_t height = 0;
    uint32_t channel = 3;
};

// Windows Bitmap v3 only, uncompressed 24bpp. Geometry is read from the header
// rather than assumed, so the source image is not pinned to one resolution.
bool read_bmp_header(const std::string& filename, BmpInfo& info)
{
    std::ifstream f(filename, std::ios::binary);
    if (!f) {
        std::cerr << "[ERROR] cannot open " << filename << "\n";
        return false;
    }
    uint8_t hdr[BMP_HEADER_SIZE];
    f.read(reinterpret_cast<char*>(hdr), BMP_HEADER_SIZE);
    if (!f) {
        std::cerr << "[ERROR] short read on BMP header\n";
        return false;
    }
    if (hdr[0] != 'B' || hdr[1] != 'M') {
        std::cerr << "[ERROR] not a BMP (bad magic)\n";
        return false;
    }
    auto le32 = [&hdr](int off) {
        return static_cast<uint32_t>(hdr[off]) | (static_cast<uint32_t>(hdr[off + 1]) << 8) |
               (static_cast<uint32_t>(hdr[off + 2]) << 16) | (static_cast<uint32_t>(hdr[off + 3]) << 24);
    };
    info.width  = le32(18);
    info.height = le32(22);
    uint16_t bpp = static_cast<uint16_t>(hdr[28] | (hdr[29] << 8));
    if (bpp != 24) {
        std::cerr << "[ERROR] only 24bpp BMP supported, got " << bpp << "\n";
        return false;
    }
    info.channel = 3;
    return true;
}

// Rows are bottom-up in a BMP and padded to a 4-byte boundary.
bool read_bmp_pixels(const std::string& filename, const BmpInfo& info)
{
    FILE* fp = fopen(filename.c_str(), "rb");
    if (!fp) return false;

    const uint32_t row_bytes = info.width * info.channel;
    const uint32_t padding   = (4 - (row_bytes % 4)) % 4;
    const uint32_t line_width = row_bytes + padding;

    if (fseek(fp, BMP_HEADER_SIZE, SEEK_SET) != 0) { fclose(fp); return false; }

    std::vector<uint8_t> line(line_width);
    for (int32_t i = static_cast<int32_t>(info.height) - 1; i >= 0; i--) {
        if (fread(line.data(), sizeof(uint8_t), line_width, fp) != line_width) {
            std::cerr << "[ERROR] short read on BMP row " << i << "\n";
            fclose(fp);
            return false;
        }
        memcpy(img_buffer + static_cast<size_t>(i) * row_bytes, line.data(), row_bytes);
    }
    fclose(fp);
    return true;
}

// Blank lines are skipped: the stock ImageNet synset file ends with one, which
// would otherwise count as a 1001st class and defeat the output-size check below.
std::map<int, std::string> load_label_file(const std::string& path)
{
    std::map<int, std::string> list;
    std::ifstream infile(path);
    if (!infile.is_open()) return list;
    std::string line;
    int n = 0;
    while (getline(infile, line)) {
        if (line.empty() || line == "\r") continue;
        list[n++] = line;
    }
    return list;
}

void softmax(float* val, int64_t size)
{
    float max_num = -static_cast<float>(INT_MAX);
    for (int64_t i = 0; i < size; i++) max_num = std::max(max_num, val[i]);
    float sum = 0;
    for (int64_t i = 0; i < size; i++) { val[i] = expf(val[i] - max_num); sum += val[i]; }
    for (int64_t i = 0; i < size; i++) val[i] /= sum;
}

void usage(const char* argv0)
{
    std::cerr << "usage: " << argv0 << " <model_dir> <image.bmp> <labels.txt> [-k topk]\n"
              << "  model_dir must contain deploy.json/params/so and a preprocess/ directory\n";
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 4) { usage(argv[0]); return 1; }

    const std::string model_dir = argv[1];
    const std::string image     = argv[2];
    const std::string labels    = argv[3];
    int topk = 5;
    for (int i = 4; i < argc; i++) {
        if (std::string(argv[i]) == "-k" && i + 1 < argc) topk = atoi(argv[++i]);
    }
    const std::string pre_dir = model_dir + "/preprocess";

    auto label_map = load_label_file(labels);
    if (label_map.empty()) {
        std::cerr << "[ERROR] failed to load labels: " << labels << "\n";
        return 1;
    }

    BmpInfo bmp;
    if (!read_bmp_header(image, bmp)) return 1;
    std::cout << "input image: " << image << " " << bmp.width << "x" << bmp.height
              << "x" << bmp.channel << "\n";

    uint32_t drpaimem_addr_start = get_drpai_start_addr();
    if (drpaimem_addr_start == 0) return 1;

    MeraDrpRuntimeWrapper runtime;
    PreRuntime preruntime;

    timespec t0, t1;

    // Model first, at the 16MB-aligned base of the DRP-AI region.
    uint32_t runtime_start_addr =
        (drpaimem_addr_start + MEMORY_ALIGNMENT - 1) & ~(MEMORY_ALIGNMENT - 1);
    timespec_get(&t0, TIME_UTC);
    runtime.LoadModel(model_dir, runtime_start_addr);
    timespec_get(&t1, TIME_UTC);
    std::cout << "[TIME] LoadModel: " << std::fixed << std::setprecision(2)
              << msec_between(t0, t1) << " msec\n";

    // Pre-processing object goes after whatever the model claimed. A CPU-only model
    // reports no last address; fall back to the region base.
    uint64_t runtime_last_addr = runtime.GetLastAddress();
    uint32_t preruntime_start_addr =
        (runtime_last_addr == 0)
            ? drpaimem_addr_start
            : static_cast<uint32_t>((runtime_last_addr + MEMORY_ALIGNMENT - 1) & ~(MEMORY_ALIGNMENT - 1));
    if (runtime_last_addr == 0)
        std::cout << "note: no runtime last address (CPU-only model?)\n";

    if (preruntime.Load(pre_dir, preruntime_start_addr) > 0) {
        std::cerr << "[ERROR] PreRuntime.Load failed: " << pre_dir << "\n";
        return 1;
    }

    auto input_data_type = runtime.GetInputDataType(0);
    if (InOutDataType::FLOAT32 != input_data_type) {
        std::cerr << "[ERROR] input data type is not FP32 (FP16 path not implemented here)\n";
        return 1;
    }

    const uint32_t udmabuf_size = bmp.height * bmp.width * bmp.channel;
    uint32_t udmabuf_addr_start = get_udmabuf_addr();
    if (udmabuf_addr_start == 0) return 1;

    int udmabuf_fd = open("/dev/udmabuf0", O_RDWR);
    if (udmabuf_fd < 0) {
        std::cerr << "[ERROR] open /dev/udmabuf0\n";
        return 1;
    }
    img_buffer = static_cast<unsigned char*>(
        mmap(NULL, udmabuf_size, PROT_READ | PROT_WRITE, MAP_SHARED, udmabuf_fd, 0));
    if (MAP_FAILED == img_buffer) {
        std::cerr << "[ERROR] mmap udmabuf\n";
        close(udmabuf_fd);
        return 1;
    }
    // Touch every page to back the mapping with physical memory. memset does not
    // reliably do this here.
    for (uint32_t i = 0; i < udmabuf_size; i++) img_buffer[i] = 0;

    if (!read_bmp_pixels(image, bmp)) {
        munmap(img_buffer, udmabuf_size);
        close(udmabuf_fd);
        return 1;
    }

    // Only the source geometry and colour order are supplied: resize and normalize
    // live in the compiled preprocess object.
    s_preproc_param_t in_param;
    in_param.pre_in_addr    = udmabuf_addr_start;
    in_param.pre_in_shape_w = bmp.width;
    in_param.pre_in_shape_h = bmp.height;
    in_param.pre_in_format  = FORMAT_BGR;
    in_param.pre_out_format = FORMAT_RGB;

    void* output_ptr = nullptr;
    uint32_t out_size = 0;
    timespec_get(&t0, TIME_UTC);
    if (preruntime.Pre(&in_param, &output_ptr, &out_size) > 0) {
        std::cerr << "[ERROR] PreRuntime.Pre failed\n";
        munmap(img_buffer, udmabuf_size);
        close(udmabuf_fd);
        return 1;
    }
    timespec_get(&t1, TIME_UTC);
    std::cout << "[TIME] Pre: " << msec_between(t0, t1) << " msec\n";

    runtime.SetInput(0, static_cast<float*>(output_ptr));

    timespec_get(&t0, TIME_UTC);
    runtime.Run();
    timespec_get(&t1, TIME_UTC);
    std::cout << "[TIME] Run: " << msec_between(t0, t1) << " msec\n";

    if (runtime.GetNumOutput() != 1) {
        std::cerr << "[ERROR] expected a single output tensor, got " << runtime.GetNumOutput()
                  << " -- not a plain classifier\n";
        munmap(img_buffer, udmabuf_size);
        close(udmabuf_fd);
        return 1;
    }

    auto output_buffer = runtime.GetOutput(0);
    int64_t n_out = std::get<2>(output_buffer);

    // A detector also reports a single output head, so GetNumOutput() alone does not
    // distinguish one from a classifier. Without this check a detection tensor gets
    // softmaxed and printed as confident-looking class names -- wrong output that
    // looks right. The element count must match the label list.
    // Compared as an upper bound, not equality: a label list may legitimately carry
    // extra entries (a background class, trailing junk), but an output larger than
    // the list cannot be indexed by it and is not a class vector at all.
    if (n_out > static_cast<int64_t>(label_map.size())) {
        std::cerr << "[ERROR] output has " << n_out << " elements but the label list has "
                  << label_map.size() << ". This is not a classifier for these labels"
                  << " (a detector or segmentation head reaches here too).\n";
        munmap(img_buffer, udmabuf_size);
        close(udmabuf_fd);
        return 1;
    }

    std::vector<float> scores(n_out);
    if (InOutDataType::FLOAT16 == std::get<0>(output_buffer)) {
        uint16_t* p = reinterpret_cast<uint16_t*>(std::get<1>(output_buffer));
        for (int64_t i = 0; i < n_out; i++) scores[i] = float16_to_float32(p[i]);
    } else if (InOutDataType::FLOAT32 == std::get<0>(output_buffer)) {
        float* p = reinterpret_cast<float*>(std::get<1>(output_buffer));
        for (int64_t i = 0; i < n_out; i++) scores[i] = p[i];
    } else {
        std::cerr << "[ERROR] output is not a floating point type\n";
        munmap(img_buffer, udmabuf_size);
        close(udmabuf_fd);
        return 1;
    }

    softmax(scores.data(), n_out);
    std::map<float, int> ranked;
    for (int64_t i = 0; i < n_out; i++) ranked[scores[i]] = static_cast<int>(i);

    std::cout << "classes: " << n_out << "\nResult -----------------------\n";
    int cnt = 0;
    for (auto it = ranked.rbegin(); it != ranked.rend() && cnt < topk; ++it) {
        cnt++;
        std::cout << "  Top " << cnt << " [" << std::right << std::setw(5) << std::fixed
                  << std::setprecision(1) << it->first * 100 << "%] : ["
                  << label_map[it->second] << "]\n";
    }

    munmap(img_buffer, udmabuf_size);
    close(udmabuf_fd);
    return 0;
}
