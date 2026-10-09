# Security

A beamlet belongs to one person: you. Each client you connect gets its own token, and a token reaches everything in your beamlet. Its policy steers the agent using it. This page covers what can go wrong, how it happens, and what to do about each.

## The token is the boundary

Without a token, a request reaches the pages your agents have built, the sign-in page and the OAuth pages, and nothing else. That's the line Beamlet holds firmly.

With a token, the policy takes over. It decides which tools a client gets and which modules and functions its code may call, and your beamlet checks every piece of code before it runs. Files go through `Host.File`, which keeps them to the files dir. HTTP goes through `Host.HTTP`, which keeps off your network. That keeps an honest agent to what you meant, and stops a prompt injection that reaches for ordinary APIs ("read this file", "fetch this URL").

## Getting past the policy

A policy is a guardrail, not a sandbox. Agent code runs in the same VM as your beamlet, and Elixir is a big language. Beamlet closes the routes an agent might take by accident or be talked into, not every route there is.

Code that gets past its policy gains less than it sounds. A token already reaches everything in your beamlet: its data, its files and its pages. Past the policy, code can also read your beamlet's own secrets, run programs, and serve pages you won't see in your routes. With the secrets it can keep a way in after you delete the token.

In the Docker image it still can't reach your private network or a cloud provider's metadata address, change the firewall, or change Beamlet itself. Getting further means breaking out of the container, which takes a bug in the kernel.

## Where the risk is

These are the ways someone gets in, the most likely scenarios first.

* #### A leaked token

  It takes one slip: a client config file committed with your dotfiles, or caught in a screenshot. Whoever holds a token gets everything in your beamlet, since a policy steers an agent, not a person set on getting in.
  
  Give each client its own token, keep config files private, and delete tokens you stop using.

* #### Prompt injection

  Anything the agent reads, like a web page or an email, can carry instructions telling it to send your data somewhere or add a page. The injection gets what the policy allows, including a way to phone home.
  
  Mind what else the agent reads alongside your beamlet. Give a client reading untrusted text a policy with `deny: [Host.HTTP]`.

* #### Bugs in what agents build

  Agent pages are public, and models write SQL injection and XSS like anyone. Someone who finds a bug reaches the agent database, and script on a page can act as you while you're signed in.
  
  Treat every page as public, or close everything but `/beamlet` and `/.well-known` at your proxy.

* ####  Agent code escapes its policy

  Code written on purpose to break out, usually by an attack aimed at Beamlet, gets your beamlet's own secrets, programs run on the machine and the public internet, but not your network.
  
  Run it in the image, on a machine you've chosen, and start over after a suspected compromise.

* #### Your password

  The sign-in can approve a token, so a weak or reused password, once guessed, gets everything.
  
  Use a strong password, and use it nowhere else.

* #### A bug in Beamlet

  Beamlet is young code, and a bug at the token edge or in OAuth could give anything away.
  
  Keep it up to date, and close what you don't need at your proxy.

Note that the most likely scenarios don't require code escaping its policy. A beamlet gives an agent your data, whatever it reads, and a way to send things out. Simon Willison calls that combination [the lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/), and it's worth knowing before you connect a client that also reads your email.

## Where to run it

Agent code runs inside your beamlet, so a sandbox can only go around the two together. It won't keep agent code from your beamlet's data, but it can limit how far code that escapes its policy can reach beyond your beamlet. So the useful question is what else shares the machine.

- **On Fly**, each machine is a virtual machine of its own, a Firecracker microVM, which is as strong a box as sandboxing offers. [Deploy Beamlet on Fly.io](deploy-beamlet-on-fly.md) sets one up.
- **On a server that runs nothing else**, the server is the box, and the image's [firewall](operating-a-beamlet.md#firewall) keeps agent code off your network. Without it, `BEAMLET_FIREWALL=off`, agent code reaches whatever the server can.
- **On a machine you care about**, a home server or your laptop, the container shares a kernel with everything else on it. A virtual machine of its own puts a stronger wall between them.
- **Inside your own Phoenix app**, agent code runs in your app's VM, so your app is inside the box too, with no firewall.

Wherever it runs, cap what it can use: `--memory`, `--cpus` and `--pids-limit` on `docker run`, or the machine size on Fly. A runaway loop then slows your beamlet and nothing else. And give it no cloud credentials or roles it doesn't need.

If you want to go further, [A Curated Guide to Code Sandboxing Solutions](https://github.com/restyler/awesome-sandbox) compares the ways to isolate code, from containers to microVMs.

## What's in place

- Token secrets are shown once and stored only as hashes.
- Chat clients connect with OAuth, using PKCE and single-use codes.
- HTTP requests from agent code can't reach your private network, loopback or a cloud provider's metadata address, unless you allow a host.
- In the Docker image, firewall rules hold agent code to public TCP even if it gets past its policy, and your beamlet runs as a user with no rights beyond its data dir.
- Agent code's files are kept to the files dir, and the agent database can't reach any other file.
- Your sign-in cookie is kept away from the pages agents build.

## What you should do

- Choose a strong password when you run `beamlet setup`, and use it nowhere else.
- Put HTTPS in front of your beamlet once it's online.
- Give each client its own token, and [delete the ones](tokens-and-policies.md#creating-and-managing-tokens) you stop using. Treat a client's config file as a secret.
- Only allow a client on the consent page when you started connecting it yourself.
- Consider opening only `/beamlet` and `/.well-known` to the internet at your proxy, and keeping everything else to your own network or behind basic auth. Clients connect and you sign in through those two paths alone. Otherwise, treat every page an agent builds as public.
- Open the [allow list](operating-a-beamlet.md#firewall) only to the hosts you mean.
- Give agent code third-party keys with narrow scopes that you can revoke.
- Back up the data dir.
- Protect the account your beamlet is hosted on. Shell access there outranks everything here.

## If something goes wrong

If a token leaks, delete it. If you find code, routes or tokens you didn't ask for, treat your beamlet as compromised. Deleting the token isn't enough then, since what got in may have left a way back. Start a fresh beamlet on a new data dir, with a new password and new tokens, and bring across only what you trust from a backup taken before.
