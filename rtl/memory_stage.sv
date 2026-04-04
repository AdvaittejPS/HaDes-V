/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: memory_stage.sv
 */

module memory_stage (
    input logic clk,
    input logic rst,

    // Memory interface
    wishbone_interface.master wb,

    // Inputs
    input logic [31:0]   source_data_in,
    input logic [31:0]   rd_data_in,
    input instruction::t instruction_in,
    input logic [31:0]   program_counter_in,
    input logic [31:0]   next_program_counter_in,

    // Outputs
    output logic [31:0]   source_data_reg_out,
    output logic [31:0]   rd_data_reg_out,
    output instruction::t instruction_reg_out,
    output logic [31:0]   program_counter_reg_out,
    output logic [31:0]   next_program_counter_reg_out,
    output forwarding::t  forwarding_out,

    // Pipeline control
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::forwards_t  status_forwards_out,
    input  pipeline_status::backwards_t status_backwards_in,
    output pipeline_status::backwards_t status_backwards_out,
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out
);

    // =========================================================================
    // 1. Instruction Decoding & Alignment Checking
    // =========================================================================
    logic is_load, is_store, mem_active;
    logic [1:0] addr_offset;
    logic load_misaligned, store_misaligned, is_misaligned;

    assign is_load  = (instruction_in.op inside {op::LB, op::LH, op::LW, op::LBU, op::LHU});
    assign is_store = (instruction_in.op inside {op::SB, op::SH, op::SW});
    assign mem_active = (is_load || is_store) && (status_forwards_in == pipeline_status::VALID);
    
    // The lowest 2 bits of the address tell us the byte offset within the word
    assign addr_offset = rd_data_in[1:0];

    always_comb begin
        load_misaligned = 1'b0;
        store_misaligned = 1'b0;

        // Word operations (LW, SW) must be 4-byte aligned (offset == 00)
        // Halfword operations (LH, LHU, SH) must be 2-byte aligned (offset[0] == 0)
        if (instruction_in.op == op::LW && addr_offset != 2'b00) load_misaligned = 1'b1;
        if (instruction_in.op inside {op::LH, op::LHU} && addr_offset[0] != 1'b0) load_misaligned = 1'b1;
        
        if (instruction_in.op == op::SW && addr_offset != 2'b00) store_misaligned = 1'b1;
        if (instruction_in.op == op::SH && addr_offset[0] != 1'b0) store_misaligned = 1'b1;
    end

    assign is_misaligned = load_misaligned || store_misaligned;

    // =========================================================================
    // 2. Wishbone Bus Interface (Dynamic Shifting)
    // =========================================================================
    logic [3:0] wb_sel;

    // Calculate Byte Enables based on operation and offset
    always_comb begin
        if (instruction_in.op inside {op::LB, op::LBU, op::SB}) begin
            wb_sel = 4'b0001 << addr_offset;
        end else if (instruction_in.op inside {op::LH, op::LHU, op::SH}) begin
            wb_sel = 4'b0011 << addr_offset;
        end else if (instruction_in.op inside {op::LW, op::SW}) begin
            wb_sel = 4'b1111;
        end else begin
            wb_sel = 4'b0000;
        end
    end

    // Only assert CYC and STB if it's a valid, aligned memory op, and downstream isn't jumping
    assign wb.cyc = mem_active && !is_misaligned && (status_backwards_in != pipeline_status::JUMP);
    assign wb.stb = wb.cyc;
    assign wb.we  = is_store;
    
    // Address must be word-aligned (drop lowest 2 bits)
    assign wb.adr = {2'b00, rd_data_in[31:2]};
    assign wb.sel = wb_sel;
    
    // Shift the data to the correct byte lanes for writing
    assign wb.dat_mosi = source_data_in << (addr_offset * 8);

    // =========================================================================
    // 3. Read Data Formatting
    // =========================================================================
    logic [31:0] shifted_miso;
    logic [31:0] formatted_read_data;

    // Shift the data down from its byte lane to the bottom 
    assign shifted_miso = wb.dat_miso >> (addr_offset * 8);

    // Apply Sign/Zero Extension
    always_comb begin
        case (instruction_in.op)
            op::LB:  formatted_read_data = {{24{shifted_miso[7]}},  shifted_miso[7:0]};
            op::LBU: formatted_read_data = {24'b0,                  shifted_miso[7:0]};
            op::LH:  formatted_read_data = {{16{shifted_miso[15]}}, shifted_miso[15:0]};
            op::LHU: formatted_read_data = {16'b0,                  shifted_miso[15:0]};
            op::LW:  formatted_read_data = shifted_miso;
            default: formatted_read_data = rd_data_in; // Pass-through ALU results
        endcase
    end

    // =========================================================================
    // 4. Pipeline Back-Pressure & Forwarding
    // =========================================================================
    logic memory_busy;
    
    // We are busy if we started a Wishbone transaction but haven't received ACK or ERR yet
    assign memory_busy = wb.cyc && !(wb.ack || wb.err);

    // Backwards Control: Tell Execute to STALL if memory is busy
    always_comb begin
        if (status_backwards_in == pipeline_status::JUMP) begin
            status_backwards_out = pipeline_status::JUMP;
        end else if (memory_busy) begin
            status_backwards_out = pipeline_status::STALL;
        end else begin
            status_backwards_out = status_backwards_in;
        end
    end

    assign jump_address_backwards_out = jump_address_backwards_in;

    // Forwarding: Send data back to Decode instantly
    always_comb begin
        forwarding_out.address = (status_forwards_in == pipeline_status::VALID) ? instruction_in.rd_address : 5'b0;
        
        if (is_load) begin
            forwarding_out.data = formatted_read_data;
            // Load data is ONLY valid to forward once the Wishbone bus acknowledges it
            forwarding_out.data_valid = (status_forwards_in == pipeline_status::VALID) && wb.ack;
        end else begin
            forwarding_out.data = rd_data_in; // Pass through ALU result
            // ALU data is immediately valid to forward
            forwarding_out.data_valid = (status_forwards_in == pipeline_status::VALID);
        end
    end

    // =========================================================================
    // 5. Unified Synchronous Pipeline Registers
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            status_forwards_out          <= pipeline_status::BUBBLE;
            program_counter_reg_out      <= constants::RESET_ADDRESS;
            next_program_counter_reg_out <= constants::RESET_ADDRESS;
            instruction_reg_out          <= '0;
            source_data_reg_out          <= 32'b0;
            rd_data_reg_out              <= 32'b0;
        end else begin
            if (status_backwards_in == pipeline_status::JUMP) begin
                status_forwards_out <= pipeline_status::BUBBLE;
            end else if (!memory_busy) begin
                // Only update pipeline registers when memory is NOT busy (or not a memory op)
                program_counter_reg_out      <= program_counter_in;
                next_program_counter_reg_out <= next_program_counter_in;
                instruction_reg_out          <= instruction_in;
                source_data_reg_out          <= source_data_in;

                if (is_load) begin
                    rd_data_reg_out <= formatted_read_data;
                end else begin
                    rd_data_reg_out <= rd_data_in;
                end

                // Determine Output Status
                if (status_forwards_in == pipeline_status::VALID) begin
                    if (load_misaligned) begin
                        status_forwards_out <= pipeline_status::LOAD_MISALIGNED;
                    end else if (store_misaligned) begin
                        status_forwards_out <= pipeline_status::STORE_MISALIGNED;
                    end else if (wb.cyc && wb.err) begin
                        status_forwards_out <= is_load ? pipeline_status::LOAD_FAULT : pipeline_status::STORE_FAULT;
                    end else begin
                        status_forwards_out <= pipeline_status::VALID;
                    end
                end else begin
                    // Pass through BUBBLE or previous stage's errors
                    status_forwards_out <= status_forwards_in;
                end
            end
            // If memory_busy == 1, we literally do nothing here. 
            // The registers hold their current state, effectively stalling the pipeline.
        end
    end

endmodule
