defmodule HllConditionalActions.Encrypted.Map do
  @moduledoc """
  Ecto type for a map stored encrypted with `HllConditionalActions.Vault`.

  Used for payment provider credentials, whose keys differ per provider but
  are all secrets: the whole map is serialised and encrypted as one value.
  """

  use Cloak.Ecto.Map, vault: HllConditionalActions.Vault
end
