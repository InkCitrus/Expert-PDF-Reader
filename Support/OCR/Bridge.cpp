#include "rapidocrlite/rapidocrlite.h"
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>

namespace {
std::mutex mutex;
rpocr_ocr* engine = nullptr;

std::string quoted(const char* value) {
    std::string result = "\"";
    for (const unsigned char c : std::string(value ? value : "")) {
        if (c == '"' || c == '\\') { result += '\\'; result += c; }
        else if (c == '\n') result += "\\n";
        else if (c == '\r') result += "\\r";
        else if (c == '\t') result += "\\t";
        else if (c >= 0x20) result += c;
    }
    return result + '"';
}
char* error(const char* message) { return strdup(("{\"error\":" + quoted(message) + "}").c_str()); }
}

// One lazily loaded model shared by all windows; callers run on a worker thread.
// The reader's C ABI avoids exposing C++ or model dependencies to Swift/PDFKit.
extern "C" char* reader_ocr(const char* models, const unsigned char* rgb, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex);
    try {
        if (!engine) {
            const std::string directory(models);
            rpocr_options options;
            rpocr_options_init_ex(&options, sizeof(options));
            options.backend = RPOCR_BACKEND_CPU;
            // The 0/180 classifier incorrectly flips upright vertical Chinese columns.
            // PP-OCRv6 recognizes their original glyphs directly, without that classifier.
            options.use_cls = 0;
            engine = rpocr_create((directory + "/PP-OCRv6_det_small.onnx").c_str(),
                                 (directory + "/PP-OCRv6_rec_small.onnx").c_str(),
                                 (directory + "/characters.txt").c_str(), &options);
            if (!engine) return error(rpocr_last_error());
        }
        rpocr_image image = {width, height, rgb};
        rpocr_result result = {};
        if (rpocr_recognize(engine, &image, &result) != RPOCR_OK) return error(rpocr_last_error());
        std::string json = "{\"lines\":[";
        for (size_t i = 0; i < result.count; ++i) {
            const auto& box = result.items[i];
            if (i) json += ',';
            json += "{\"text\":" + quoted(box.text) + ",\"confidence\":" + std::to_string(box.confidence)
                + ",\"x\":" + std::to_string(box.bbox_x) + ",\"y\":" + std::to_string(box.bbox_y)
                + ",\"width\":" + std::to_string(box.bbox_w) + ",\"height\":" + std::to_string(box.bbox_h) + '}';
        }
        rpocr_result_free(&result);
        json += "]}";
        return strdup(json.c_str());
    } catch (const std::exception& exception) { return error(exception.what()); }
}
extern "C" void reader_ocr_free(char* result) { free(result); }
