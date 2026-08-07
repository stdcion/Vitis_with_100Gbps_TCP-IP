// hls_stream.h — шим: hls::stream как обычная очередь.
//
// ВАЖНО про full(): здесь он всегда false, ровно как в настоящем csim
// (там stream неограничен). Значит все проверки full() в ядрах при таком
// прогоне — мёртвый код, и баги, зависящие от заполнения FIFO, этим
// способом не проявятся. Для них нужен cosim.
#ifndef SHIM_HLS_STREAM_H
#define SHIM_HLS_STREAM_H

#include <deque>
#include <string>
#include <cassert>

namespace hls {

template <typename T, int DEPTH = 0>
class stream {
    std::deque<T> q;
    std::string nm;
public:
    stream() {}
    explicit stream(const char* n) : nm(n) {}

    bool empty() const { return q.empty(); }

    // Как в csim: неограничен.
    bool full() const { return false; }

    void write(const T& x) { q.push_back(x); }

    T read() {
        assert(!q.empty() && "read() из пустого stream — в железе это залипание");
        T x = q.front(); q.pop_front(); return x;
    }
    // read(x) — форма с аргументом, используется в axi_utils.hpp
    void read(T& x) {
        assert(!q.empty() && "read() из пустого stream");
        x = q.front(); q.pop_front();
    }
    bool read_nb(T& x) {
        if (q.empty()) return false;
        x = q.front(); q.pop_front(); return true;
    }

    size_t size() const { return q.size(); }
    const std::string& name() const { return nm; }
};

} // namespace hls

#endif // SHIM_HLS_STREAM_H
