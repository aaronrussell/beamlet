# Security

A beamlet belongs to one person: you. Each client you connect gets its own token, and each token carries a policy that sets what the client's agent may do. A policy is a guardrail, not a sandbox, so treat any token as full access to your beamlet, and give one only to a client you trust.

## The token is the boundary

Without a token, a request reaches the pages your agents have built, the sign-in page and the OAuth pages, and nothing else. That is the line Beamlet holds firmly.

With a token, the policy takes over. Give a token only to a client you trust, and when you stop using a client, delete its token. The client is cut off from its next request.

If you run Beamlet inside your own Phoenix app, agent code runs in your app's VM, so your app is inside the boundary too. `Beamlet` has more.

## What a policy does, and doesn't

A policy decides which tools a client gets, and which modules and functions its code may call. Your beamlet checks every piece of code before it runs. Code that calls something the policy refuses is turned away, and so is code that works out what to call at runtime, uses `apply`, writes a macro or starts a process. Files go through `Host.File`, which keeps them to the files dir, and HTTP through `Host.HTTP`, which keeps off your network.

That stops an honest agent's accidents, and the prompt injection that reaches for ordinary APIs: "read this file", "fetch this URL". It stops a good deal more besides.

It isn't a sandbox. Agent code runs in the same VM as your beamlet, and Elixir is a big language. There are ways through, and each one takes more deliberate and stranger code than the last. Beamlet closes the routes an agent might take by accident or be talked into, and stops there. Closing every one would mean taking away the language that makes a beamlet worth having.

## What's in place

- Token secrets are shown once and stored only as hashes.
- Chat clients connect with OAuth, using PKCE and single-use codes.
- HTTP requests from agent code can't reach your private network, loopback or a cloud provider's metadata address, unless you allow a host.
- In the Docker image, firewall rules hold agent code to public TCP even if it gets past its policy, and your beamlet runs as a user with no rights beyond its data dir.
- Agent code's files are kept to the files dir, and the agent database can't reach any other file.
- Your sign-in cookie is kept away from the pages agents build.

## What you should do

- Choose a strong password when you run `beamlet setup`.
- Put HTTPS in front of your beamlet once it's online.
- Give tokens only to clients you trust, and [delete the ones](tokens-and-policies.md#creating-and-managing-tokens) you stop using.
- Open the [allow list](operating-a-beamlet.md#the-firewall) only to the hosts you mean.
- Consider opening only `/beamlet` and `/.well-known` to the internet at your proxy, and keeping everything else to your own network or behind basic auth. Clients connect and you sign in through those two paths alone.
- Otherwise, treat every page an agent builds as public. Anyone with the address can open it, so don't build anything you wouldn't put on the open web.
