return function(env)
    local cycles, instructions = env.run_until_ecall()
    print(string.format("[matmul_cycles] image=%s AXI_delay=5 cycles=%d instructions=%d",
        os.getenv("RISCV_HEX") or "default", cycles, instructions))
end
