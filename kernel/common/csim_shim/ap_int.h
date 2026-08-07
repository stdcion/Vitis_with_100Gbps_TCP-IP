// ─────────────────────────────────────────────────────────────────────────────
// ap_int.h — минимальный шим для нативной сборки HLS-ядер на этой машине.
//
// Vitis HLS здесь не установлен, но тестбенчи ядер — обычный C++: они дёргают
// ядро по одному такту. Этот шим даёт ровно то, что нужно, чтобы такой
// тестбенч собрался и побежал нативно: ap_uint с битовыми срезами, ap_axiu,
// hls::stream.
//
// ГРАНИЦЫ ПРИМЕНИМОСТИ (важно, иначе выводы будут ложными):
//
//   1. hls::stream здесь НЕОГРАНИЧЕННЫЙ, full() всегда false — как и в
//      настоящем csim. Значит любая проверка full() в ядре здесь мёртвый код,
//      и баги, зависящие от давления FIFO, этим способом не ловятся. Для них
//      нужен cosim или ограниченный режим шима.
//
//   2. Ядра держат состояние в function-local static, поэтому между тестами
//      в одном процессе оно НЕ сбрасывается. Сценарии, требующие чистого
//      старта, надо разносить по отдельным исполняемым файлам.
//
//   3. Это не эмулятор тайминга. Такты считает тестбенч, вызывая ядро в цикле;
//      II, латентность конвейера и backpressure шимом не моделируются.
// ─────────────────────────────────────────────────────────────────────────────
#ifndef SHIM_AP_INT_H
#define SHIM_AP_INT_H

#include <cstdint>
#include <cstddef>
#include <cassert>

// ── ap_uint<W> для любой ширины ──────────────────────────────────────────────
//
// Значение хранится массивом 64-битных слов. Срезы поддерживаются шириной до
// 64 бит, в том числе на стыке двух слов — этого достаточно для всех
// обращений в ядрах: они читают поля заголовков, а не произвольные широкие
// окна. Попытка взять срез шире 64 бит падает на assert, а не считает молча
// неверно.
// Срез объявлен ОТДЕЛЬНЫМ нешаблонным типом. Так конверсия в ap_uint<W>
// любой ширины однозначна: один конструктор от ApRange вместо шаблонного,
// который компилятор не выводил (no viable conversion from 'Range').
struct ApRangeBase {
    virtual uint64_t rd() const = 0;
    virtual void     wr(uint64_t) = 0;
    virtual ~ApRangeBase() {}
};

struct ApRange {
    uint64_t* words;
    int hi, lo, nw, totalW;

    uint64_t rd() const {
        int width = hi - lo + 1;
        assert(width >= 1 && width <= 64 && "шим: срез шире 64 бит не поддержан");
        int wi = lo / 64, off = lo % 64;
        uint64_t m = (width >= 64) ? ~uint64_t(0) : ((uint64_t(1) << width) - 1);
        uint64_t res = words[wi] >> off;
        if (off && off + width > 64 && wi + 1 < nw) res |= words[wi + 1] << (64 - off);
        return res & m;
    }
    void wr(uint64_t x) {
        int width = hi - lo + 1;
        assert(width >= 1 && width <= 64 && "шим: срез шире 64 бит не поддержан");
        uint64_t m = (width >= 64) ? ~uint64_t(0) : ((uint64_t(1) << width) - 1);
        x &= m;
        int wi = lo / 64, off = lo % 64;
        uint64_t lowMask = m << off;
        words[wi] = (words[wi] & ~lowMask) | ((x << off) & lowMask);
        if (off && off + width > 64 && wi + 1 < nw) {
            int rest = off + width - 64;
            uint64_t hiMask = (uint64_t(1) << rest) - 1;
            words[wi + 1] = (words[wi + 1] & ~hiMask) | ((x >> (64 - off)) & hiMask);
        }
        int restBits = totalW % 64;
        if (restBits) words[nw - 1] &= (uint64_t(1) << restBits) - 1;
    }

    operator uint64_t() const { return rd(); }
    ApRange& operator=(uint64_t x)       { wr(x); return *this; }
    ApRange& operator=(const ApRange& o) { wr(o.rd()); return *this; }
};

template <int W>
struct ap_uint {
    static_assert(W >= 1, "ap_uint<W>: W должен быть >= 1");
    static const int NW = (W + 63) / 64;
    uint64_t w[NW];

    ap_uint()            { clear(); }
    ap_uint(uint64_t x)  { clear(); w[0] = x; trim(); }
    // Присваивание срезом: ap_uint<16> x = pkt.data(15,0).
    ap_uint(const ApRange& r) { clear(); w[0] = r.rd(); trim(); }

    void clear() { for (int i = 0; i < NW; i++) w[i] = 0; }

    // Обрезаем биты выше W в старшем слове, чтобы арифметика была по модулю 2^W.
    void trim() {
        int restBits = W % 64;
        if (restBits) w[NW - 1] &= (uint64_t(1) << restBits) - 1;
    }

    ap_uint& operator=(uint64_t x) { clear(); w[0] = x; trim(); return *this; }
    ap_uint& operator=(const ApRange& r) { return *this = r.rd(); }

    // Приведение к целому: младшие 64 бита. Для W<=64 это точное значение.
    operator uint64_t() const { return w[0]; }

    ap_uint& operator++()    { addU(1); return *this; }
    ap_uint  operator++(int) { ap_uint t = *this; addU(1); return t; }
    ap_uint& operator+=(uint64_t x) { addU(x); return *this; }
    ap_uint& operator-=(uint64_t x) { addU(~x + 1); return *this; }

    void addU(uint64_t x) {
        uint64_t carry = x;
        for (int i = 0; i < NW && carry; i++) {
            uint64_t before = w[i];
            w[i] = before + carry;
            carry = (w[i] < before) ? 1 : 0;
        }
        trim();
    }

    uint64_t get(int hi, int lo) const {
        int width = hi - lo + 1;
        assert(width >= 1 && width <= 64 &&
               "шим: срез шире 64 бит не поддержан");
        int wi = lo / 64, off = lo % 64;
        uint64_t m = (width >= 64) ? ~uint64_t(0) : ((uint64_t(1) << width) - 1);
        uint64_t res = w[wi] >> off;
        if (off && off + width > 64 && wi + 1 < NW)
            res |= w[wi + 1] << (64 - off);
        return res & m;
    }
    void set(int hi, int lo, uint64_t x) {
        int width = hi - lo + 1;
        assert(width >= 1 && width <= 64 &&
               "шим: срез шире 64 бит не поддержан");
        uint64_t m = (width >= 64) ? ~uint64_t(0) : ((uint64_t(1) << width) - 1);
        x &= m;
        int wi = lo / 64, off = lo % 64;
        uint64_t lowMask = (off + 64 <= 64 + 0 && width == 64 && off == 0)
                             ? ~uint64_t(0) : (m << off);
        w[wi] = (w[wi] & ~lowMask) | ((x << off) & lowMask);
        if (off && off + width > 64 && wi + 1 < NW) {
            int restBits = off + width - 64;
            uint64_t hiMask = (uint64_t(1) << restBits) - 1;
            w[wi + 1] = (w[wi + 1] & ~hiMask) | ((x >> (64 - off)) & hiMask);
        }
        trim();
    }

    // ── срез: x(hi, lo), читаемый и записываемый ──
    ApRange  operator()(int hi, int lo)       { return ApRange{w, hi, lo, NW, W}; }
    uint64_t operator()(int hi, int lo) const { return get(hi, lo); }

    // ── одиночный бит ──
    struct Bit {
        ap_uint* owner; int idx;
        operator uint64_t() const { return owner->get(idx, idx); }
        Bit& operator=(uint64_t x) { owner->set(idx, idx, x & 1); return *this; }
    };
    Bit      operator[](int i)       { return Bit{this, i}; }
    uint64_t operator[](int i) const { return get(i, i); }

    // Сравнения с целыми объявлены явно: иначе operator uint64_t() даёт
    // неоднозначность на выражениях вида (x == 0) для узких типов.
    bool operator==(uint64_t x) const { return uint64_t(w[0]) == x && highZero(); }
    bool operator!=(uint64_t x) const { return !(*this == x); }
    bool operator==(int x) const { return *this == uint64_t(x); }
    bool operator!=(int x) const { return !(*this == uint64_t(x)); }
    bool operator< (uint64_t x) const { return highZero() && w[0] <  x; }
    bool operator> (uint64_t x) const { return !highZero() || w[0] >  x; }
    bool operator<=(uint64_t x) const { return highZero() && w[0] <= x; }
    bool operator>=(uint64_t x) const { return !highZero() || w[0] >= x; }
    // Те же сравнения с int/unsigned: без них выражения (x < 64) и (x >= 64),
    // где литерал имеет тип int, дают ambiguity против uint64_t-версии.
    bool operator< (int x) const { return *this <  uint64_t(x); }
    bool operator> (int x) const { return *this >  uint64_t(x); }
    bool operator<=(int x) const { return *this <= uint64_t(x); }
    bool operator>=(int x) const { return *this >= uint64_t(x); }
    bool operator< (unsigned x) const { return *this <  uint64_t(x); }
    bool operator> (unsigned x) const { return *this >  uint64_t(x); }
    bool operator<=(unsigned x) const { return *this <= uint64_t(x); }
    bool operator>=(unsigned x) const { return *this >= uint64_t(x); }
    bool highZero() const {
        for (int i = 1; i < NW; i++) if (w[i]) return false;
        return true;
    }

    bool operator==(const ap_uint& o) const {
        for (int i = 0; i < NW; i++) if (w[i] != o.w[i]) return false;
        return true;
    }
    bool operator!=(const ap_uint& o) const { return !(*this == o); }
};

// Совместимость: часть кода могла ссылаться на ap_uint_wide.
template <int W> using ap_uint_wide = ap_uint<W>;

// ap_int — знаковый; ядрам нужен только как тип-заглушка.
template <int W> using ap_int_t = ap_uint<W>;

#endif // SHIM_AP_INT_H
