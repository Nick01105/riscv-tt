// rv_muldiv - iterative M-extension unit, one bit per cycle.
//
// f3_i is the instruction's funct3 (MUL, MULH, MULHSU, MULHU, DIV, DIVU,
// REM, REMU). word_i selects the RV64 *W forms: operands are sign- or
// zero-extended from 32 bits, the full-width operation runs, and the low
// word of the result is sign-extended (this gives the architected results,
// including division by zero and overflow).
//
// Signed operations run on magnitudes and fix the sign at the output.
// Multiply: shift-add into {hi, lo}, XLEN cycles. Divide: restoring, the
// remainder in hi and the quotient shifting into lo, XLEN cycles. Division
// by zero skips the iterations (quotient all ones, remainder = dividend).
//
// start_i is taken in IDLE; done_o then stays high with y_o valid until
// ack_i. kill_i abandons the operation.
module rv_muldiv #(
  parameter int XLEN = 32
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            kill_i,
  input  logic            start_i,
  input  logic [2:0]      f3_i,
  input  logic            word_i,
  input  logic [XLEN-1:0] a_i,
  input  logic [XLEN-1:0] b_i,
  output logic            busy_o,
  output logic            done_o,
  input  logic            ack_i,
  output logic [XLEN-1:0] y_o
);
  localparam int CW = $clog2(XLEN) + 1;
  localparam logic [1:0] S_IDLE = 2'd0, S_BUSY = 2'd1, S_DONE = 2'd2;

  logic [1:0]      st_q;
  logic [CW-1:0]   cnt_q;
  logic [XLEN-1:0] hi_q, lo_q, opnd_q;
  logic            is_div_q, hi_sel_q, neg_lo_q, neg_hi_q, word_q;

  // ---- operand preparation ------------------------------------------------
  logic            is_div, a_sgn, b_sgn;
  logic [XLEN-1:0] a_x, b_x, a_mag, b_mag;

  assign is_div = f3_i[2];
  // MULH (1) and MULHSU (2) treat a as signed, MULH treats b as signed;
  // DIV (4) and REM (6) are signed. MUL (0) is sign-agnostic.
  assign a_sgn = is_div ? !f3_i[0] : (f3_i == 3'd1 || f3_i == 3'd2);
  assign b_sgn = is_div ? !f3_i[0] : (f3_i == 3'd1);

  generate
    if (XLEN == 64) begin : g_w
      always_comb begin
        a_x = a_i;
        b_x = b_i;
        if (word_i) begin
          a_x = a_sgn ? {{32{a_i[31]}}, a_i[31:0]} : {32'b0, a_i[31:0]};
          b_x = b_sgn ? {{32{b_i[31]}}, b_i[31:0]} : {32'b0, b_i[31:0]};
        end
      end
    end else begin : g_n
      assign a_x = a_i;
      assign b_x = b_i;
    end
  endgenerate

  logic a_neg, b_neg, b_zero;
  assign a_neg  = a_sgn && a_x[XLEN-1];
  assign b_neg  = b_sgn && b_x[XLEN-1];
  assign a_mag  = a_neg ? (~a_x + 1'b1) : a_x;
  assign b_mag  = b_neg ? (~b_x + 1'b1) : b_x;
  assign b_zero = (b_x == '0);

  // ---- one iteration ---------------------------------------------------------
  // one shared adder: hi + (lo[0] ? opnd : 0) for multiply, rem - opnd for divide
  logic [XLEN:0]   m_sum, d_rem, d_dif, add_a, add_b, add_y;
  assign d_rem = {hi_q, lo_q[XLEN-1]};
  assign add_a = is_div_q ? d_rem : {1'b0, hi_q};
  assign add_b = is_div_q ? ~{1'b0, opnd_q} : {1'b0, lo_q[0] ? opnd_q : {XLEN{1'b0}}};
  assign add_y = add_a + add_b + {{XLEN{1'b0}}, is_div_q};
  assign m_sum = add_y;
  assign d_dif = add_y;

  always_ff @(posedge clk) begin
    if (!rst_n || kill_i) begin
      st_q <= S_IDLE;
    end else begin
      case (st_q)
        S_IDLE: if (start_i) begin
          is_div_q <= is_div;
          word_q   <= word_i;
          hi_sel_q <= is_div ? f3_i[1] : (f3_i != 3'd0);   // REM/REMU: remainder; MULH*: high word
          cnt_q    <= '0;
          if (is_div && b_zero) begin
            hi_q     <= a_x;
            lo_q     <= '1;
            neg_lo_q <= 1'b0;
            neg_hi_q <= 1'b0;
            st_q     <= S_DONE;
          end else begin
            hi_q     <= '0;
            lo_q     <= is_div ? a_mag : b_mag;
            opnd_q   <= is_div ? b_mag : a_mag;
            neg_lo_q <= a_neg ^ b_neg;                      // quotient / product sign
            neg_hi_q <= is_div ? a_neg : (a_neg ^ b_neg);   // remainder takes the dividend's sign
            st_q     <= S_BUSY;
          end
        end
        S_BUSY: begin
          if (is_div_q) begin
            if (!d_dif[XLEN]) begin
              hi_q <= d_dif[XLEN-1:0];
              lo_q <= {lo_q[XLEN-2:0], 1'b1};
            end else begin
              hi_q <= d_rem[XLEN-1:0];
              lo_q <= {lo_q[XLEN-2:0], 1'b0};
            end
          end else begin
            hi_q <= m_sum[XLEN:1];
            lo_q <= {m_sum[0], lo_q[XLEN-1:1]};
          end
          cnt_q <= cnt_q + 1'b1;
          if (cnt_q == CW'(XLEN - 1)) st_q <= S_DONE;
        end
        S_DONE: if (ack_i) st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  // ---- result ------------------------------------------------------------------
  // Product negation: -{hi,lo} = {~hi + (lo == 0), ~lo + 1}. Quotient and
  // remainder are negated independently.
  logic [XLEN-1:0] res, sel, inv;
  logic            neg, cin;
  assign sel = hi_sel_q ? hi_q : lo_q;
  assign neg = hi_sel_q ? neg_hi_q : neg_lo_q;
  assign cin = (hi_sel_q && !is_div_q) ? (lo_q == '0) : 1'b1;
  assign inv = ~sel + {{(XLEN-1){1'b0}}, cin};
  assign res = neg ? inv : sel;

  generate
    if (XLEN == 64) begin : g_wy
      assign y_o = word_q ? {{32{res[31]}}, res[31:0]} : res;
    end else begin : g_ny
      assign y_o = res;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused;
      assign unused = word_q;
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endgenerate

  assign busy_o = (st_q == S_BUSY);
  assign done_o = (st_q == S_DONE);
endmodule
