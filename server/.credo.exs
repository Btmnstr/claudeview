# Credo runs its default check set in strict mode; we only scope the files.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "config/"]},
      strict: true
    }
  ]
}
