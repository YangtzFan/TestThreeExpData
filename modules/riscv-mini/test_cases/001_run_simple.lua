return function(env)
    env.run_cycles()
    env.print_host_state()
    print("=== stimulus completed ===")
    io.flush()
end
