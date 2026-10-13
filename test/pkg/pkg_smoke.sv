// Elaboration check: every type in frontend_pkg is used as a port or signal.
module pkg_smoke (
  input  logic         clk,
  input  frontend_pkg::fetch_req_t   req_i,
  input  frontend_pkg::fetch_slot_t  slot_i,
  input  frontend_pkg::uop_t         uop_i,
  input  frontend_pkg::redirect_t    rdr_i,
  input  frontend_pkg::br_resolve_t  res_i,
  input  frontend_pkg::bp_train_t    trn_i,
  input  frontend_pkg::refill_req_t  rfr_i,
  input  frontend_pkg::refill_beat_t rfb_i,
  input  frontend_pkg::axi_ar_t      ar_i,
  input  frontend_pkg::axi_r_t       r_i,
  output logic [31:0]  sig_o
);
  logic [31:0] acc;
  localparam logic [31:0] HL0   = frontend_pkg::tage_hist_len(0);
  localparam logic [31:0] BEATS = frontend_pkg::REFILL_BEATS;
  always_ff @(posedge clk) begin
    acc <= {32{^{req_i, slot_i, uop_i, rdr_i, res_i, trn_i, rfr_i, rfb_i, ar_i, r_i}}}
         ^ HL0 ^ BEATS ^ {31'd0, frontend_pkg::parcel_is_rvc(slot_i.raw32[1:0])};
  end
  assign sig_o = acc;
endmodule
