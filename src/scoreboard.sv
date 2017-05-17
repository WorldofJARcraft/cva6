// Author: Florian Zaruba, ETH Zurich
// Date: 08.04.2017
// Description: Scoreboard - keeps track of all decoded, issued and committed instructions
//
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Bug fixes and contributions will eventually be released under the
// SolderPad open hardware license in the context of the PULP platform
// (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
// University of Bologna.
//

import ariane_pkg::*;

module scoreboard #(
    parameter int  NR_ENTRIES  = 8,
    parameter int  NR_WB_PORTS = 1,
    parameter type dtype       = scoreboard_entry
    )
    (
    input  logic                                      clk_i,    // Clock
    input  logic                                      rst_ni,   // Asynchronous reset active low
    output logic                                      full_o,   // We can't take anymore data
    input  logic                                      flush_i,  // flush whole scoreboard
    input  logic                                      flush_unissued_instr_i,
    // list of clobbered registers to issue stage
    output fu_t [31:0]                                rd_clobber_o,

    // regfile like interface to operand read stage
    input  logic [4:0]                                rs1_i,
    output logic [63:0]                               rs1_o,
    output logic                                      rs1_valid_o,

    input  logic [4:0]                                rs2_i,
    output logic [63:0]                               rs2_o,
    output logic                                      rs2_valid_o,

    // advertise instruction to commit stage, if commit_ack_i is asserted advance the commit pointer
    output dtype                                      commit_instr_o,
    input  logic                                      commit_ack_i,

    // instruction to put on top of scoreboard e.g.   : top pointer
    // we can always put this instruction to the to   p unless we signal with asserted full_o
    input  dtype                                      decoded_instr_i,
    input  logic                                      decoded_instr_valid_i,
    output logic                                      decoded_instr_ack_o,

    // instruction to issue logic, if issue_instr_valid and issue_ready is asserted, advance the issue pointer
    output dtype                                      issue_instr_o,
    output logic                                      issue_instr_valid_o,
    input  logic                                      issue_ack_i,

    // write-back port
    input logic [NR_WB_PORTS-1:0][TRANS_ID_BITS-1:0]  trans_id_i,  // transaction ID at which to write the result back
    input logic [NR_WB_PORTS-1:0][63:0]               wdata_i,     // write data in
    input exception [NR_WB_PORTS-1:0]                 ex_i,        // exception from a functional unit (e.g.: ld/st exception, divide by zero)
    input logic [NR_WB_PORTS-1:0]                     wb_valid_i   // data in is valid
);
localparam BITS_ENTRIES      = $clog2(NR_ENTRIES);

dtype [NR_ENTRIES-1:0]         mem_q, mem_n;
logic [BITS_ENTRIES-1:0]       issue_pointer_n, issue_pointer_q, // points to the instruction currently in issue
                               commit_pointer_n, commit_pointer_q, // points to the instruction currently in commit
                               top_pointer_n, top_pointer_q, top_pointer_qq; // points to the top of the scoreboard, an empty slot, top pointer two cycles ago

logic                          pointer_overflow;
logic                          empty;
logic                          reset_condition;
// full and empty signaling: signal that we are not able to take new instructions
// track pointer overflow
// && top_pointer_q >= top_pointer_qq
assign reset_condition  = top_pointer_q == top_pointer_qq;
assign pointer_overflow = (top_pointer_q <= commit_pointer_q && ~reset_condition) ? 1'b1 : 1'b0;
assign full_o           = (reset_condition) ? 1'b0 : (commit_pointer_q == top_pointer_q);
assign empty            = (pointer_overflow) ? 1'b0 : (commit_pointer_q == top_pointer_q);

// rd_clobber output: output currently clobbered destination registers
// but only between commit and issue pointer
// normal case:                                      overflow case:
// ._________________________.                      ._________________________.
// |_________________________|                      |_________________________|
// |_________________________|<- commit pointer     |_________________________|<- issue pointer
// |_________________________|                      |_________________________|<- top pointer
// |_________________________|<- issue pointer      |_________________________|<- commit pointer
// |_________________________|<- top pointer        |_________________________|
//
always_comb begin : clobber_output
    rd_clobber_o = '{default: NONE};
    // excluding issue, the issue pointer points to the instruction which is currently not issued
    // but might be issued as soon as the issue unit acknowledges
    if (commit_pointer_q < issue_pointer_q) begin
        for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
            // non overflowed case, depicted on the left
            if (i[BITS_ENTRIES-1:0] >= commit_pointer_q && i[BITS_ENTRIES-1:0] < issue_pointer_q)
                rd_clobber_o[mem_q[i].rd] = mem_q[i].fu;
        end
    end else if (commit_pointer_q == issue_pointer_q) begin // everything committed
        rd_clobber_o = '{default: NONE};
    end else begin // the issue pointer has overflowed, invert logic, depicted on the right
        for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
            if (i[BITS_ENTRIES-1:0] >= commit_pointer_q || i[BITS_ENTRIES-1:0] < issue_pointer_q)
                rd_clobber_o[mem_q[i].rd] = mem_q[i].fu;
        end
    end
    // the zero register is always free
    rd_clobber_o[0] = NONE;
end
// read operand interface: same logic as register file, including a valid file
always_comb begin : read_operands

    rs1_o       = 64'b0;
    rs2_o       = 64'b0;
    rs1_valid_o = 1'b0;
    rs2_valid_o = 1'b0;

    if (commit_pointer_q < issue_pointer_q) begin
        for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
            if (i[BITS_ENTRIES-1:0] >= commit_pointer_q && i[BITS_ENTRIES-1:0] < issue_pointer_q) begin
                // look at the appropriate fields and look whether there was an
                // instruction that wrote the rd field before, first for RS1 and then for RS2
                if (mem_q[i[BITS_ENTRIES-1:0]].rd == rs1_i) begin
                    rs1_o = mem_q[i].result;
                    rs1_valid_o = mem_q[i].valid;
                // do the same for rs2
                end else if (mem_q[i].rd == rs2_i) begin
                    rs2_o = mem_q[i].result;
                    rs2_valid_o = mem_q[i].valid;
                end
            end
        end
    end else begin // the issue pointer has overflowed, invert logic
        for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
            if (i[BITS_ENTRIES-1:0] >= commit_pointer_q || i[BITS_ENTRIES-1:0] < issue_pointer_q) begin
                // same as above but for the overflowed pointer case
                if (mem_q[i[BITS_ENTRIES-1:0]].rd == rs1_i) begin
                    rs1_o = mem_q[i].result;
                    rs1_valid_o = mem_q[i].valid;
                // do the same for rs2
                end else if (mem_q[i[BITS_ENTRIES-1:0]].rd == rs2_i) begin
                    rs2_o = mem_q[i].result;
                    rs2_valid_o = mem_q[i].valid;
                end
            end
        end
    end

    // provide a direct combinational path from WB a.k.a forwarding
    // make sure that we are not forwarding a result that got an exception
    for (int j = 0; j < NR_WB_PORTS; j++) begin
        if (mem_q[trans_id_i[j]].rd == rs1_i && wb_valid_i[j] && ~ex_i[j].valid) begin
            rs1_o = wdata_i[j];
            rs1_valid_o = wb_valid_i[j];
            break;
        end
        if (mem_q[trans_id_i[j]].rd == rs2_i && wb_valid_i[j] && ~ex_i[j].valid) begin
            rs2_o = wdata_i[j];
            rs2_valid_o = wb_valid_i[j];
            break;
        end
    end

    // make sure we didn't read the zero register
    if (rs1_i == '0)
        rs1_valid_o = 1'b0;
    if (rs2_i == '0)
        rs2_valid_o = 1'b0;
end
// push new decoded instruction: if still empty space push the instruction to the scoreboard
// write-back instruction: update value of RD register in scoreboard
always_comb begin : push_instruction_and_wb
    // default assignment
    top_pointer_n       = top_pointer_q;
    mem_n               = mem_q;
    // acknowledge decoded instruction
    decoded_instr_ack_o = 1'b0;
    // if we are not full we can push a new instruction
    if (~full_o && decoded_instr_valid_i) begin
        mem_n[$unsigned(top_pointer_q)] = decoded_instr_i;
        // label the transaction ID with the current top pointer
        mem_n[$unsigned(top_pointer_q)].trans_id = top_pointer_q;
        top_pointer_n       = top_pointer_q + 1;
        decoded_instr_ack_o = 1'b1;
    end

    // write back:
    // look for the intruction with the given transaction ID and write the result data back
    // also set the valid bit
    for (int j = 0; j < NR_WB_PORTS; j++) begin
        if (wb_valid_i[j]) begin
            for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
                if (mem_q[i].trans_id == trans_id_i[j]) begin
                    mem_n[i].valid  = 1'b1;
                    mem_n[i].result = wdata_i[j];
                    mem_n[i].ex     = ex_i[j];
                end
            end
        end
    end
    // flush all instructions which are not issued, e.g. set the top pointer back to the issue pointer
    // -> everything we decoded so far was garbage
    if (flush_unissued_instr_i) begin
        top_pointer_n = issue_pointer_q;
    end
end

// issue instruction: advance the issue pointer
always_comb begin : issue_instruction


    // provide a combinatorial path in case the scoreboard is empty
    if (top_pointer_q == issue_pointer_q && ~full_o) begin
        issue_instr_o          = decoded_instr_i;
        issue_instr_o.trans_id = issue_pointer_q;
        issue_instr_valid_o    = decoded_instr_valid_i;
    // if not empty go to scoreboard and get the instruction at the issue pointer
    end else begin
        issue_instr_o = mem_q[$unsigned(issue_pointer_q)];
        // we have not reached the top of the buffer
        // issue pointer has overflowed
        if (issue_pointer_q < commit_pointer_q) begin
            if (issue_pointer_q < top_pointer_q)
                issue_instr_valid_o = 1'b1;
            else
                issue_instr_valid_o = 1'b0;
        end else if (issue_pointer_q == commit_pointer_q) begin
            // commit and issue pointer are the same, so we are waiting
            // for instructions to be written back
            issue_instr_valid_o = 1'b0;
        end else begin // issue pointer has not overflowed
            if (pointer_overflow)
                issue_instr_valid_o = 1'b1;
            else if (issue_pointer_q <= top_pointer_q)
                issue_instr_valid_o = 1'b1;
            else
                issue_instr_valid_o = 1'b0;
        end

    end
    // default assignment: issue didn't read
    issue_pointer_n = issue_pointer_q;
    // advance pointer if the issue logic was ready
    if (issue_ack_i) begin
        issue_pointer_n = issue_pointer_q + 1;
    end

    // if we are flushing we should not issue the current instruction
    if (flush_unissued_instr_i)
        issue_instr_valid_o = 1'b0;

end

// commit instruction: remove from scoreboard, advance pointer
always_comb begin: commit_instruction
    commit_pointer_n = commit_pointer_q;
    // we can always safely output the instruction at which the commit pointer points
    // since the scoreboard entry has a valid bit which the commit stage needs to check anyway
    commit_instr_o   = mem_q[commit_pointer_q];
    if (commit_ack_i) begin
        commit_pointer_n = commit_pointer_q + 1;
    end
end

// sequential process
always_ff @(posedge clk_i or negedge rst_ni) begin : sequential
    if(~rst_ni) begin
        issue_pointer_q   <= '{default: 0};
        commit_pointer_q  <= '{default: 0};
        top_pointer_q     <= '{default: 0};
        top_pointer_qq    <= '{default: 0};
        for (int i = 0; i < NR_ENTRIES; i++) begin
            mem_q[i] <= {$bits(scoreboard_entry){1'b0}};
        end
    end else if (flush_i) begin // reset pointers on flush
        // flush signal, e.g.: flush everything we need to backtrack after an exception
        issue_pointer_q   <= '{default: 0};
        commit_pointer_q  <= '{default: 0};
        top_pointer_q     <= '{default: 0};
        top_pointer_qq    <= '{default: 0};
        for (int i = 0; i < NR_ENTRIES; i++) begin
            mem_q[i] <= {$bits(scoreboard_entry){1'b0}};
        end
    end else begin
        issue_pointer_q   <= issue_pointer_n;
        commit_pointer_q  <= commit_pointer_n;
        top_pointer_q     <= top_pointer_n;
        mem_q             <= mem_n;
        if (decoded_instr_valid_i && ~full_o) // only advance if we decoded instruction and we are not full
            if (flush_unissued_instr_i)
                top_pointer_qq    <= top_pointer_n;
            else
                top_pointer_qq    <= top_pointer_q;
    end
end

`ifndef SYNTHESIS
`ifndef verilator
initial begin
    assert (NR_ENTRIES == 2**$clog2(NR_ENTRIES)) else $fatal("Scoreboard size needs to be a power of two.");
end

// assert that zero is never set
assert property (
    @(posedge clk_i) rst_ni |-> (rd_clobber_o[0] == NONE))
    else $error ("RD 0 should not bet set");
// assert that we never acknowledge a commit if the instruction is not valid
assert property (
    @(posedge clk_i) (rst_ni && commit_ack_i |-> commit_instr_o.valid))
    else $error ("Commit acknowledged but instruction is not valid");
// assert that we never give an issue ack signal if the instruction is not valid
assert property (
    @(posedge clk_i) (rst_ni && issue_ack_i |-> issue_instr_valid_o))
    else $error ("Issue acknowledged but instruction is not valid");

// there should never be more than one instruction writing the same destination register (except x0)
// assert strict pointer ordering

// print scoreboard
// initial begin
//         automatic string pointer = "";
//         static integer f = $fopen("scoreboard.txt", "w");

//         forever begin
//             wait(rst_ni == 1'b1);
//             @(posedge clk_i)
//             $fwrite(f, $time);
//             $fwrite(f, "\n");
//             $fwrite(f, "._________________________.\n");
//             for (int i = 0; i < NR_ENTRIES; i++) begin
//                 if (i == commit_pointer_q && i == issue_pointer_q && i == top_pointer_q)
//                     pointer = " <- top, issue, commit pointer";
//                 else if (i == commit_pointer_q && i == issue_pointer_q)
//                     pointer = " <- issue, commit pointer";
//                 else if (i == top_pointer_q && i == issue_pointer_q)
//                     pointer = " <- top, issue pointer";
//                 else if (i == top_pointer_q && i == commit_pointer_q)
//                     pointer = " <- top, commit pointer";
//                 else if (i == top_pointer_q)
//                     pointer = " <- top pointer";
//                 else if (i == commit_pointer_q)
//                     pointer = " <- commit pointer";
//                 else if (i == issue_pointer_q)
//                     pointer = " <- issue pointer";
//                 else
//                     pointer = "";
//                 $fwrite(f, "|_________________________| %s\n", pointer);
//             end
//              $fwrite(f, "\n");
//         end
//         $fclose(f);
// end
`endif
`endif
endmodule