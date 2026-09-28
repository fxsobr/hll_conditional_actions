defmodule HllConditionalActionsWeb.ErrorMessages do
  @moduledoc """
  The app's own validation messages, listed for `mix gettext.extract`.

  Changesets add their errors as plain English strings, which
  `HllConditionalActionsWeb.CoreComponents.translate_error/1` looks up in
  the "errors" domain at render time. Gettext only extracts strings it can
  see in a gettext call, so each message the domain code writes is named
  here once with `dgettext_noop/2`; a new `add_error` or `message:` needs
  its line too. Values that change - a field, a minimum - are `%{...}`
  bindings, never interpolated, so the message itself stays fixed.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  @doc false
  def messages do
    [
      dgettext_noop("errors", "must have at least one entry"),
      dgettext_noop("errors", "%{fields} cannot be used with this trigger"),
      dgettext_noop("errors", "runs a different game than this rule"),
      dgettext_noop("errors", "is not valid for this field"),
      dgettext_noop("errors", "is not a valid regex: %{reason}"),
      dgettext_noop("errors", "must list at least one value"),
      dgettext_noop("errors", "must be a whole number"),
      dgettext_noop("errors", "must be a number"),
      dgettext_noop("errors", "must be true or false"),
      dgettext_noop("errors", "%{param} is required"),
      dgettext_noop("errors", "%{param} must be at least %{min}"),
      dgettext_noop("errors", "%{param} must be a whole number"),
      dgettext_noop("errors", "%{param} must be a registered Discord webhook"),
      dgettext_noop("errors", "%{param} must be a colour like #5865F2"),
      dgettext_noop("errors", "%{param} must be an https:// address"),
      dgettext_noop("errors", "%{param} is not one of the choices"),
      dgettext_noop("errors", "%{param} must be a Discord id"),
      dgettext_noop("errors", "a Discord message needs a text or an embed"),
      dgettext_noop("errors", "must be a Discord webhook URL"),
      dgettext_noop("errors", "must be an https:// address"),
      dgettext_noop("errors", "Discord does not know this webhook"),
      dgettext_noop("errors", "may only contain letters, numbers, dots, dashes and underscores"),
      dgettext_noop("errors", "must be a valid email address"),
      dgettext_noop("errors", "does not match"),
      dgettext_noop("errors", "can only be counted over a career"),
      dgettext_noop("errors", "give at least one stat a weight")
    ]
  end
end
