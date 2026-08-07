// ap_axi_sdata.h — шим: ap_axiu<W,0,0,0> с полями data/keep/last.
//
// Настоящий ap_axiu имеет ещё strb/user/id/dest; ядра их не используют,
// но strb присутствует в коде заглушек, поэтому оставлен.
#ifndef SHIM_AP_AXI_SDATA_H
#define SHIM_AP_AXI_SDATA_H

#include "ap_int.h"

template <int W, int U, int TI, int TD>
struct ap_axiu {
    ap_uint_wide<W>     data;
    ap_uint_wide<W / 8> keep;
    ap_uint_wide<W / 8> strb;
    ap_uint<1>          last;

    ap_axiu() : last(0) {}
};

#endif // SHIM_AP_AXI_SDATA_H
