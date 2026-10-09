# Builds and runs the standalone server in server/. The build context
# is the repo root because the server path-depends on the library at
# `..`. Builder and runner share a Debian snapshot: the release
# carries ERTS and the SQLite NIF compiled against the builder's libc.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1
ARG DEBIAN_VERSION=bookworm-20260824-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Deps first, so a source change does not refetch or recompile them.
# The library's mix.exs is what the path dep resolves against; its
# deps are pinned by the server's lock file.
COPY mix.exs /app/mix.exs
COPY server/mix.exs server/mix.lock /app/server/
WORKDIR /app/server
RUN mix deps.get --only prod
COPY server/config/config.exs server/config/prod.exs config/
RUN mix deps.compile --skip-local-deps

COPY lib /app/lib
COPY priv /app/priv
COPY server/lib lib
COPY server/rel rel
COPY server/config/runtime.exs config/
RUN mix compile --warnings-as-errors && mix release

FROM ${RUNNER_IMAGE}

# git is what the code audit shells out to and iptables what the
# entrypoint sets the firewall with; the rest is what ERTS needs on a
# slim image, libsctp1 so the socket layer stops warning that it
# cannot find it.
RUN apt-get update -y && \
    apt-get install -y git iptables libstdc++6 openssl libncurses5 libsctp1 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# The image starts as root, for the entrypoint's firewall, and the
# release drops to `beamlet` (rel/env.sh.eex). `beamlet` owns /data
# and nothing else: the release, /app included, is root's, so code
# past the policy cannot change what root runs later, and it has no
# home. What the release writes goes to /tmp.
RUN useradd --uid 1000 --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin beamlet && \
    mkdir /data && chown beamlet:beamlet /data

WORKDIR /app
COPY --from=builder /app/server/_build/prod/rel/beamlet_server ./
COPY server/rel/docker-entrypoint.sh /usr/local/bin/docker-entrypoint

ENV BEAMLET_DATA_DIR=/data
ENV RELEASE_TMP=/tmp
ENV ERL_CRASH_DUMP=/tmp/erl_crash.dump
ENV PATH="/app/bin:${PATH}"
EXPOSE 4000

ENTRYPOINT ["docker-entrypoint"]
CMD ["beamlet_server", "start"]
