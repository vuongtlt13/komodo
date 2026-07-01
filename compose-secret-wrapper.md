# Compose Secret Wrapper

This document describes how to use `bin/periphery/decrypt-compose-secrets.sh` to decrypt `secret:<encrypted_value>` placeholders before `docker compose` runs.

The wrapper is intended for Komodo Stack `compose_cmd_wrapper`, but you can also run it locally.

## What it does

The wrapper:

- intercepts the final `docker compose ...` command,
- renders temporary sibling files next to the original compose/env files,
- replaces `secret:<encrypted_value>` with decrypted plaintext,
- executes the original compose command with the rendered temp files,
- removes the temp files when the command exits.

The original source files are not modified.

## Script location

In this repo:

```text
bin/periphery/decrypt-compose-secrets.sh
```

In the packaged Periphery image:

```text
/usr/local/bin/decrypt-compose-secrets.sh
```

## Required environment variables

```sh
export DECRYPT_API_KEY="your-api-key"
```

Optional:

```sh
export DECRYPT_URL="https://encryptor-028035723b26.viset.vn/decrypt"
```

If `DECRYPT_URL` is not set, the script defaults to:

```text
https://encryptor-028035723b26.viset.vn/decrypt
```

## Komodo UI setup

Configure the Stack wrapper as:

```sh
/usr/local/bin/decrypt-compose-secrets.sh [[COMPOSE_COMMAND]]
```

Recommended wrapper include values:

- `config`
- `up`

Add `build`, `pull`, or `run` too if your workflow needs them.

Why `config` matters: Komodo runs `docker compose ... config` before `up`, so secrets must already resolve there.

## Supported secret locations

The wrapper currently supports these input paths:

### 1. Directly inside compose YAML

```yaml
services:
  app:
    environment:
      APP_SECRET: secret:ENCRYPTED_VALUE
```

### 2. Explicit Compose env files passed with `--env-file`

```sh
docker compose --env-file stack.env -f compose.yaml up -d
```

`stack.env`:

```env
APP_SECRET=secret:ENCRYPTED_VALUE
```

### 3. Service-level `env_file:` entries in compose YAML

```yaml
services:
  app:
    env_file:
      - stack.env
```

`stack.env`:

```env
APP_SECRET=secret:ENCRYPTED_VALUE
```

## Supported env file formats

The wrapper intentionally supports the common dotenv shapes only:

```env
KEY=secret:ENCRYPTED_VALUE
KEY="secret:ENCRYPTED_VALUE"
KEY='secret:ENCRYPTED_VALUE'
export KEY=secret:ENCRYPTED_VALUE
```

Blank lines and comment lines are preserved.

## Local usage

### Example 1: direct compose secret

`compose.yaml`

```yaml
services:
  whoami:
    image: traefik/whoami
    command:
      - --port=2001
      - --name=secret:CG4iWT3ARbSKqySv.Y+4Er4SN1Wp9kYNe9lLdDW4ky6P3IW4Mv2ax
    ports:
      - "18080:2001"
```

Run:

```sh
export DECRYPT_API_KEY="your-api-key"

bash ./bin/periphery/decrypt-compose-secrets.sh \
  docker compose -f compose.yaml up -d
```

Check:

```sh
curl http://127.0.0.1:18080/
```

Expected output contains:

```text
Name: "hello world"
```

### Example 2: `env_file: - stack.env`

`compose.yaml`

```yaml
services:
  app:
    image: alpine:3.22
    command: ["sh", "-lc", "printf '%s' \"$${WHOAMI_NAME}\""]
    env_file:
      - stack.env
```

`stack.env`

```env
WHOAMI_NAME=secret:CG4iWT3ARbSKqySv.Y+4Er4SN1Wp9kYNe9lLdDW4ky6P3IW4Mv2ax
```

Run:

```sh
export DECRYPT_API_KEY="your-api-key"

bash ./bin/periphery/decrypt-compose-secrets.sh \
  docker compose -f compose.yaml run --rm app
```

Expected output:

```text
hello world
```

### Example 3: `--env-file stack.env`

`compose.yaml`

```yaml
services:
  app:
    image: busybox
    command: ["sh", "-lc", "printf '%s' \"${WHOAMI_NAME}\""]
```

`stack.env`

```env
WHOAMI_NAME=secret:CG4iWT3ARbSKqySv.Y+4Er4SN1Wp9kYNe9lLdDW4ky6P3IW4Mv2ax
```

Run:

```sh
export DECRYPT_API_KEY="your-api-key"

bash ./bin/periphery/decrypt-compose-secrets.sh \
  docker compose --env-file stack.env -f compose.yaml config
```

Expected rendered output contains:

```text
printf '%s' "hello world"
```

## Komodo Stack examples

### A. Secret directly in compose file

```yaml
services:
  app:
    image: myorg/myapp:latest
    environment:
      APP_SECRET: secret:ENCRYPTED_VALUE
```

### B. Secret in a Stack env file

Compose:

```yaml
services:
  app:
    image: myorg/myapp:latest
    env_file:
      - stack.env
```

`stack.env`:

```env
APP_SECRET=secret:ENCRYPTED_VALUE
```

### C. Secret in `additional_env_files` / `--env-file`

Compose:

```yaml
services:
  app:
    image: myorg/myapp:latest
    command: ["sh", "-lc", "echo ${APP_SECRET}"]
```

`stack.env`:

```env
APP_SECRET=secret:ENCRYPTED_VALUE
```

In Komodo, pass that env file using Stack `additional_env_files` so Periphery adds it with `--env-file`.

## Important Compose interpolation note

If the value should be read by the container at runtime, escape the dollar sign:

```yaml
command: ["sh", "-lc", "printf '%s' \"$${WHOAMI_NAME}\""]
```

Use:

- `${VAR}` when Docker Compose should substitute it during render
- `$${VAR}` when the container process should read it at runtime

## Failure behavior

The wrapper exits non-zero when:

- `DECRYPT_API_KEY` is missing,
- the decrypt API returns a non-2xx response,
- the decrypt API response is malformed,
- a placeholder cannot be fully rendered,
- a decrypted value contains newlines.

## Security notes

- The wrapper does not print plaintext secrets.
- Running `docker compose ... config` will still expose rendered plaintext in the command output.
- If Komodo wraps `config`, rendered plaintext may also appear in stored rendered config such as `deployed_config`.
- Temp rendered files are removed when the wrapped command exits.

## Limitations

- Only single-line decrypted values are supported.
- Env file support is intentionally narrow and targets the common dotenv forms above.
- Compose `env_file:` support targets the common scalar and list string forms, not every advanced YAML/object variant.

skipped: parser-backed YAML/env handling, add when real stack files start using advanced env_file syntaxes.
