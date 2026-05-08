# Operator SSH public keys baked into the appliance image

`lab/stage-core-base.sh` reads every `*.pub` file in this
directory at master-build time and writes the keys into the cloud-init
seed under `users[debadmin].ssh_authorized_keys`. The deployed
appliance accepts SSH from any of those keys (plus the password the
operator sets via the console wizard's `[P]` action).

## What goes here

One or more standard OpenSSH public-key files:

```text
lab/keys/
├── README.md                    # tracked in git
├── alice.pub                    # gitignored — drop yours here
├── bob.pub                      # gitignored
└── shared-team-deploy-key.pub   # gitignored
```

File naming is just for your own reference. Comment lines (starting
with `#`) and blank lines are stripped before substitution.

## What if I don't add any keys?

The stager will refuse to build the seed unless you pass
`--allow-no-keys`. The deployed appliance would then have no SSH path
in — only the console wizard's `[P]assword` action would work.

## Why a directory, not a single file

So that cloning the repo onto a different machine doesn't silently
pick up *that* machine's `~/.ssh/id_ed25519.pub` and ship a master
nobody else can log into. See the existing siblings'
`lab/keys/README.md` for the full rationale.
