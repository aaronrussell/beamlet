defmodule Beamlet.Web.SessionHTML do
  @moduledoc false

  use Phoenix.Component

  import Beamlet.Web.Components

  alias Beamlet.Web.Layouts

  embed_templates "session_html/*"
end
