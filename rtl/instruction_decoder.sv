/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: instruction_decoder.sv
 */

module instruction_decoder (
    input  logic [31:0]   instruction_in,
    output instruction::t instruction_out
);

    // --- 1. FIELD EXTRACTION ---
    // We pre-extract common fields to make the case statements more readable.
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;
    logic [4:0]  rd, rs1, rs2;
    logic [11:0] csr_idx;

    assign opcode  = instruction_in[6:0];
    assign funct3  = instruction_in[14:12];
    assign funct7  = instruction_in[31:25];
    assign rd      = instruction_in[11:7];
    assign rs1     = instruction_in[19:15];
    assign rs2     = instruction_in[24:20];
    assign csr_idx = instruction_in[31:20];

    // --- 2. IMMEDIATE GENERATION ---
    // We generate all possible immediate formats combinationally.
    // The decoder will pick the right one based on the opcode.
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

    assign imm_i = {{20{instruction_in[31]}}, instruction_in[31:20]};
    assign imm_s = {{20{instruction_in[31]}}, instruction_in[31:25], instruction_in[11:7]};
    assign imm_b = {{19{instruction_in[31]}}, instruction_in[31], instruction_in[7], instruction_in[30:25], instruction_in[11:8], 1'b0};
    assign imm_u = {instruction_in[31:12], 12'b0};
    assign imm_j = {{11{instruction_in[31]}}, instruction_in[31], instruction_in[19:12], instruction_in[20], instruction_in[30:21], 1'b0};

    // --- 3. MAIN DECODING LOGIC ---
    always_comb begin
        // Default values: Set to ILLEGAL and zero out fields to avoid latches.
        instruction_out.op          = op::ILLEGAL;
        instruction_out.rd_address  = rd;
        instruction_out.rs1_address = rs1;
        instruction_out.rs2_address = rs2;
        instruction_out.csr         = csr::MSCRATCH; // Default scratchpad
        instruction_out.immediate   = 32'b0;

        casez (instruction_in)
            // U-Type: LUI, AUIPC
            {25'b?, 7'b0110111}: begin 
                instruction_out.op = op::LUI;   
                instruction_out.immediate = imm_u; 
                instruction_out.rs1_address = 0; 
                instruction_out.rs2_address = 0; 
            end
            {25'b?, 7'b0010111}: begin 
                instruction_out.op = op::AUIPC; 
                instruction_out.immediate = imm_u; 
                instruction_out.rs1_address = 0; 
                instruction_out.rs2_address = 0; 
            end

            // J-Type: JAL
            {25'b?, 7'b1101111}: begin 
                instruction_out.op = op::JAL;   
                instruction_out.immediate = imm_j; 
                instruction_out.rs1_address = 0; 
                instruction_out.rs2_address = 0; 
            end

            // I-Type (JALR, Loads, ALU-Imm)
            {12'b?, 5'b?, 3'b000, 5'b?, 7'b1100111}: begin instruction_out.op = op::JALR;  instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b000, 5'b?, 7'b0000011}: begin instruction_out.op = op::LB;    instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b001, 5'b?, 7'b0000011}: begin instruction_out.op = op::LH;    instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b010, 5'b?, 7'b0000011}: begin instruction_out.op = op::LW;    instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b100, 5'b?, 7'b0000011}: begin instruction_out.op = op::LBU;   instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b101, 5'b?, 7'b0000011}: begin instruction_out.op = op::LHU;   instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            
            {12'b?, 5'b?, 3'b000, 5'b?, 7'b0010011}: begin instruction_out.op = op::ADDI;  instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b010, 5'b?, 7'b0010011}: begin instruction_out.op = op::SLTI;  instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b011, 5'b?, 7'b0010011}: begin instruction_out.op = op::SLTIU; instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b100, 5'b?, 7'b0010011}: begin instruction_out.op = op::XORI;  instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b110, 5'b?, 7'b0010011}: begin instruction_out.op = op::ORI;   instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            {12'b?, 5'b?, 3'b111, 5'b?, 7'b0010011}: begin instruction_out.op = op::ANDI;  instruction_out.immediate = imm_i; instruction_out.rs2_address = 0; end
            
            // Shift-Imm (Special I-Type using funct7)
            {7'b0000000, 5'b?, 5'b?, 3'b001, 5'b?, 7'b0010011}: begin instruction_out.op = op::SLLI; instruction_out.immediate = {27'b0, rs2}; instruction_out.rs2_address = 0; end
            {7'b0000000, 5'b?, 5'b?, 3'b101, 5'b?, 7'b0010011}: begin instruction_out.op = op::SRLI; instruction_out.immediate = {27'b0, rs2}; instruction_out.rs2_address = 0; end
            {7'b0100000, 5'b?, 5'b?, 3'b101, 5'b?, 7'b0010011}: begin instruction_out.op = op::SRAI; instruction_out.immediate = {27'b0, rs2}; instruction_out.rs2_address = 0; end

            // S-Type: Store
            {7'b?, 5'b?, 5'b?, 3'b000, 5'b?, 7'b0100011}: begin instruction_out.op = op::SB; instruction_out.immediate = imm_s; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b001, 5'b?, 7'b0100011}: begin instruction_out.op = op::SH; instruction_out.immediate = imm_s; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b010, 5'b?, 7'b0100011}: begin instruction_out.op = op::SW; instruction_out.immediate = imm_s; instruction_out.rd_address = 0; end

            // B-Type: Branches
            {7'b?, 5'b?, 5'b?, 3'b000, 5'b?, 7'b1100011}: begin instruction_out.op = op::BEQ;  instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b001, 5'b?, 7'b1100011}: begin instruction_out.op = op::BNE;  instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b100, 5'b?, 7'b1100011}: begin instruction_out.op = op::BLT;  instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b101, 5'b?, 7'b1100011}: begin instruction_out.op = op::BGE;  instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b110, 5'b?, 7'b1100011}: begin instruction_out.op = op::BLTU; instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end
            {7'b?, 5'b?, 5'b?, 3'b111, 5'b?, 7'b1100011}: begin instruction_out.op = op::BGEU; instruction_out.immediate = imm_b; instruction_out.rd_address = 0; end

            // R-Type: ALU-Reg
            {7'b0000000, 5'b?, 5'b?, 3'b000, 5'b?, 7'b0110011}: instruction_out.op = op::ADD;
            {7'b0100000, 5'b?, 5'b?, 3'b000, 5'b?, 7'b0110011}: instruction_out.op = op::SUB;
            {7'b0000000, 5'b?, 5'b?, 3'b001, 5'b?, 7'b0110011}: instruction_out.op = op::SLL;
            {7'b0000000, 5'b?, 5'b?, 3'b010, 5'b?, 7'b0110011}: instruction_out.op = op::SLT;
            {7'b0000000, 5'b?, 5'b?, 3'b011, 5'b?, 7'b0110011}: instruction_out.op = op::SLTU;
            {7'b0000000, 5'b?, 5'b?, 3'b100, 5'b?, 7'b0110011}: instruction_out.op = op::XOR;
            {7'b0000000, 5'b?, 5'b?, 3'b101, 5'b?, 7'b0110011}: instruction_out.op = op::SRL;
            {7'b0100000, 5'b?, 5'b?, 3'b101, 5'b?, 7'b0110011}: instruction_out.op = op::SRA;
            {7'b0000000, 5'b?, 5'b?, 3'b110, 5'b?, 7'b0110011}: instruction_out.op = op::OR;
            {7'b0000000, 5'b?, 5'b?, 3'b111, 5'b?, 7'b0110011}: instruction_out.op = op::AND;

            // FENCE & SYSTEM
            {12'b?, 5'b?, 3'b000, 5'b?, 7'b0001111}: begin instruction_out.op = op::FENCE;   instruction_out.rd_address = 0; end
            {12'b?, 5'b?, 3'b001, 5'b?, 7'b0001111}: begin instruction_out.op = op::FENCE_I; instruction_out.rd_address = 0; end

            32'h00000073: instruction_out.op = op::ECALL;
            32'h00100073: instruction_out.op = op::EBREAK;
            32'h30200073: instruction_out.op = op::MRET;
            32'h10500073: instruction_out.op = op::WFI;

            // CSR Instructions
            {12'b?, 5'b?, 3'b001, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRW;  instruction_out.csr = csr::t'(csr_idx); end
            {12'b?, 5'b?, 3'b010, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRS;  instruction_out.csr = csr::t'(csr_idx); end
            {12'b?, 5'b?, 3'b011, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRC;  instruction_out.csr = csr::t'(csr_idx); end
            {12'b?, 5'b?, 3'b101, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRWI; instruction_out.csr = csr::t'(csr_idx); instruction_out.immediate = {27'b0, rs1}; instruction_out.rs1_address = 0; end
            {12'b?, 5'b?, 3'b110, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRSI; instruction_out.csr = csr::t'(csr_idx); instruction_out.immediate = {27'b0, rs1}; instruction_out.rs1_address = 0; end
            {12'b?, 5'b?, 3'b111, 5'b?, 7'b1110011}: begin instruction_out.op = op::CSRRCI; instruction_out.csr = csr::t'(csr_idx); instruction_out.immediate = {27'b0, rs1}; instruction_out.rs1_address = 0; end

            default: instruction_out.op = op::ILLEGAL;
        endcase
    end

endmodule
