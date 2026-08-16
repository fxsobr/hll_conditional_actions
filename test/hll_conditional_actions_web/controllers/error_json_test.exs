defmodule HllConditionalActionsWeb.ErrorJSONTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  test "renders 404" do
    assert HllConditionalActionsWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert HllConditionalActionsWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
