// rv_skid_buffer - fully registered valid/ready pipeline stage.
// Breaks both the forward (valid/data) and backward (ready) timing paths and
// still runs at one transfer per cycle. When the output stalls, the one item
// already in flight lands in the skid register.
module rv_skid_buffer #(
  parameter int W = 32
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         flush_i,
  input  logic         in_valid_i,
  output logic         in_ready_o,
  input  logic [W-1:0] in_data_i,
  output logic         out_valid_o,
  input  logic         out_ready_i,
  output logic [W-1:0] out_data_o
);
  logic         out_valid_q, skid_valid_q;
  logic [W-1:0] out_data_q,  skid_data_q;
  logic         out_free;

  assign in_ready_o  = !skid_valid_q;
  assign out_valid_o = out_valid_q;
  assign out_data_o  = out_data_q;
  assign out_free    = out_ready_i || !out_valid_q;

  always_ff @(posedge clk) begin
    if (!rst_n || flush_i) begin
      out_valid_q  <= 1'b0;
      skid_valid_q <= 1'b0;
    end else if (out_free) begin
      if (skid_valid_q) begin
        out_valid_q  <= 1'b1;
        skid_valid_q <= 1'b0;
      end else begin
        out_valid_q  <= in_valid_i;
      end
    end else if (in_valid_i && in_ready_o) begin
      skid_valid_q <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (out_free) begin
      if (skid_valid_q)    out_data_q <= skid_data_q;
      else if (in_valid_i) out_data_q <= in_data_i;
    end else if (in_valid_i && in_ready_o) begin
      skid_data_q <= in_data_i;
    end
  end
endmodule
