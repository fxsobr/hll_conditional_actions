defmodule HllConditionalActionsWeb.RelativeTime do
  @moduledoc """
  Short, server-side "how long ago" labels for the shell - the bell's panel
  and the command palette: "agora", "7 min", "2 h", "ontem", "3 dias".

  Pages that show a time the viewer reads closely use
  `HllConditionalActionsWeb.Ui.local_time/1` instead, which follows the
  browser's clock and time zone; these labels only have to be right to the
  minute when the panel opens.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  @doc """
  How long ago `at` was, in the fewest words.

      iex> now = ~U[2026-09-30 12:00:00Z]
      iex> HllConditionalActionsWeb.RelativeTime.short(~U[2026-09-30 11:53:00Z], now)
      "7 min"
      iex> HllConditionalActionsWeb.RelativeTime.short(~U[2026-09-30 09:00:00Z], now)
      "3 h"
      iex> HllConditionalActionsWeb.RelativeTime.short(nil, now)
      nil
  """
  @spec short(DateTime.t() | NaiveDateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def short(at, now \\ DateTime.utc_now())
  def short(nil, _now), do: nil
  def short(%NaiveDateTime{} = at, now), do: short(DateTime.from_naive!(at, "Etc/UTC"), now)

  def short(%DateTime{} = at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> gettext("now")
      seconds < 3600 -> gettext("%{count} min", count: div(seconds, 60))
      seconds < 86_400 -> gettext("%{count} h", count: div(seconds, 3600))
      seconds < 2 * 86_400 -> gettext("yesterday")
      true -> ngettext("1 day", "%{count} days", div(seconds, 86_400))
    end
  end

  @doc """
  The same, as a phrase: "há 7 min", "ontem".
  """
  @spec ago(DateTime.t() | NaiveDateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def ago(at, now \\ DateTime.utc_now())
  def ago(nil, _now), do: nil

  def ago(at, now) do
    case short(at, now) do
      nil ->
        nil

      label ->
        if label in [gettext("now"), gettext("yesterday")],
          do: label,
          else: gettext("%{time} ago", time: label)
    end
  end
end
