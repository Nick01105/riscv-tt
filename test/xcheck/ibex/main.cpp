// Sweep all 49,152 compressed parcels through both expanders.
#include "Vtb_xcheck.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_xcheck top;
    int total = 0, legal_both = 0, illegal_both = 0, enc_diff = 0, legality_diff = 0;
    FILE* log = std::fopen("xcheck_mismatches.txt", "w");
    for (unsigned c = 0; c < 65536; c++) {
        if ((c & 3) == 3) continue;
        top.instr = 0xA5A50000u | c;
        top.clk = 0; top.eval(); top.clk = 1; top.eval();
        total++;
        if (top.our_ill != top.their_ill) {
            legality_diff++;
            std::fprintf(log, "legality %04x ours_ill=%d ibex_ill=%d ours=%08x ibex=%08x\n",
                         c, top.our_ill, top.their_ill, top.ours, top.theirs);
        } else if (!top.our_ill) {
            legal_both++;
            if (top.ours != top.theirs) {
                enc_diff++;
                std::fprintf(log, "encoding %04x ours=%08x ibex=%08x\n", c, top.ours, top.theirs);
            }
        } else {
            illegal_both++;
        }
    }
    std::fclose(log);
    std::printf("parcels=%d legal_both=%d illegal_both=%d encoding_mismatch=%d legality_mismatch=%d\n",
                total, legal_both, illegal_both, enc_diff, legality_diff);
    return (enc_diff || legality_diff) ? 1 : 0;
}
