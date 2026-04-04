/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: execute_stage.sv
 */

module execute_stage (
    input logic clk,
    input logic rst,

    // Inputs
    input logic [31:0]   rs1_data_in,
    input logic [31:0]   rs2_data_in,
    input instruction::t instruction_in,
    input logic [31:0]   program_counter_in,

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
    // 1. ALU Operand MUXing
    // =========================================================================
    logic [31:0] alu_in_a;
    logic [31:0] alu_in_b;

    always_comb begin
        // Select Input A (Default to RS1)
        if (instruction_in.op == op::AUIPC || instruction_in.op == op::JAL) begin
            alu_in_a = program_counter_in;
        end else begin
            alu_in_a = rs1_data_in;
        end

        // Select Input B (Default to RS2)
        if (instruction_in.op inside {
            op::ADDI, op::SLTI, op::SLTIU, op::XORI, op::ORI, op::ANDI,
            op::SLLI, op::SRLI, op::SRAI,
            op::LB, op::LH, op::LW, op::LBU, op::LHU, op::SB, op::SH, op::SW,
            op::JALR, op::JAL, op::AUIPC
        }) begin
            alu_in_b = instruction_in.immediate;
        end else begin
            alu_in_b = rs2_data_in;
        end
    end

    // =========================================================================
    // 2. The ALU & Branch Logic
    // =========================================================================
    logic [31:0] alu_result;
    logic        branch_taken;
    logic [31:0] jump_target;

    always_comb begin
        // Default values
        alu_result = 32'b0;
        branch_taken = 1'b0;

        case (instruction_in.op)
            // Arithmetic & Memory Addresses
            op::ADD, op::ADDI, op::AUIPC, op::LB, op::LH, op::LW, 
            op::LBU, op::LHU, op::SB, op::SH, op::SW: 
                alu_result = alu_in_a + alu_in_b;
            op::SUB:  
                alu_result = alu_in_a - alu_in_b;
            
            // Logical
            op::XOR, op::XORI: alu_result = alu_in_a ^ alu_in_b;
            op::OR,  op::ORI:  alu_result = alu_in_a | alu_in_b;
            op::AND, op::ANDI: alu_result = alu_in_a & alu_in_b;
            
            // Shifts (Only use bottom 5 bits of B for 32-bit shifts)
            op::SLL, op::SLLI: alu_result = alu_in_a << alu_in_b[4:0];
            op::SRL, op::SRLI: alu_result = alu_in_a >> alu_in_b[4:0];
            op::SRA, op::SRAI: alu_result = $signed(alu_in_a) >>> alu_in_b[4:0];

            // Set Less Than
            op::SLT, op::SLTI:   alu_result = {31'b0, ($signed(alu_in_a) < $signed(alu_in_b))};
            op::SLTU, op::SLTIU: alu_result = {31'b0, (alu_in_a < alu_in_b)};

            // Branch Evaluations
            op::BEQ:  branch_taken = (rs1_data_in == rs2_data_in);
            op::BNE:  branch_taken = (rs1_data_in != rs2_data_in);
            op::BLT:  branch_taken = ($signed(rs1_data_in) < $signed(rs2_data_in));
            op::BGE:  branch_taken = ($signed(rs1_data_in) >= $signed(rs2_data_in));
            op::BLTU: branch_taken = (rs1_data_in < rs2_data_in);
            op::BGEU: branch_taken = (rs1_data_in >= rs2_data_in);
            
            default: alu_result = 32'b0;
        endcase

        // Calculate Target Address for Branches and Jumps
        if (instruction_in.op == op::JALR) begin
            jump_target = (rs1_data_in + instruction_in.immediate) & ~32'h1; // Clear LSB
        end else begin
            jump_target = program_counter_in + instruction_in.immediate; // JAL and Branches
        end
    end

    // =========================================================================
    // 3. Result Formatting & Forwarding
    // =========================================================================
    logic [31:0] rd_data_next;
    logic [31:0] source_data_next;
    logic        is_jump;

    assign is_jump = (instruction_in.op == op::JAL || instruction_in.op == op::JALR);

    always_comb begin
        // What gets written to the Destination Register (rd)?
        if (instruction_in.op == op::LUI) begin
            rd_data_next = instruction_in.immediate;
        end else if (is_jump) begin
            rd_data_next = program_counter_in + 4; // Return address for jumps
        end else begin
            rd_data_next = alu_result;
        end

        // What gets passed as Source Data? (Used for Memory Stores & CSRs)
        if (instruction_in.op inside {op::CSRRW, op::CSRRS, op::CSRRC}) begin
            source_data_next = rs1_data_in;
        end else if (instruction_in.op inside {op::CSRRWI, op::CSRRSI, op::CSRRCI}) begin
            source_data_next = instruction_in.immediate;
        end else begin
            source_data_next = rs2_data_in; // Used for SB, SH, SW
        end

        // Combinatorial Forwarding Output
        forwarding_out.address = (status_forwards_in == pipeline_status::VALID) ? instruction_in.rd_address : 5'b0;
        forwarding_out.data = rd_data_next;
        // Do not forward memory loads (they aren't ready yet) or illegal instructions
        forwarding_out.data_valid = (status_forwards_in == pipeline_status::VALID) && 
                                    (instruction_in.rd_address != 5'b0) &&
                                    !(instruction_in.op inside {op::LB, op::LH, op::LW, op::LBU, op::LHU});
    end

    // =========================================================================
    // 4. Pipeline Status Routing
    // =========================================================================
    always_comb begin
        // Route JUMPS upstream to Fetch
        if (status_backwards_in == pipeline_status::JUMP) begin
            status_backwards_out = pipeline_status::JUMP;
            jump_address_backwards_out = jump_address_backwards_in;
        end else if ((is_jump || branch_taken) && status_forwards_in == pipeline_status::VALID) begin
            status_backwards_out = pipeline_status::JUMP;
            jump_address_backwards_out = jump_target;
        end else begin
            status_backwards_out = status_backwards_in; // Pass STALL or READY
            jump_address_backwards_out = 32'b0;
        end
    end

    // =========================================================================
    // 5. Synchronous Pipeline Registers
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            status_forwards_out          <= pipeline_status::BUBBLE;
            instruction_reg_out          <= '0;
            program_counter_reg_out      <= constants::RESET_ADDRESS;
            next_program_counter_reg_out <= constants::RESET_ADDRESS;
            rd_data_reg_out              <= 32'b0;
            source_data_reg_out          <= 32'b0;
        end else begin
            if (status_backwards_in == pipeline_status::JUMP) begin
                // Flush this stage if a downstream jump happened
                status_forwards_out <= pipeline_status::BUBBLE;
            end else if (status_backwards_in == pipeline_status::STALL) begin
                // Hold state (do nothing to the registers)
            end else begin
                // Normal execution: pass data to the Memory stage
                status_forwards_out          <= status_forwards_in;
                instruction_reg_out          <= instruction_in;
                program_counter_reg_out      <= program_counter_in;
                rd_data_reg_out              <= rd_data_next;
                source_data_reg_out          <= source_data_next;

                // Calculate next PC for tracking purposes
                if (is_jump || branch_taken) begin
                    next_program_counter_reg_out <= jump_target;
                end else begin
                    next_program_counter_reg_out <= program_counter_in + 4;
                end
                
                // Catch Misaligned Jumps (must be multiples of 4 bytes)
                if ((is_jump || branch_taken) && jump_target[1:0] != 2'b00 && status_forwards_in == pipeline_status::VALID) begin
                    status_forwards_out <= pipeline_status::FETCH_MISALIGNED;
                end
            end
        end
    end

endmodule
