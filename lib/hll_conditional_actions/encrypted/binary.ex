defmodule HllConditionalActions.Encrypted.Binary do
  @moduledoc """
  Ecto type for values stored encrypted with `HllConditionalActions.Vault`.

  Reads and writes look like a plain string in application code; the ciphertext
  only exists in the `:binary` database column.
  """

  use Cloak.Ecto.Binary, vault: HllConditionalActions.Vault
end
