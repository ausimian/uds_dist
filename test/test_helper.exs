ExUnit.start()

excludes = [:stress]

excludes =
  case :os.type() do
    {:unix, :linux} -> excludes
    _ -> [:linux_only | excludes]
  end

ExUnit.configure(exclude: excludes)
