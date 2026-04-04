/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: writeback_stage.sv
 */

module writeback_stage (
    input logic clk,
    input logic rst,

    // Inputs from Memory Stage
    input logic [31:0]   source_data_in,           // Data for CSR writes
    input logic [31:0]   rd_data_in,               // Result from ALU or Load
    input instruction::t instruction_in,           // Decoded instruction
    input logic [31:0]   program_counter_in,       // PC of the current instruction
    input logic [31:0]   next_program_counter_in,  // PC calculated by Execute stage

    // Interrupt signals
    input logic external_interrupt_in,
    input logic timer_interrupt_in,

    // Outputs
    output forwarding::t forwarding_out,           // Data being written back to RF

    // Pipeline control
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::backwards_t status_backwards_out,
    output logic [31:0]                 jump_address_backwards_out
);

    // =========================================================================
    // 1. Hardware CSR Registers (State)
    // =========================================================================
    logic [31:0] csr_mstatus;
    logic [31:0] csr_mtvec;
    logic [31:0] csr_mie;
    logic [31:0] csr_mscratch;
    logic [31:0] csr_mepc;
    logic [31:0] csr_mcause;
    logic [63:0] csr_mcycle;
    logic [63:0] csr_minstret;
    
    // MIP (Machine Interrupt Pending) is driven directly by the external pins
    // Bit 11: MEIP (External), Bit 7: MTIP (Timer)
    logic [31:0] csr_mip;
    assign csr_mip = {20'b0, external_interrupt_in, 3'b0, timer_interrupt_in, 7'b0};

    // =========================================================================
    // 2. Instruction Decoding & CSR Read
    // =========================================================================
    logic is_csr_instr, is_mret, is_fence_i;
    logic [31:0] csr_read_data;

    assign is_csr_instr = (instruction_in.op inside {op::CSRRW, op::CSRRS, op::CSRRC, op::CSRRWI, op::CSRRSI, op::CSRRCI});
    assign is_mret      = (instruction_in.op == op::MRET);
    assign is_fence_i   = (instruction_in.op == op::FENCE_I);

    always_comb begin
        case (instruction_in.csr)
            csr::MSTATUS:   csr_read_data = csr_mstatus;
            csr::MTVEC:     csr_read_data = csr_mtvec;
            csr::MIP:       csr_read_data = csr_mip;
            csr::MIE:       csr_read_data = csr_mie;
            csr::MCYCLE:    csr_read_data = csr_mcycle[31:0];
            csr::MCYCLEH:   csr_read_data = csr_mcycle[63:32];
            csr::MINSTRET:  csr_read_data = csr_minstret[31:0];
            csr::MINSTRETH: csr_read_data = csr_minstret[63:32];
            csr::MSCRATCH:  csr_read_data = csr_mscratch;
            csr::MEPC:      csr_read_data = csr_mepc;
            csr::MCAUSE:    csr_read_data = csr_mcause;
            default:        csr_read_data = 32'b0;
        endcase
    end

    // =========================================================================
    // 3. Exception & Interrupt Evaluation (Zero-Delay)
    // =========================================================================
    logic is_exception, is_interrupt;
    logic should_trap;
    logic [31:0] trap_cause;

    // Check if the memory stage handed us a fault/exception
    assign is_exception = (status_forwards_in inside {
        pipeline_status::FETCH_MISALIGNED, pipeline_status::FETCH_FAULT,
        pipeline_status::ILLEGAL_INSTRUCTION, pipeline_status::EBREAK,
        pipeline_status::LOAD_MISALIGNED, pipeline_status::LOAD_FAULT,
        pipeline_status::STORE_MISALIGNED, pipeline_status::STORE_FAULT,
        pipeline_status::ECALL
    });

    // An interrupt fires if: Global Interrupts Enabled (MIE=bit 3) AND specific interrupt is Enabled AND Pending
    assign is_interrupt = csr_mstatus[3] && (
        (csr_mie[11] && csr_mip[11]) || // External
        (csr_mie[7]  && csr_mip[7])     // Timer
    );

    // We trap if an exception arrived OR an interrupt fired during a valid cycle
    assign should_trap = is_exception || ((status_forwards_in == pipeline_status::VALID) && is_interrupt);

    // Determine the exact cause code to store in MCAUSE
    always_comb begin
        if (is_interrupt && !is_exception) begin
            // MSB = 1 for Interrupts
            trap_cause = (csr_mie[11] && csr_mip[11]) ? {1'b1, 31'd11} : {1'b1, 31'd7};
        end else begin
            // MSB = 0 for Exceptions
            case (status_forwards_in)
                pipeline_status::FETCH_MISALIGNED:    trap_cause = {1'b0, 31'd0};
                pipeline_status::FETCH_FAULT:         trap_cause = {1'b0, 31'd1};
                pipeline_status::ILLEGAL_INSTRUCTION: trap_cause = {1'b0, 31'd2};
                pipeline_status::EBREAK:              trap_cause = {1'b0, 31'd3};
                pipeline_status::LOAD_MISALIGNED:     trap_cause = {1'b0, 31'd4};
                pipeline_status::LOAD_FAULT:          trap_cause = {1'b0, 31'd5};
                pipeline_status::STORE_MISALIGNED:    trap_cause = {1'b0, 31'd6};
                pipeline_status::STORE_FAULT:         trap_cause = {1'b0, 31'd7};
                pipeline_status::ECALL:               trap_cause = {1'b0, 31'd11};
                default:                              trap_cause = {1'b0, 31'd2}; 
            endcase
        end
    end

    // =========================================================================
    // 4. CSR Write Calculation (What the instruction WANTS to write)
    // =========================================================================
    logic [31:0] csr_write_data;

    always_comb begin
        case (instruction_in.op)
            op::CSRRW:  csr_write_data = source_data_in;
            op::CSRRS:  csr_write_data = csr_read_data | source_data_in;
            op::CSRRC:  csr_write_data = csr_read_data & ~source_data_in;
            op::CSRRWI: csr_write_data = {27'b0, instruction_in.immediate[4:0]};
            op::CSRRSI: csr_write_data = csr_read_data | {27'b0, instruction_in.immediate[4:0]};
            op::CSRRCI: csr_write_data = csr_read_data & ~{27'b0, instruction_in.immediate[4:0]};
            default:    csr_write_data = 32'b0;
        endcase
    end

    // =========================================================================
    // 5. Forwarding / Register File Writeback
    // =========================================================================
    // We write to the Register File if the pipeline is VALID, we aren't trapping, 
    // and the destination register isn't x0.
    logic write_to_rf;
    assign write_to_rf = (status_forwards_in == pipeline_status::VALID) && !should_trap && (instruction_in.rd_address != 5'b0);

    assign forwarding_out.address    = instruction_in.rd_address;
    assign forwarding_out.data       = is_csr_instr ? csr_read_data : rd_data_in;
    assign forwarding_out.data_valid = write_to_rf;

    // =========================================================================
    // 6. Pipeline Control (Backwards Jump Logic)
    // =========================================================================
    // The Writeback stage never stalls. It only issues JUMPs for traps, MRET, or FENCE.I
    always_comb begin
        if (should_trap || (status_forwards_in == pipeline_status::VALID && (is_mret || is_fence_i))) begin
            status_backwards_out = pipeline_status::JUMP;
        end else begin
            status_backwards_out = pipeline_status::READY;
        end

        // Where are we jumping to?
        if (should_trap) begin
            jump_address_backwards_out = csr_mtvec;
        end else if (is_mret) begin
            jump_address_backwards_out = csr_mepc;
        end else if (is_fence_i) begin
            jump_address_backwards_out = next_program_counter_in;
        end else begin
            jump_address_backwards_out = 32'b0;
        end
    end

    // =========================================================================
    // 7. Synchronous Commit (The Final Latch)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            csr_mstatus  <= 32'b0;
            csr_mtvec    <= 32'b0;
            csr_mie      <= 32'b0;
            csr_mscratch <= 32'b0;
            csr_mepc     <= 32'b0;
            csr_mcause   <= 32'b0;
            csr_mcycle   <= 64'b0;
            csr_minstret <= 64'b0;
        end else begin
            // 1. Unconditional Cycle Counter
            csr_mcycle <= csr_mcycle + 1;

            if (should_trap) begin
                // --- TRAP OVERRIDES ---
                csr_mcause <= trap_cause;
                // If it's an interrupt, save next PC. If it's an exception, save faulting PC.
                csr_mepc   <= (is_interrupt && !is_exception) ? next_program_counter_in : program_counter_in;
                // Save MIE into MPIE (bit 7), then disable MIE (bit 3)
                csr_mstatus[7] <= csr_mstatus[3];
                csr_mstatus[3] <= 1'b0;

            end else if (status_forwards_in == pipeline_status::VALID) begin
                // 2. Successful Instruction Counter
                csr_minstret <= csr_minstret + 1;

                if (is_mret) begin
                    // --- MRET OVERRIDES ---
                    // Restore MPIE into MIE, set MPIE to 1
                    csr_mstatus[3] <= csr_mstatus[7];
                    csr_mstatus[7] <= 1'b1;

                end else if (is_csr_instr) begin
                    // --- NORMAL CSR WRITES ---
                    case (instruction_in.csr)
                        csr::MSTATUS:   csr_mstatus  <= csr_write_data;
                        csr::MTVEC:     csr_mtvec    <= {csr_write_data[31:2], 2'b00}; // Force alignment
                        csr::MIE:       csr_mie      <= csr_write_data;
                        csr::MCYCLE:    csr_mcycle[31:0]  <= csr_write_data;
                        csr::MCYCLEH:   csr_mcycle[63:32] <= csr_write_data;
                        csr::MINSTRET:  csr_minstret[31:0]  <= csr_write_data;
                        csr::MINSTRETH: csr_minstret[63:32] <= csr_write_data;
                        csr::MSCRATCH:  csr_mscratch <= csr_write_data;
                        csr::MEPC:      csr_mepc     <= {csr_write_data[31:2], 2'b00}; // Force alignment
                        csr::MCAUSE:    csr_mcause   <= csr_write_data;
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
