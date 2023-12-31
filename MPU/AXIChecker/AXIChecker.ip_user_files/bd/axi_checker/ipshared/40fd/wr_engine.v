/*
 * Original Source: Copyright 2019 - 2020, RC4ML, Zhejiang University, https://github.com/RC4ML/Shuhai
 * Modifications: Austin York, University of California, Davis
 *
 * This hardware operator is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

//=====================================
//             Write Engine
//=====================================
module wr_engine #(
    parameter ENGINE_ID   = 0,
    parameter ADDR_WIDTH  = 33,                   // 8G-->33 bits
    parameter DATA_WIDTH  = 256,                  // 256 HBM & 512 DDR4
    parameter ID_WIDTH    = 6,
    parameter LEN_WIDTH   = 8
)(
    input                         clk,            // should be 450MHz
    input                         resetn,          // negative reset

    //-------------------Begin/Stop Write--------------------//
    input                         start,
    input      [ADDR_WIDTH - 1:0] write_addr,
    input       [LEN_WIDTH - 1:0] burst,
    input      [DATA_WIDTH - 1:0] write_data,
    output                        end_of_write,

    //----------------------AXI Signals----------------------//
    // Write Address (Output) 
    output                        m_axi_AWVALID,  // wr address valid
    output reg [ADDR_WIDTH - 1:0] m_axi_AWADDR,   // wr byte address
    output reg   [ID_WIDTH - 1:0] m_axi_AWID,     // wr address id
    output reg  [LEN_WIDTH - 1:0] m_axi_AWLEN,    // wr burst = awlen+1
    output reg              [2:0] m_axi_AWSIZE,   // wr 3'b101, 32B
    output reg              [1:0] m_axi_AWBURST,  // wr burst type: 01 (INC), 00 (FIXED)
    output reg              [1:0] m_axi_AWLOCK,   // wr no
    output reg              [3:0] m_axi_AWCACHE,  // wr no
    output reg              [2:0] m_axi_AWPROT,   // wr no
    output reg              [3:0] m_axi_AWQOS,    // wr no
    output reg              [3:0] m_axi_AWREGION, // wr no
    input                         m_axi_AWREADY,  // wr ready to accept address.

    // Write Data (Output)
    output                        m_axi_WVALID,   // wr data valid
    output reg [DATA_WIDTH - 1:0] m_axi_WDATA,    // wr data
    output reg [DATA_WIDTH/8-1:0] m_axi_WSTRB,    // wr data strob
    output                        m_axi_WLAST,    // wr last beat in a burst
    output reg   [ID_WIDTH - 1:0] m_axi_WID,      // wr data id
    input                         m_axi_WREADY,   // wr ready to accept data

    // Write Response (Input)
    input                         m_axi_BVALID,   // wr response valid
    input                   [1:0] m_axi_BRESP,    // wr response status
    input        [ID_WIDTH - 1:0] m_axi_BID,      // wr response id
    output                        m_axi_BREADY    // wr response ready
);

reg started;
wire resp;
reg guard_AWVALID, guard_WVALID, guard_BREADY, guard_WLAST;
reg [7:0] burst_count;
wire [7:0] next_burst_count;

always @(posedge clk)
begin
if (~resetn)
    started   <= 1'b0;
else
    started   <= start;
end

//----------------------Parameters----------------------//
always @(posedge clk)
begin
    m_axi_AWID     <= {ID_WIDTH{1'b0}};
    m_axi_AWLEN    <= burst; // 1-1 length, 1 beat
    m_axi_AWSIZE   <= (DATA_WIDTH == 64)? 3'b011: ((DATA_WIDTH == 128)? 3'b100: ((DATA_WIDTH == 256)? 3'b101: 3'b110)); // 64, 128, 256, or 512 bits. Default == 512.
    m_axi_AWBURST  <= 2'b01;   // INC (01), FIXED (00)
    m_axi_AWLOCK   <= 2'b00;   // Normal memory operation
    m_axi_AWCACHE  <= 4'b0000; // 4'b0011; // Normal, non-cacheable, modifiable, bufferable (Xilinx recommends)
    m_axi_AWPROT   <= 3'b010;  // 3'b000;  // Normal, secure, data
    m_axi_AWQOS    <= 4'b0000; // Not participating in any Qos schem, a higher value indicates a higher priority transaction
    m_axi_AWREGION <= 4'b0000; // Region indicator, default to 0
    m_axi_WDATA    <= write_data; // wr data
    m_axi_AWADDR   <= write_addr; // wr address
    m_axi_WSTRB    <= {(DATA_WIDTH/8){1'b1}}; // wr select by byte
    m_axi_WID      <= {ID_WIDTH{1'b0}}; // wr id
end

assign end_of_write  = m_axi_WREADY && m_axi_WVALID;
assign m_axi_BREADY  = guard_BREADY;  // Always ready
assign m_axi_AWVALID = guard_AWVALID; // wr address valid
assign m_axi_WLAST   = guard_WLAST;   // wlast is 1 for the last beat.
assign m_axi_WVALID  = guard_WVALID;  // wr data valid
assign resp          = (m_axi_BRESP==2'b00 || m_axi_BRESP==2'b01) ? 1'b1:1'b0; // 00/01 OKAY, 10/11 ERRORS

assign next_burst_count = burst_count + 1'b1;
//----------------------FSM For Addr & Data----------------------//
reg [2:0] state;
localparam [2:0]
    WR_IDLE     = 3'b000,
    WR_ADDR     = 3'b001,
    WR_DATA     = 3'b010,
    WR_RESP     = 3'b011,
    WR_RETRY    = 3'b100,
    WR_END      = 3'b101;

always @(posedge clk)
begin
if (~resetn) begin
    state         <= WR_IDLE;
    guard_AWVALID <= 1'b0;
    guard_WVALID  <= 1'b0;
    guard_BREADY  <= 1'b0;
    guard_WLAST   <= 1'b0;
    burst_count   <= 4'b0000;
    end
else
begin

    case (state)
        
        WR_IDLE:
        begin
            guard_AWVALID <= 1'b0;
            guard_WVALID  <= 1'b0;
            guard_BREADY  <= 1'b0;
            guard_WLAST   <= 1'b0;
            if (started)
                state     <= WR_ADDR;
        end
        
        WR_ADDR: // Write Address
        begin
            if (m_axi_AWREADY && m_axi_AWVALID)
            begin
                guard_AWVALID  <= 1'b0;
                if (burst==8'd0) guard_WLAST <= 1'b1;
                state          <= WR_DATA;
            end
            else guard_AWVALID <= 1'b1;
        end
        
        WR_DATA: // Write Data
        begin
            if (m_axi_WREADY && m_axi_WVALID)
            begin
                burst_count  <= next_burst_count;
            end
            
            if (m_axi_WREADY && m_axi_WVALID && (next_burst_count==burst))
            begin
                guard_WLAST  <= 1'b1;
            end
            
            if (m_axi_WLAST && m_axi_WREADY && m_axi_WVALID)
            begin
                guard_WVALID <= 1'b0;
                guard_WLAST  <= 1'b0;
                state        <= WR_RESP;
            end
            else guard_WVALID   <= 1'b1;
        end
        
        WR_RESP: // Check Response
        begin
            burst_count    <= 4'd0000;
            
            if (m_axi_BVALID && resp) // Write successful
            begin
                guard_BREADY   <= 1'b1;
                state          <= WR_END;
            end
            else if (m_axi_BVALID && ~resp) // Write failed
            begin
                guard_BREADY   <= 1'b1;
                state          <= WR_RETRY;
            end
        end

        WR_RETRY: // Write retry, delay 1 cycle
        begin
            guard_BREADY       <= 1'b0;
            state              <= WR_ADDR;
        end
        
        WR_END:  // End Write
        begin
            guard_BREADY       <= 1'b0;
            state              <= WR_IDLE;
        end
        
        default: state         <= WR_IDLE;
    endcase
end
end
endmodule
