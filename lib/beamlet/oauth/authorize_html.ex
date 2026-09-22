defmodule Beamlet.OAuth.AuthorizeHTML do
  @moduledoc false

  use Phoenix.Component

  alias Beamlet.Web.Layouts

  embed_templates "authorize_html/*"
end
