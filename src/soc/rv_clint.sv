// rv_clint - SiFive-style CLINT for one hart: msip, mtimecmp, mtime.
// mtime counts clock cycles and is writable. mtip = (mtime >= mtimecmp).
// Register access (32-bit words; off_i is the offset from 0x0200_0000):
//   0x0000 msip (bit 0)   0x4000/4 mtimecmp lo/hi   0xBFF8/C mtime lo/hi
// hit_o says whether off_i names a register (otherwise the SoC answers with
// an access fault).
module rv_clint (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] off_i,
  output logic        hit_o,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,
  output logic        mtip_o,
  output logic        msip_o,
  output logic [63:0] mtime_o
);
  logic        msip_q;
  logic [63:0] mtimecmp_q, mtime_q;

  always_comb begin
    hit_o   = 1'b1;
    rdata_o = '0;
    case (off_i)
      16'h0000: rdata_o = {31'b0, msip_q};
      16'h4000: rdata_o = mtimecmp_q[31:0];
      16'h4004: rdata_o = mtimecmp_q[63:32];
      16'hBFF8: rdata_o = mtime_q[31:0];
      16'hBFFC: rdata_o = mtime_q[63:32];
      default:  hit_o   = 1'b0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      msip_q     <= 1'b0;
      mtimecmp_q <= '1;
      mtime_q    <= '0;
    end else begin
      mtime_q <= mtime_q + 64'd1;
      if (we_i) begin
        case (off_i)
          16'h0000: msip_q             <= wdata_i[0];
          16'h4000: mtimecmp_q[31:0]   <= wdata_i;
          16'h4004: mtimecmp_q[63:32]  <= wdata_i;
          16'hBFF8: mtime_q[31:0]      <= wdata_i;
          16'hBFFC: mtime_q[63:32]     <= wdata_i;
          default: ;
        endcase
      end
    end
  end

  assign mtip_o  = (mtime_q >= mtimecmp_q);
  assign msip_o  = msip_q;
  assign mtime_o = mtime_q;
endmodule
