# BeamletServer

The standalone server for Beamlet: the smallest Phoenix app that can run a beamlet. It holds nothing a second embedder would want, only an endpoint, an application module, config and, later, the release and the Dockerfile. Everything else, the MCP server, the router, the assets plug and the operator CLI, is the `beamlet` library at `..`.

    mix deps.get
    mix phx.server

The MCP server is at `http://localhost:4000/_mcp`, and the pages and APIs agents build are served at the root. Users and tokens are managed with `mix beamlet`; see `Beamlet.CLI`. In development the data dir is the library's `../data`, and the policies come from the operator config file there, `../data/config.exs`, which both projects' dev config import when it exists; see `Beamlet.Config.Provider` for the file.
