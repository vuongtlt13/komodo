# Local development

This guide covers the usual local setup flow for Komodo. Most commands are defined in [runfile.toml](runfile.toml) and can be run with `run <task>`.

## Prerequisites

Install the required CLIs:

```sh
rustup install 1.91.1
rustup override set 1.91.1
cargo install runnables-cli
cargo install cargo-watch typeshare-cli
```

Install Node/Yarn. The UI packages use Yarn 1.x.

Docker is required for the compose-based development services.

## Environment files

### Compose / local app env

Create a local env file from the example already in this repo:

```sh
cp .env.local .env
```

For local development, the important values are usually:

```sh
KOMODO_HOST=http://localhost
KOMODO_LOCAL_AUTH=true
KOMODO_INIT_ADMIN_USERNAME=admin
KOMODO_INIT_ADMIN_PASSWORD=changeme
KOMODO_DATABASE_USERNAME=komodo
KOMODO_DATABASE_PASSWORD=komodo
```

Adjust secrets and OAuth/cloud provider variables only when you need those integrations.

### UI dev env

Create [ui/.env.development](ui/.env.development):

```sh
VITE_KOMODO_HOST=http://localhost:9120
```

If you want the UI to point at another Komodo instance, set `VITE_KOMODO_HOST` to that host instead.

## Install and build local JavaScript packages

The UI depends on the local TypeScript client package at [client/core/ts/](client/core/ts/). Run these tasks in order:

```sh
run yarn-install
run gen-client
run link-client
```

`yarn-install` installs JavaScript dependencies for the UI, docsite, and TypeScript client. `gen-client` generates TypeScript types with `typeshare`, builds `komodo_client`, and copies the public client build. `link-client` links `komodo_client` into [ui/](ui/).

## Run with Docker Compose

To start the full local stack with Docker Compose:

```sh
run dev-compose
```

This runs [dev.compose.yaml](dev.compose.yaml), including Core, Periphery, and FerretDB.

To expose the development compose ports:

```sh
run dev-compose-exposed
```

To rebuild compose images:

```sh
run dev-compose-build
```

Check status with:

```sh
docker compose -p komodo-dev -f dev.compose.yaml ps
```

## Run Rust services directly

Start Core:

```sh
run dev-core
```

Equivalent command:

```sh
KOMODO_CONFIG_PATH=.dev/core.config.toml cargo run -p komodo_core --release
```

Start Periphery:

```sh
run dev-periphery
```

Equivalent command:

```sh
cargo run -p komodo_periphery --release -- -c .dev/periphery.config.toml
```

Start outbound Periphery config:

```sh
run dev-periphery-outbound
```

## Run the UI

After `run link-client`, start Vite:

```sh
cd ui
yarn dev
```

The UI should be available at:

```text
http://localhost:5173/
```

## Hot reload

Core watch task:

```sh
run dev-core-watch
```

Periphery watch task:

```sh
run dev-periphery-watch
```

If `cargo watch` fails with `Permission denied` while scanning Docker data under [data/](data/), restrict the watched paths instead of changing database file permissions:

```sh
KOMODO_CONFIG_PATH=.dev/core.config.toml cargo watch \
  -w bin \
  -w lib \
  -w client \
  -w Cargo.toml \
  -w Cargo.lock \
  -x 'run -p komodo_core'
```

## Common issues

### `typeshare: not found`

Install the CLI:

```sh
cargo install typeshare-cli --version 1.0.5
```

Then rerun:

```sh
run link-client
```

### Vite cannot resolve `komodo_client`

Build and link the local TypeScript client:

```sh
run link-client
cd ui
yarn dev
```

### Vite cannot resolve `@lib/formatting`

Use the UI helper import instead:

```ts
import { fmt_date_with_minutes } from "@/lib/formatting";
```

The `@` alias is configured in [ui/vite.config.ts](ui/vite.config.ts).
