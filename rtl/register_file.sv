/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: register_file.sv
 */

module register_file (
    input logic clk,
    input logic rst,

    // read ports
    input  logic [4:0]  read_address1,
    output logic [31:0] read_data1,
    
    input  logic [4:0]  read_address2,
    output logic [31:0] read_data2,

    // write port
    input  logic [4:0]  write_address,
    input  logic [31:0] write_data,
    input  logic        write_enable
);

    // The 32 machine registers (x0 to x31), each 32-bits wide
    logic [31:0] registers [31:0];

    // ASYNCHRONOUS READ PORTS
    // The register at address zero always reads zero.
    assign read_data1 = (read_address1 == 5'b00000) ? 32'b0 : registers[read_address1];
    assign read_data2 = (read_address2 == 5'b00000) ? 32'b0 : registers[read_address2];

    // SYNCHRONOUS WRITE PORT
    always_ff @(posedge clk) begin
        if (rst) begin
            // Clear all registers on reset 
            for (int i = 0; i < 32; i++) begin
                registers[i] <= 32'b0;
            end
        end else begin
            // Write data if enabled, and block writes to x0
            if (write_enable && (write_address != 5'b00000)) begin
                registers[write_address] <= write_data;
            end
        end
    end

endmodule
