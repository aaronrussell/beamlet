defmodule Beamlet.OAuth.AuthorizeHTML do
  @moduledoc false

  use Phoenix.Component

  import Beamlet.Web.Components

  alias Beamlet.Web.Layouts

  embed_templates "authorize_html/*"
end
