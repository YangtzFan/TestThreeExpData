"""Patch the -O0 RV32IM image with one hand-encoded MAMUL instruction.

Only matmul_scalar (0x29c..0x3bf) is replaced. Startup, main, data,
and the ECALL endpoint remain byte-for-byte identical to the RV32IM image.
"""

from pathlib import Path
import struct

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "matmul_2x3_3x5_rv32im.hex"
TARGET = HERE / "matmul_2x3_3x5_mamul.hex"
FUNC_START = 0x29C
FUNC_END = 0x3C0
MAMUL = 0x0000007F
NOP = 0x00000013


def lui(rd: int, upper: int) -> int:
    return (upper << 12) | (rd << 7) | 0x37


def lw(rd: int, offset: int, base: int) -> int:
    assert 0 <= offset < 2048
    return (offset << 20) | (base << 15) | (2 << 12) | (rd << 7) | 0x03


def sw(rs2: int, offset: int, base: int) -> int:
    assert 0 <= offset < 2048
    return ((offset >> 5) << 25) | (rs2 << 20) | (base << 15) | (2 << 12) | ((offset & 31) << 7) | 0x23


lines = SOURCE.read_text(encoding="ascii").splitlines()
assert all(len(line) == 32 for line in lines)
image = bytearray().join(bytes.fromhex(line)[::-1] for line in lines)
word = lambda addr: struct.unpack_from("<I", image, addr)[0]
assert image[:0x200] == bytes(0x200)
assert word(0x200) == 0x00020117  # _start
assert word(0x294) == 0x00000073  # original ECALL
assert word(FUNC_START) == 0xFE010113  # original matmul_scalar prologue
assert word(FUNC_END) == 0xFF010113  # original main prologue
assert struct.unpack_from("<21I", image, 0x3F0) == tuple(range(1, 22))

# x22 points to matrix_a at 0x10000. Use the two free words immediately
# after matrix_c (0x1007c and 0x10080) to preserve ra and sp while MAMUL
# consumes x1 and x2 as matrix operands.
instructions = [
    lui(22, 0x10),
    sw(1, 0x7C, 22),
    sw(2, 0x80, 22),
]
instructions += [lw(reg, (reg - 1) * 4, 22) for reg in range(1, 22)]
instructions += [
    MAMUL,
    lui(1, 0x10),
]
instructions += [sw(22 + index, 0x54 + index * 4, 1) for index in range(10)]
instructions += [
    lw(2, 0x80, 1),
    lw(1, 0x7C, 1),
    NOP,  # load-use spacing before jalr ra
    0x00008067,  # jalr x0, 0(ra)
]
assert instructions.count(MAMUL) == 1
assert len(instructions) * 4 <= FUNC_END - FUNC_START
instructions += [NOP] * ((FUNC_END - FUNC_START) // 4 - len(instructions))
for index, instruction in enumerate(instructions):
    struct.pack_into("<I", image, FUNC_START + index * 4, instruction)

assert word(FUNC_START + 24 * 4) == MAMUL
output_lines = [bytes(image[i:i + 16])[::-1].hex() for i in range(0, len(image), 16)]
assert all(len(line) == 32 for line in output_lines)
TARGET.write_text("\n".join(output_lines) + "\n", encoding="ascii")
print(f"{TARGET}: {len(image)} bytes, one MAMUL at 0x{FUNC_START + 24 * 4:x}")
