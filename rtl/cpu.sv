/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: cpu.sv
 */

module cpu (
    input logic clk,
    input logic rst,

    wishbone_interface.master memory_fetch_port,
    wishbone_interface.master memory_mem_port,

    input logic external_interrupt_in,
    input logic timer_interrupt_in
);

    // --- INTERCONNECT SIGNALS ---

    // Fetch <-> Decode
    logic [31:0] f2d_instruction;
    logic [31:0] f2d_program_counter;
    pipeline_status::forwards_t f2d_status_forwards;
    pipeline_status::backwards_t d2f_status_backwards;
    logic [31:0] d2f_jump_address;

    // Decode <-> Execute
    instruction::t d2e_instruction;
    logic [31:0] d2e_program_counter;
    logic [31:0] d2e_rs1_data;
    logic [31:0] d2e_rs2_data;
    pipeline_status::forwards_t d2e_status_forwards;
    pipeline_status::backwards_t e2d_status_backwards;
    logic [31:0] e2d_jump_address;

    // Execute <-> Memory
    instruction::t e2m_instruction;
    logic [31:0] e2m_program_counter;
    logic [31:0] e2m_next_pc;
    logic [31:0] e2m_rd_data;
    logic [31:0] e2m_source_data;
    forwarding::t exe_forwarding;
    pipeline_status::forwards_t e2m_status_forwards;
    pipeline_status::backwards_t m2e_status_backwards;
    logic [31:0] m2e_jump_address;

    // Memory <-> Writeback
    instruction::t m2w_instruction;
    logic [31:0] m2w_program_counter;
    logic [31:0] m2w_next_pc;
    logic [31:0] m2w_rd_data;
    logic [31:0] m2w_source_data;
    forwarding::t mem_forwarding;
    pipeline_status::forwards_t m2w_status_forwards;
    pipeline_status::backwards_t w2m_status_backwards;
    logic [31:0] w2m_jump_address;

    // Writeback -> Decode (Forwarding)
    forwarding::t wb_forwarding;

    // --- STAGE INSTANTIATIONS ---

    fetch_stage fetch (
        .clk(clk),
        .rst(rst),
        .wishbone(memory_fetch_port),

        .status_backwards_in(d2f_status_backwards),
        .jump_address_in(d2f_jump_address),

        .instruction_out(f2d_instruction),
        .program_counter_out(f2d_program_counter),
        .status_forwards_out(f2d_status_forwards)
    );

    decode_stage decode (
        .clk(clk),
        .rst(rst),

        .instruction_in(f2d_instruction),
        .program_counter_in(f2d_program_counter),
        .wb_forwarding_in(wb_forwarding),
        .mem_forwarding_in(mem_forwarding),
        .exe_forwarding_in(exe_forwarding),
        .status_forwards_in(f2d_status_forwards),
        .status_backwards_in(e2d_status_backwards),
        .jump_address_in(e2d_jump_address),

        .instruction_out(d2e_instruction),
        .program_counter_out(d2e_program_counter),
        .rs1_data_out(d2e_rs1_data),
        .rs2_data_out(d2e_rs2_data),
        .status_forwards_out(d2e_status_forwards),
        .status_backwards_out(d2f_status_backwards),
        .jump_address_out(d2f_jump_address)
    );

    execute_stage execute (
        .clk(clk),
        .rst(rst),

        .instruction_in(d2e_instruction),
        .program_counter_in(d2e_program_counter),
        .rs1_data_in(d2e_rs1_data),
        .rs2_data_in(d2e_rs2_data),
        .status_forwards_in(d2e_status_forwards),
        .status_backwards_in(m2e_status_backwards),
        .jump_address_in(m2e_jump_address),

        .instruction_out(e2m_instruction),
        .program_counter_out(e2m_program_counter),
        .next_pc_out(e2m_next_pc),
        .rd_data_out(e2m_rd_data),
        .source_data_out(e2m_source_data),
        .forwarding_out(exe_forwarding),
        .status_forwards_out(e2m_status_forwards),
        .status_backwards_out(e2d_status_backwards),
        .jump_address_out(e2d_jump_address)
    );

    memory_stage memory (
        .clk(clk),
        .rst(rst),
        .wishbone(memory_mem_port),

        .instruction_in(e2m_instruction),
        .program_counter_in(e2m_program_counter),
        .next_pc_in(e2m_next_pc),
        .rd_data_in(e2m_rd_data),
        .source_data_in(e2m_source_data),
        .status_forwards_in(e2m_status_forwards),
        .status_backwards_in(w2m_status_backwards),
        .jump_address_in(w2m_jump_address),

        .instruction_out(m2w_instruction),
        .program_counter_out(m2w_program_counter),
        .next_pc_out(m2w_next_pc),
        .rd_data_out(m2w_rd_data),
        .source_data_out(m2w_source_data),
        .forwarding_out(mem_forwarding),
        .status_forwards_out(m2w_status_forwards),
        .status_backwards_out(m2e_status_backwards),
        .jump_address_out(m2e_jump_address)
    );

    writeback_stage writeback (
        .clk(clk),
        .rst(rst),

        .instruction_in(m2w_instruction),
        .program_counter_in(m2w_program_counter),
        .next_pc_in(m2w_next_pc),
        .rd_data_in(m2w_rd_data),
        .source_data_in(m2w_source_data),
        .status_forwards_in(m2w_status_forwards),
        .external_interrupt_in(external_interrupt_in),
        .timer_interrupt_in(timer_interrupt_in),

        .forwarding_out(wb_forwarding),
        .status_backwards_out(w2m_status_backwards),
        .jump_address_out(w2m_jump_address)
    );

endmodule
