// -----------------------------------------------------------------------------
// decoder_tb.cpp — verilog/decoder.sv 的 Verilator 单元测试
//
// 思路：在 C++ 里按 RISC-V 规范独立实现一份参考译码器（立即数用与 RTL 不同
// 的构造方式），把 RTL 的每一根输出线都和参考值逐位比较：
//   1. 穷举 opcode x funct3 x funct7（含全部非法组合）；
//   2. 五种立即数格式的边界值（编码器正向构造 + 参考模型反向核验）；
//   3. 随机 32 位指令 fuzz；
//   4. 解析 testcases/*/program.S 里的真实指令交叉验证。
//
// 编译与运行见 test/decoder_test/run.sh。
// -----------------------------------------------------------------------------

#include "Vdecoder.h"
#include "verilated.h"

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

// ---- 编码常量：与 verilog/rv32_defs.sv 保持一致 -----------------------------
enum {
  ALU_ADD = 0, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR, ALU_SRL, ALU_SRA,
  ALU_OR, ALU_AND, ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU, ALU_DIV, ALU_DIVU,
  ALU_REM, ALU_REMU
};
enum { A_REG = 0, A_PC, A_ZERO };
enum { B_REG = 0, B_IMM };
enum { WB_ALU = 0, WB_MEM, WB_PC4 };
enum { SZ_BYTE = 0, SZ_HALF, SZ_WORD };

namespace {

// ---- 参考译码器 --------------------------------------------------------------

struct Dec {
  uint8_t  rs1 = 0, rs2 = 0, rd = 0;
  bool     reg_we = false;
  uint8_t  wb_sel = WB_ALU;
  uint8_t  alu_op = ALU_ADD;
  uint8_t  a_sel = A_REG;
  bool     b_sel = B_REG;
  uint32_t imm = 0;
  bool     is_branch = false, is_jal = false, is_jalr = false;
  bool     is_load = false, is_store = false;
  uint8_t  mem_size = SZ_WORD;
  bool     mem_unsigned = false;
  bool     illegal = false;
};

uint32_t sext(uint32_t v, int bits) {
  uint32_t m = 1u << (bits - 1);
  return (v ^ m) - m;
}

uint32_t imm_i(uint32_t x) { return sext(x >> 20, 12); }

uint32_t imm_s(uint32_t x) {
  uint32_t v = ((x >> 25) << 5) | ((x >> 7) & 0x1f);
  return sext(v, 12);
}

uint32_t imm_b(uint32_t x) {
  uint32_t v = (((x >> 31) & 1) << 12) | (((x >> 7) & 1) << 11) |
               (((x >> 25) & 0x3f) << 5) | (((x >> 8) & 0xf) << 1);
  return sext(v, 13);
}

uint32_t imm_u(uint32_t x) { return x & 0xfffff000u; }

uint32_t imm_j(uint32_t x) {
  uint32_t v = (((x >> 31) & 1) << 20) | (((x >> 12) & 0xff) << 12) |
               (((x >> 20) & 1) << 11) | (((x >> 21) & 0x3ff) << 1);
  return sext(v, 21);
}

Dec ref_decode(uint32_t x) {
  Dec d;
  d.rs1 = (x >> 15) & 0x1f;
  d.rs2 = (x >> 20) & 0x1f;
  d.rd  = (x >> 7) & 0x1f;
  uint32_t funct3 = (x >> 12) & 0x7;
  uint32_t funct7 = (x >> 25) & 0x7f;

  switch (x & 0x7f) {
    case 0x37: // LUI
      d.imm = imm_u(x);
      d.reg_we = true;
      d.a_sel = A_ZERO;
      d.b_sel = B_IMM;
      d.alu_op = ALU_ADD;
      break;
    case 0x17: // AUIPC
      d.imm = imm_u(x);
      d.reg_we = true;
      d.a_sel = A_PC;
      d.b_sel = B_IMM;
      d.alu_op = ALU_ADD;
      break;
    case 0x6f: // JAL
      d.imm = imm_j(x);
      d.reg_we = true;
      d.wb_sel = WB_PC4;
      d.is_jal = true;
      break;
    case 0x67: // JALR
      d.imm = imm_i(x);
      d.reg_we = true;
      d.wb_sel = WB_PC4;
      d.is_jalr = true;
      d.b_sel = B_IMM;
      if (funct3 != 0) d.illegal = true;
      break;
    case 0x63: // BRANCH
      d.imm = imm_b(x);
      d.is_branch = true;
      d.b_sel = B_IMM;
      if (funct3 == 2 || funct3 == 3) d.illegal = true;
      break;
    case 0x03: // LOAD
      d.imm = imm_i(x);
      d.reg_we = true;
      d.wb_sel = WB_MEM;
      d.is_load = true;
      d.b_sel = B_IMM;
      switch (funct3) {
        case 0: d.mem_size = SZ_BYTE; break;                    // LB
        case 1: d.mem_size = SZ_HALF; break;                    // LH
        case 2: d.mem_size = SZ_WORD; break;                    // LW
        case 4: d.mem_size = SZ_BYTE; d.mem_unsigned = true; break;  // LBU
        case 5: d.mem_size = SZ_HALF; d.mem_unsigned = true; break;  // LHU
        default: d.illegal = true;
      }
      break;
    case 0x23: // STORE
      d.imm = imm_s(x);
      d.is_store = true;
      d.b_sel = B_IMM;
      switch (funct3) {
        case 0: d.mem_size = SZ_BYTE; break;  // SB
        case 1: d.mem_size = SZ_HALF; break;  // SH
        case 2: d.mem_size = SZ_WORD; break;  // SW
        default: d.illegal = true;
      }
      break;
    case 0x13: // OP-IMM
      d.imm = imm_i(x);
      d.reg_we = true;
      d.b_sel = B_IMM;
      switch (funct3) {
        case 0: d.alu_op = ALU_ADD; break;
        case 1:
          d.alu_op = ALU_SLL;
          if (funct7 != 0x00) d.illegal = true;
          break;
        case 2: d.alu_op = ALU_SLT; break;
        case 3: d.alu_op = ALU_SLTU; break;
        case 4: d.alu_op = ALU_XOR; break;
        case 5:
          if (funct7 == 0x00) d.alu_op = ALU_SRL;
          else if (funct7 == 0x20) d.alu_op = ALU_SRA;
          else d.illegal = true;
          break;
        case 6: d.alu_op = ALU_OR; break;
        case 7: d.alu_op = ALU_AND; break;
        default: d.illegal = true;
      }
      break;
    case 0x33: // OP
      d.reg_we = true;
      if (funct7 == 0x01) {  // M extension
        switch (funct3) {
          case 0: d.alu_op = ALU_MUL; break;
          case 1: d.alu_op = ALU_MULH; break;
          case 2: d.alu_op = ALU_MULHSU; break;
          case 3: d.alu_op = ALU_MULHU; break;
          case 4: d.alu_op = ALU_DIV; break;
          case 5: d.alu_op = ALU_DIVU; break;
          case 6: d.alu_op = ALU_REM; break;
          case 7: d.alu_op = ALU_REMU; break;
        }
      } else {
        switch (funct3) {
          case 0: d.alu_op = (funct7 == 0x20) ? ALU_SUB : ALU_ADD; break;
          case 1:
            d.alu_op = ALU_SLL;
            if (funct7 != 0x00) d.illegal = true;
            break;
          case 2: d.alu_op = ALU_SLT; break;
          case 3: d.alu_op = ALU_SLTU; break;
          case 4: d.alu_op = ALU_XOR; break;
          case 5: d.alu_op = (funct7 == 0x20) ? ALU_SRA : ALU_SRL; break;
          case 6: d.alu_op = ALU_OR; break;
          case 7: d.alu_op = ALU_AND; break;
          default: d.illegal = true;
        }
        if (funct7 != 0x00 && funct7 != 0x20) d.illegal = true;
        if (funct7 == 0x20 && funct3 != 0 && funct3 != 5) d.illegal = true;
      }
      break;
    default:
      d.illegal = true;
  }
  return d;
}

// ---- 指令编码器（从期望的字段/立即数正向构造指令）----------------------------

uint32_t enc_i(uint32_t op, uint32_t rd, uint32_t f3, uint32_t rs1, uint32_t imm) {
  return ((imm & 0xfffu) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}

uint32_t enc_s(uint32_t op, uint32_t f3, uint32_t rs1, uint32_t rs2, uint32_t imm) {
  return (((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) |
         (f3 << 12) | ((imm & 0x1f) << 7) | op;
}

uint32_t enc_b(uint32_t op, uint32_t f3, uint32_t rs1, uint32_t rs2, uint32_t imm) {
  return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25) |
         (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
         (((imm >> 1) & 0xf) << 8) | (((imm >> 11) & 1) << 7) | op;
}

uint32_t enc_u(uint32_t op, uint32_t rd, uint32_t imm) {
  return (imm & 0xfffff000u) | (rd << 7) | op;
}

uint32_t enc_j(uint32_t op, uint32_t rd, uint32_t imm) {
  return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) |
         (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) |
         (rd << 7) | op;
}

// ---- 测试主体 ----------------------------------------------------------------

uint32_t rng_state = 0x12345678u;
uint32_t rnd() {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 17;
  rng_state ^= rng_state << 5;
  return rng_state;
}

struct Tester {
  Vdecoder* dut;
  long checked = 0;
  long fails = 0;
  long printed = 0;
  long field_fails[19] = {};
  long op_fails[128] = {};

  static const int kMaxPrint = 20;

  void check(uint32_t x, const char* group) {
    dut->instr = x;
    dut->eval();
    checked++;

    Dec e = ref_decode(x);
    // 非法指令不会执行（core 收到 illegal 即停机），imm 视为 don't-care：
    // 例如 RTL 对 SYSTEM(0x73) 仍按 I 型拼装立即数，参考模型则不关心。
    bool imm_ok = e.illegal || (dut->imm == e.imm);
    bool ok = dut->rs1 == e.rs1 && dut->rs2 == e.rs2 && dut->rd == e.rd &&
              bool(dut->reg_we) == e.reg_we && dut->wb_sel == e.wb_sel &&
              dut->alu_op == e.alu_op && dut->a_sel == e.a_sel &&
              bool(dut->b_sel) == e.b_sel && imm_ok &&
              bool(dut->is_branch) == e.is_branch && bool(dut->is_jal) == e.is_jal &&
              bool(dut->is_jalr) == e.is_jalr && bool(dut->is_load) == e.is_load &&
              bool(dut->is_store) == e.is_store && dut->mem_size == e.mem_size &&
              bool(dut->mem_unsigned) == e.mem_unsigned &&
              bool(dut->illegal) == e.illegal;
    if (!ok) {
      long f[19] = {dut->rs1 != e.rs1, dut->rs2 != e.rs2, dut->rd != e.rd,
                    bool(dut->reg_we) != e.reg_we, dut->wb_sel != e.wb_sel,
                    dut->alu_op != e.alu_op, dut->a_sel != e.a_sel,
                    bool(dut->b_sel) != e.b_sel, !e.illegal && (dut->imm != e.imm),
                    bool(dut->is_branch) != e.is_branch, bool(dut->is_jal) != e.is_jal,
                    bool(dut->is_jalr) != e.is_jalr, bool(dut->is_load) != e.is_load,
                    bool(dut->is_store) != e.is_store, dut->mem_size != e.mem_size,
                    bool(dut->mem_unsigned) != e.mem_unsigned,
                    bool(dut->illegal) != e.illegal};
      for (int i = 0; i < 17; i++) field_fails[i] += f[i];
      op_fails[x & 0x7f]++;
    }
    if (!ok && printed < kMaxPrint) {
      printed++;
      std::printf("FAIL [%s] instr=%08x\n", group, x);
      std::printf("  got: rs1=%u rs2=%u rd=%u we=%u wb=%u alu=%u asel=%u bsel=%u "
                  "imm=%08x br=%u jal=%u jalr=%u ld=%u st=%u sz=%u uns=%u ill=%u\n",
                  dut->rs1, dut->rs2, dut->rd, dut->reg_we, dut->wb_sel, dut->alu_op,
                  dut->a_sel, dut->b_sel, dut->imm, dut->is_branch, dut->is_jal,
                  dut->is_jalr, dut->is_load, dut->is_store, dut->mem_size,
                  dut->mem_unsigned, dut->illegal);
      std::printf("  want:rs1=%u rs2=%u rd=%u we=%u wb=%u alu=%u asel=%u bsel=%u "
                  "imm=%08x br=%u jal=%u jalr=%u ld=%u st=%u sz=%u uns=%u ill=%u\n",
                  e.rs1, e.rs2, e.rd, e.reg_we, e.wb_sel, e.alu_op, e.a_sel, e.b_sel,
                  e.imm, e.is_branch, e.is_jal, e.is_jalr, e.is_load, e.is_store,
                  e.mem_size, e.mem_unsigned, e.illegal);
    }
    if (!ok) fails++;
  }

  void exhaustive() {
    for (uint32_t op = 0; op < 128; op++)
      for (uint32_t f3 = 0; f3 < 8; f3++)
        for (uint32_t f7 = 0; f7 < 128; f7++) {
          uint32_t x = (f7 << 25) | (0x15u << 20) | (0x0au << 15) |
                       (f3 << 12) | (0x07u << 7) | op;
          check(x, "exhaustive");
        }
  }

  void immediates() {
    const uint32_t i_vals[] = {0, 1, 0x7ff, 0x800, 0xfff};
    for (uint32_t v : i_vals) {
      check(enc_i(0x13, 5, 0, 3, v), "imm-I");
      check(enc_i(0x03, 5, 2, 3, v), "imm-I");
      check(enc_i(0x67, 5, 0, 3, v), "imm-I");
    }
    const uint32_t s_vals[] = {0, 1, 0x7ff, 0x800, 0xfff};
    for (uint32_t v : s_vals)
      check(enc_s(0x23, 2, 3, 4, v), "imm-S");

    const uint32_t b_vals[] = {0, 2, 0x7fe, 0x800, 0x1ffe};
    for (uint32_t v : b_vals)
      check(enc_b(0x63, 0, 3, 4, v), "imm-B");

    const uint32_t u_vals[] = {0, 0x1000, 0x7ffff000u, 0x80000000u, 0xfffff000u};
    for (uint32_t v : u_vals) {
      check(enc_u(0x37, 5, v), "imm-U");
      check(enc_u(0x17, 5, v), "imm-U");
    }

    const uint32_t j_vals[] = {0, 2, 0x7fffe, 0x80000, 0xffffe};
    for (uint32_t v : j_vals)
      check(enc_j(0x6f, 5, v), "imm-J");
  }

  void random(long count) {
    for (long i = 0; i < count; i++) {
      uint32_t x = rnd();
      x = (x & ~0x7fu) | (rnd() & 0x7fu);  // 保证 opcode 在 0..127
      check(x, "random");
    }
  }

  void from_file(const std::string& path) {
    std::ifstream in(path);
    if (!in) return;
    std::string line;
    while (std::getline(in, line)) {
      size_t colon = line.find(':');
      if (colon == std::string::npos) continue;
      size_t i = colon + 1;
      while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) i++;
      size_t j = i;
      while (j < line.size() && std::isxdigit(static_cast<unsigned char>(line[j]))) j++;
      if (j - i != 8) continue;
      uint32_t x = static_cast<uint32_t>(std::stoul(line.substr(i, 8), nullptr, 16));
      check(x, path.c_str());
    }
  }

  void scan(const std::string& path) {
    namespace fs = std::filesystem;
    std::error_code ec;
    if (fs::is_regular_file(path, ec)) {
      from_file(path);
      return;
    }
    if (!fs::is_directory(path, ec)) return;
    for (auto it = fs::recursive_directory_iterator(path, ec);
         it != fs::recursive_directory_iterator(); it.increment(ec)) {
      if (ec) break;
      if (it->is_regular_file(ec) && it->path().filename() == "program.S")
        from_file(it->path().string());
    }
  }
};

}  // namespace

int main(int argc, char** argv) {
  VerilatedContext ctx;
  Vdecoder dut{&ctx};

  Tester t{&dut};
  t.exhaustive();
  t.immediates();
  t.random(200000);

  if (argc > 1) {
    for (int i = 1; i < argc; i++) t.scan(argv[i]);
  } else {
    t.scan("testcases");
  }

  static const char* kFieldNames[] = {
      "rs1", "rs2", "rd", "reg_we", "wb_sel", "alu_op", "a_sel", "b_sel", "imm",
      "is_branch", "is_jal", "is_jalr", "is_load", "is_store", "mem_size",
      "mem_unsigned", "illegal"};
  std::printf("field mismatches:");
  for (int i = 0; i < 17; i++)
    if (t.field_fails[i]) std::printf(" %s=%ld", kFieldNames[i], t.field_fails[i]);
  std::printf("\nfailing opcodes:");
  for (int op = 0; op < 128; op++)
    if (t.op_fails[op]) std::printf(" %02x:%ld", op, t.op_fails[op]);
  std::printf("\n");

  std::printf("decoder_tb: checked=%ld fails=%ld\n", t.checked, t.fails);
  std::printf("%s\n", t.fails ? "FAIL" : "PASS");
  return t.fails ? 1 : 0;
}
