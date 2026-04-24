`timescale 1ns / 1ps
`default_nettype none

module tetra_mac_resource_bl_ack_builder #(
    parameter integer PDU_BITS = 268
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire [23:0]         ssi,
    input  wire [2:0]          addr_type,
    input  wire                random_access_flag,
    input  wire                nr,
    output reg  [PDU_BITS-1:0] pdu_bits,
    output reg                 valid
);

    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_PACK = 3'd1;
    localparam [2:0] S_DONE = 3'd2;

    reg [2:0] state;
    reg [23:0] lat_ssi;
    reg [2:0]  lat_addr_type;
    reg        lat_random_access_flag;
    reg        lat_nr;

    reg [PDU_BITS-1:0] pdu_bits_c;
    reg                fill_bit_ind_c;
    always @(*) begin
        // BL-ACK: 43-bit MAC header + 5-bit LLC BL-ACK = 48 bits = 6 octets.
        fill_bit_ind_c = 1'b0;
        pdu_bits_c =
            ({ 2'b00,
               fill_bit_ind_c,
               1'b0,
               2'b00,
               lat_random_access_flag,
               6'd6,
               lat_addr_type,
               lat_ssi,
               1'b0,
               1'b0,
               1'b0,
               1'b0, 1'b0, 2'b11, lat_nr,
               {(PDU_BITS-48){1'b0}} });
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            lat_ssi <= 24'd0;
            lat_addr_type <= 3'd0;
            lat_random_access_flag <= 1'b0;
            lat_nr <= 1'b0;
            pdu_bits <= {PDU_BITS{1'b0}};
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
            S_IDLE: begin
                if (start) begin
                    lat_ssi <= ssi;
                    lat_addr_type <= addr_type;
                    lat_random_access_flag <= random_access_flag;
                    lat_nr <= nr;
                    state <= S_PACK;
                end
            end
            S_PACK: begin
                pdu_bits <= pdu_bits_c;
                state <= S_DONE;
            end
            S_DONE: begin
                valid <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
