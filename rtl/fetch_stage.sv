/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: fetch_stage.sv
 */

module fetch_stage (
    input logic clk,
    input logic rst,

    // Memory interface
    wishbone_interface.master wb,

    //  Output data
    output logic [31:0] instruction_reg_out,
    output logic [31:0] program_counter_reg_out,

    // Pipeline control
    output pipeline_status::forwards_t  status_forwards_out,
    input  pipeline_status::backwards_t status_backwards_in,
    input  logic [31:0] jump_address_backwards_in
);

    // Internal PC register
    logic [31:0] pc;

    // --- WISHBONE CONTINUOUS ASSIGNMENTS ---
    // Instruction fetches are read-only, full word, with no side-effects.
    assign wb.we  = 1'b0;
    assign wb.sel = 4'b1111;
    assign wb.dat_mosi = 32'b0;
    
    // Convert byte address to word address (drop lowest 2 bits)
    assign wb.adr = {2'b00, pc[31:2]}; 
    
    // We can constantly request data since RAM reads have no side effects
    assign wb.cyc = 1'b1;
    assign wb.stb = 1'b1;

    // --- SEQUENTIAL LOGIC ---
    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= constants::RESET_ADDRESS;
            instruction_reg_out <= 32'b0;
            program_counter_reg_out <= 32'b0;
            status_forwards_out <= pipeline_status::BUBBLE;
        end else begin
            
            // 1. Jumps take absolute priority
            if (status_backwards_in == pipeline_status::JUMP) begin
                pc <= jump_address_backwards_in;
                status_forwards_out <= pipeline_status::BUBBLE;
            end 
            
            // 2. Normal execution (READY to accept new data)
            else if (status_backwards_in == pipeline_status::READY) begin
                
                if (wb.ack) begin
                    // Memory successfully returned an instruction
                    instruction_reg_out <= wb.dat_miso;
                    program_counter_reg_out <= pc;
                    status_forwards_out <= pipeline_status::VALID;
                    pc <= pc + 4; // Advance to next instruction
                end 
                else if (wb.err) begin
                    // Memory signaled a fault
                    instruction_reg_out <= 32'b0;
                    program_counter_reg_out <= pc;
                    status_forwards_out <= pipeline_status::FETCH_FAULT;
                end 
                else begin
                    // Waiting on memory (Wishbone hasn't ACK'd yet)
                    status_forwards_out <= pipeline_status::BUBBLE;
                end
                
            end
            // 3. STALL condition
            // If status_backwards_in == STALL, we do absolutely nothing.
            // The PC doesn't advance, and the output registers hold their previous valid state.
        end
    end

endmodule
