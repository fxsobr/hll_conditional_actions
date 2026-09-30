defmodule HllConditionalActionsWeb.ShopFormat do
  @moduledoc """
  Dates, times and small phrases of the public shop, in the visitor's
  language and the shop's time zone (the first shop server's).
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.Servers.Server

  @doc "The shop's time zone: its first server's, or UTC."
  @spec zone([map()]) :: String.t()
  def zone([%Server{} = server | _rest]), do: Server.timezone(server)
  def zone(_servers), do: "Etc/UTC"

  @doc "A moment in a time zone (UTC when the zone is unknown)."
  @spec local(DateTime.t(), String.t()) :: DateTime.t()
  def local(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _error -> at
    end
  end

  @doc "\"21:50\"."
  @spec time(DateTime.t() | nil, String.t()) :: String.t()
  def time(nil, _zone), do: ""
  def time(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  @doc "\"21:50:08\"."
  @spec time_seconds(DateTime.t() | nil, String.t()) :: String.t()
  def time_seconds(nil, _zone), do: ""
  def time_seconds(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M:%S")

  @doc "\"14 out\"."
  @spec day_month(DateTime.t() | nil, String.t()) :: String.t()
  def day_month(nil, _zone), do: ""

  def day_month(at, zone) do
    local = local(at, zone)
    "#{pad(local.day)} #{month(local.month)}"
  end

  @doc "\"28 dez 2026\"."
  @spec date(DateTime.t() | nil, String.t()) :: String.t()
  def date(nil, _zone), do: ""

  def date(at, zone) do
    local = local(at, zone)
    "#{local.day} #{month(local.month)} #{local.year}"
  end

  @doc "\"29 set, 21:51\"."
  @spec day_time(DateTime.t() | nil, String.t()) :: String.t()
  def day_time(nil, _zone), do: ""

  def day_time(at, zone) do
    local = local(at, zone)
    "#{local.day} #{month(local.month)}, #{Calendar.strftime(local, "%H:%M")}"
  end

  @doc "\"29 set 2026, 21:51\"."
  @spec full(DateTime.t() | nil, String.t()) :: String.t()
  def full(nil, _zone), do: ""

  def full(at, zone) do
    local = local(at, zone)
    "#{local.day} #{month(local.month)} #{local.year}, #{Calendar.strftime(local, "%H:%M")}"
  end

  @doc ~s(When something was last seen: "hoje 21:48", "ontem" or "14 set".)
  @spec seen(DateTime.t() | nil, String.t()) :: String.t()
  def seen(nil, _zone), do: ""

  def seen(at, zone) do
    today = DateTime.utc_now() |> local(zone) |> DateTime.to_date()
    local = local(at, zone)

    case Date.diff(today, DateTime.to_date(local)) do
      0 -> gettext("today %{time}", time: Calendar.strftime(local, "%H:%M"))
      1 -> gettext("yesterday")
      _older -> day_month(at, zone)
    end
  end

  @doc "\"junho de 2026\"."
  @spec month_year(DateTime.t() | nil) :: String.t()
  def month_year(nil), do: ""

  def month_year(at),
    do: gettext("%{month} %{year}", month: long_month(at.month), year: at.year)

  @doc "Whole days from now until a moment (0 when it is past)."
  @spec days_left(DateTime.t()) :: non_neg_integer()
  def days_left(at), do: max(ceil(DateTime.diff(at, DateTime.utc_now()) / 86_400), 0)

  @doc "A list of names: \"BR #1, BR #2 e BR #3\"."
  @spec join([String.t()]) :: String.t()
  def join([]), do: ""
  def join([one]), do: one

  def join(items) do
    {init, [last]} = Enum.split(items, -1)
    gettext("%{items} and %{last}", items: Enum.join(init, ", "), last: last)
  end

  @doc "The short name of a month."
  @spec month(1..12) :: String.t()
  def month(1), do: gettext("Jan")
  def month(2), do: gettext("Feb")
  def month(3), do: gettext("Mar")
  def month(4), do: gettext("Apr")
  def month(5), do: gettext("May")
  def month(6), do: gettext("Jun")
  def month(7), do: gettext("Jul")
  def month(8), do: gettext("Aug")
  def month(9), do: gettext("Sep")
  def month(10), do: gettext("Oct")
  def month(11), do: gettext("Nov")
  def month(12), do: gettext("Dec")

  @doc "The full name of a month."
  @spec long_month(1..12) :: String.t()
  def long_month(1), do: gettext("January")
  def long_month(2), do: gettext("February")
  def long_month(3), do: gettext("March")
  def long_month(4), do: gettext("April")
  def long_month(5), do: gettext("May (month)")
  def long_month(6), do: gettext("June")
  def long_month(7), do: gettext("July")
  def long_month(8), do: gettext("August")
  def long_month(9), do: gettext("September")
  def long_month(10), do: gettext("October")
  def long_month(11), do: gettext("November")
  def long_month(12), do: gettext("December")

  @doc "The time of day of a map, as CRCON names it."
  @spec environment(String.t() | nil) :: String.t() | nil
  def environment("day"), do: gettext("day")
  def environment("dusk"), do: gettext("dusk")
  def environment("dawn"), do: gettext("dawn")
  def environment("night"), do: gettext("night")
  def environment("overcast"), do: gettext("overcast")
  def environment("rain"), do: gettext("rain")
  def environment(_other), do: nil

  @doc ~s(Initials for an avatar: "KO" for "Kowalski [7DV]".)
  @spec initials(String.t() | nil) :: String.t()
  def initials(nil), do: "?"

  def initials(name) do
    words =
      name
      |> String.replace(~r/[\[\(].*?[\]\)]/u, "")
      |> String.split(~r/[\s._\-]+/u, trim: true)

    case words do
      [one] -> one |> String.slice(0, 2) |> String.upcase()
      [a, b | _rest] -> String.upcase(String.first(a) <> String.first(b))
      [] -> name |> String.slice(0, 2) |> String.upcase()
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)
end
