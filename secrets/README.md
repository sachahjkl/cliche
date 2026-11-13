# Secrets

cliche's secrets for its licence (`src/licence/product.odin`): the toolkit's
[docs/licence.md](https://github.com/sachahjkl/gui_toolkit/blob/main/docs/licence.md) says the whole flow. The files are
committed: their values are encrypted with sops for the maintainer's age key (`../.sops.yaml`). None is here yet: the
maintainer makes the key pair and the Paddle keys at the end (docs/licence.md, "What the maintainer does at the end").

| File | Use |
|---|---|
| `development.yaml` | the development pair (its seed is public on purpose: the program's tool has it as `dev_seed`), the sandbox's Paddle keys |
| `production.yaml` | the real signing key and the live Paddle keys, used to deploy the licence Worker |

Keys of both files (the Worker's secrets, `licence-worker/src/env.ts`):

| Key | What it is |
|---|---|
| `LICENSE_PRIVATE_KEY` | the 32-byte Ed25519 seed, base64url: the line of `private.key` that is not a `#` comment (`clichetool licence keygen`) |
| `PADDLE_WEBHOOK_SECRET` | Paddle > Developer tools > Notifications > the destination > Secret key (`pdl_ntfset_...`) |
| `PADDLE_API_KEY` | Paddle > Developer tools > Authentication > API keys (server side, `customer.read`) |
| `ADMIN_TOKEN` | optional: the bearer token of the Worker's `/admin/*` |

A key that sets the catalogue up (`clichetool paddle -apply`: product and price rights) does not go to the Worker. Keep it here
only while the set-up lasts (`PADDLE_SETUP_KEY`), revoke it in Paddle, then `sops unset` it.

## Key

The age identity is the maintainer's, outside every repository: `~/.config/sops/age/keys.txt`.

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops secrets/production.yaml                                   # edit
sops set secrets/production.yaml '["LICENSE_PRIVATE_KEY"]' '"…"'   # one value, no editor
```

## The Worker's secrets

```sh
clichetool licence secrets secrets/production.yaml <toolkit>/licence-worker/secrets.env
clichetool licence secrets secrets/development.yaml <toolkit>/licence-worker/secrets.sandbox.env
```

The tool decrypts with `sops --decrypt --output-type dotenv`, keeps only the Worker's secrets, writes a file readable by
you only, and refuses a path that git does not ignore. It prints the names, never a value. Remove the files after the deploy.
