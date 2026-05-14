ExUnit.start()

case :os.type() do
  {:unix, :linux} -> :ok
  _ -> ExUnit.configure(exclude: [:linux_only])
end
