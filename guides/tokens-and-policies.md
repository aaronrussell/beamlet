# Tokens and policies

Every client you connect gets its own token, and every token carries a policy. The token lets the client in. The policy limits what its agent can do once it's there.

## One token per client

A token is your access to your beamlet, handed to one client. Give each client its own, so you can tell them apart and cut one off without touching the others.

A token arrives in one of two ways:

- **With OAuth.** A chat client gets one when you sign in and allow access on the consent page. It's known by the client's host, such as `claude.ai`.
- **From the command line.** For a client that sends a header, you create one with `beamlet tokens.create`. It's known by the name you give it, and lasts until you delete it.

### Creating and managing tokens

Tokens are managed with the `beamlet` command, run inside the container:

```shell
# List every token with its id, name or host, policy and expiry
docker exec my-beamlet beamlet tokens

# Create a token for a client, printing its secret once
docker exec my-beamlet beamlet tokens.create cursor

# Rename a token you created, or change its policy
docker exec my-beamlet beamlet tokens.update 3 --name cursor-work
docker exec my-beamlet beamlet tokens.update 3 --policy explorer

# Delete a token
docker exec my-beamlet beamlet tokens.delete 3
```

A token is addressed by the id that `beamlet tokens` shows. Copy the secret from `tokens.create` into your client straight away, since it isn't shown again. Deleting a token cuts its client off from its next request.

An OAuth token can't be updated, so to change its policy, delete it and connect the client again. `Beamlet.OAuth` explains how long an OAuth token lasts, and `Beamlet.CLI` has every command.

## What a policy is

A policy is a named set of limits on a token: which tools its client gets, and which modules its code may call. A token gets `default` unless you name another. `default` gives both tools and the parts of Elixir and `Host.*` that keep to your beamlet, and `Beamlet.Policy.Default` shows it in full.

> #### A guardrail, not a sandbox {: .warning}
>
> A policy keeps an honest agent to what you meant it to do, and stops a casual prompt injection that reaches for an ordinary API. It isn't a sandbox, and code set on getting out may find a way. [Security](security.md) explains why.

## Writing one

Policies are declared in config, by name:

```elixir
import Config

config :beamlet,
  policies: [
    explorer: [
      tools: [:eval],
      allow: [{Host.Code, except: [remove: 1]}],
      deny: [Host.HTTP]
    ]
  ]
```

`explorer` is for a client that should look around and run things, but not change what's there. Each line is a limit you'll reach for again:

- `tools: [:eval]` gives the client `eval` alone, so it can't define or patch modules.
- `allow: [{Host.Code, except: [remove: 1]}]` takes away removing modules, which `eval` could otherwise do.
- `deny: [Host.HTTP]` stops its code making HTTP requests.

Anything a policy doesn't name stays as `default` has it. `Beamlet.Policy` lists every key.

## Putting it on your beamlet

Policies live in the config file, `config.exs` in the data dir. Your beamlet reads it when it starts. With Docker, write the file on your machine, copy it in, check it and restart:

```shell
docker cp config.exs my-beamlet:/data/config.exs
docker exec my-beamlet beamlet policies.show explorer
docker restart my-beamlet
```

`policies.show` reads the file afresh, so you can check a change before the restart puts it live.

## Giving it to a client

For a client you create a token for, name the policy:

```shell
docker exec my-beamlet beamlet tokens.create cursor --policy explorer
```

For a chat client, the consent page lists every policy when it connects. Choose `explorer` there.

The client then sees only the tools its policy gives. When its code reaches for something the policy refuses, the error says it isn't permitted by your policy, and usually what to use instead. To see what a policy allows, run `beamlet policies.show explorer`, or ask the agent to print its policy.

## Where next

- [Operating a beamlet](operating-a-beamlet.md) for the rest of what the config file can set.
- [Security](security.md) for what a policy can't do.
