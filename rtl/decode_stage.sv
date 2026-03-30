/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: decode_stage.sv
 */

module decode_stage (
    input logic clk,
    input logic rst,

    // Inputs
    input logic [31:0]  instruction_in,
    input logic [31:0]  program_counter_in,
    input forwarding::t exe_forwarding_in,
    input forwarding::t mem_forwarding_in,
    input forwarding::t wb_forwarding_in,

    // Output Registers
    output logic [31:0]   rs1_data_reg_out,
    output logic [31:0]   rs2_data_reg_out,
    output logic [31:0]   program_counter_reg_out,
    output instruction::t instruction_reg_out,

    // Pipeline control
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::forwards_t  status_forwards_out,
    input  pipeline_status::backwards_t status_backwards_in,
    output pipeline_status::backwards_t status_backwards_out,
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out
);

    // --- 1. INSTANTIATE SUBMODULES ---
    
    instruction::t decoded_instr;
    
    // The pre-compiled reference decoder (until you write it in Ex 4)
    instruction_decoder decoder (
        .instruction_in(instruction_in),
        .instruction_out(decoded_instr)
    );

    logic [31:0] rf_read_data1;
    logic [31:0] rf_read_data2;

    // The register file we built!
    register_file reg_file (
        .clk(clk),
        .rst(rst),
        .read_address1(decoded_instr.rs1_address),
        .read_data1(rf_read_data1),
        .read_address2(decoded_instr.rs2_address),
        .read_data2(rf_read_data2),
        .write_address(wb_forwarding_in.address),
        .write_data(wb_forwarding_in.data),
        .write_enable(wb_forwarding_in.data_valid)
    );

    // --- 2. FORWARDING & HAZARD DETECTION ---
    
    logic [31:0] rs1_data_fw;
    logic [31:0] rs2_data_fw;
    logic hazard_stall;

    always_comb begin
        // Default: No stall, use data directly from Register File
        hazard_stall = 1'b0;
        rs1_data_fw = rf_read_data1;
        rs2_data_fw = rf_read_data2;

        // RS1 Forwarding Priority: EXE > MEM > WB
        if (decoded_instr.rs1_address != 5'b00000) begin
            if (decoded_instr.rs1_address == exe_forwarding_in.address) begin
                if (exe_forwarding_in.data_valid) rs1_data_fw = exe_forwarding_in.data;
                else hazard_stall = 1'b1;
            end 
            else if (decoded_instr.rs1_address == mem_forwarding_in.address) begin
                if (mem_forwarding_in.data_valid) rs1_data_fw = mem_forwarding_in.data;
                else hazard_stall = 1'b1;
            end 
            else if (decoded_instr.rs1_address == wb_forwarding_in.address) begin
                if (wb_forwarding_in.data_valid) rs1_data_fw = wb_forwarding_in.data;
                else hazard_stall = 1'b1;
            end
        end

        // RS2 Forwarding Priority: EXE > MEM > WB
        if (decoded_instr.rs2_address != 5'b00000) begin
            if (decoded_instr.rs2_address == exe_forwarding_in.address) begin
                if (exe_forwarding_in.data_valid) rs2_data_fw = exe_forwarding_in.data;
                else hazard_stall = 1'b1;
            end 
            else if (decoded_instr.rs2_address == mem_forwarding_in.address) begin
                if (mem_forwarding_in.data_valid) rs2_data_fw = mem_forwarding_in.data;
                else hazard_stall = 1'b1;
            end 
            else if (decoded_instr.rs2_address == wb_forwarding_in.address) begin
                if (wb_forwarding_in.data_valid) rs2_data_fw = wb_forwarding_in.data;
                else hazard_stall = 1'b1;
            end
        end
    end

    // --- 3. COMBINATORIAL BACKWARDS STATUS ---
    
    assign jump_address_backwards_out = jump_address_backwards_in;

    always_comb begin
        if (status_backwards_in == pipeline_status::JUMP) begin
            status_backwards_out = pipeline_status::JUMP;
        end else if (status_backwards_in == pipeline_status::STALL || hazard_stall) begin
            status_backwards_out = pipeline_status::STALL;
        end else begin
            status_backwards_out = pipeline_status::READY;
        end
    end

    // --- 4. SYNCHRONOUS PIPELINE REGISTERS ---
    
    always_ff @(posedge clk) begin
        if (rst) begin
            instruction_reg_out <= '0;
            program_counter_reg_out <= constants::RESET_ADDRESS;
            rs1_data_reg_out <= 32'b0;
            rs2_data_reg_out <= 32'b0;
            status_forwards_out <= pipeline_status::BUBBLE;
        end else begin
            
            // Priority 1: Jumps (Flush the stage)
            if (status_backwards_in == pipeline_status::JUMP) begin
                status_forwards_out <= pipeline_status::BUBBLE;
                instruction_reg_out <= decoded_instr;
                program_counter_reg_out <= program_counter_in;
            end 
            
            // Priority 2: External Stall (Hold state, do nothing)
            else if (status_backwards_in == pipeline_status::STALL) begin
                // Maintain all outputs exactly as they are
            end 
            
            // Priority 3: Internal Hazard Stall (Emit bubble downstream, hold upstream)
            else if (hazard_stall) begin
                status_forwards_out <= pipeline_status::BUBBLE;
                // Registers are NOT updated because we haven't resolved the hazard yet
            end 
            
            // Priority 4: Normal Execution
            else begin
                instruction_reg_out <= decoded_instr;
                program_counter_reg_out <= program_counter_in;
                rs1_data_reg_out <= rs1_data_fw;
                rs2_data_reg_out <= rs2_data_fw;

                // Evaluate the incoming status and decoded errors
                if (status_forwards_in != pipeline_status::VALID) begin
                    status_forwards_out <= status_forwards_in; // Pass BUBBLE or FETCH_FAULT
                end else if (decoded_instr.op == op::ILLEGAL) begin
                    status_forwards_out <= pipeline_status::ILLEGAL_INSTRUCTION;
                end else if (decoded_instr.op == op::ECALL) begin
                    status_forwards_out <= pipeline_status::ECALL;
                end else if (decoded_instr.op == op::EBREAK) begin
                    status_forwards_out <= pipeline_status::EBREAK;
                end else begin
                    status_forwards_out <= pipeline_status::VALID;
                end
            end
        end
    end

endmodule
