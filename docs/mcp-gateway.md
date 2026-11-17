# MCP gateway: LiteLLM in front of MCP servers

LiteLLM is the lab's MCP gateway as well as its model endpoint
([local-ai.md](local-ai.md)). An MCP server is registered once, in LiteLLM,
along with its credential. Clients connect to `http://127.0.0.1:4000/mcp` with
their own LiteLLM key and see only the servers that key is granted.

```
Claude Code ──key: claude-code──┐
                                ├─▶ LiteLLM :4000/mcp ──token──▶ content curator :8090/mcp
Hermes lab  ──key: hermes-lab───┘      (per-key allowlist)
Hermes restricted, scripts, curator: no MCP servers
```

## Why

- The server's credential stays with LiteLLM. A client holds only its LiteLLM
  key, so reading a client's config does not give out the curator's API token,
  and a client can be cut off or narrowed by its key alone.
- One endpoint and one allowlist per client, instead of each client carrying
  its own registration of each server.
- LiteLLM logs MCP calls with the client's key, next to the model spend.

Today only the content curator's MCP is behind it. A second server (a Gmail
sorter is planned) is a few lines, below.

## How it is wired

All of it is code in `provision/lib/litellm.sh`.

| Piece | Where |
|---|---|
| Server list | `LITELLM_MCP_SERVERS`: `name\|url\|token file\|description` |
| Who may use what | `LITELLM_MCP_GRANTS`: `client:server` |
| Server tokens | read from each token file into `~/.secrets/litellm/mcp.env` (mode 600), passed to the container as `MCP_<NAME>_TOKEN`; `config.yaml` only holds `os.environ/MCP_<NAME>_TOKEN` |
| Client keys | `LITELLM_CLIENTS`; each key's grants are set on every run |
| Client registration | `litellm_connect_clients`: Claude Code (user scope) and Hermes' lab profile, server name `litellm` |

Things that are not obvious:

- **Tool names carry the server name**, `<server>-<tool>`. The curator's
  `weekly_review` is `content_curator-weekly_review`, which Claude Code shows
  as `mcp__litellm__content_curator-weekly_review`. The separator is `-`, so
  server names use underscores. The weekly review's prompt names the tool this
  way.
- **A key with no MCP grant is not locked out.** LiteLLM treats a key without
  an MCP scope as allowed to use every server. So every client not listed in
  `LITELLM_MCP_GRANTS` is set to the `no-mcp-servers` marker. Keys made by hand
  in the admin UI do not get this; set it there.
- **Server ids are pinned** to the server name in `config.yaml`. Without a pin
  LiteLLM derives the id from the url and auth type, and a grant would silently
  stop matching after an edit to either.
- **Host networking.** LiteLLM runs with `network_mode: host`, so it reaches an
  MCP server on `127.0.0.1:<port>`, not a name on a Docker network. A server in
  a container must publish a port on `127.0.0.1` only. Moving LiteLLM onto a
  bridge network would allow unpublished servers, and is a separate change.
- **Token missing.** A server whose token file does not exist is left out with
  a warning, so the order of the setup scripts does not matter. The curator's
  setup re-runs `install_litellm` after it creates the token.
- Claude Code authenticates with `x-litellm-api-key: Bearer <key>`; the Hermes
  entry uses `Authorization: Bearer <key>`, which LiteLLM also accepts.

## Add a server

1. Run it so that it listens on `127.0.0.1:<port>` (HTTP, MCP streamable
   transport), with its secret in a file under `~/.secrets/`.
2. Add a row to `LITELLM_MCP_SERVERS` in `lib/litellm.sh`. The name uses
   underscores.
3. Add `client:name` rows to `LITELLM_MCP_GRANTS` for the clients that may use it.
4. Optional, to limit tools: add `allowed_tools: [...]` to that server's entry
   in `_litellm_config` (or `mcp_tool_permissions` per key in
   `_litellm_key_mcp`), naming tools without the server prefix.
5. Run `./provision/local-ai-setup.sh`.

## Grant a key

Add the `client:server` row to `LITELLM_MCP_GRANTS` and re-run
`./provision/local-ai-setup.sh`. A new client also goes in `LITELLM_CLIENTS`.
Removing a row takes the grant away on the next run.

## Verify

```sh
KEY=$(cat ~/.secrets/litellm/claude-code.key)
curl -s -X POST http://127.0.0.1:4000/mcp \
  -H "x-litellm-api-key: Bearer $KEY" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | grep '^data:' | sed 's/^data: //' | jq -r '.result.tools[].name'

# A key with no grant sees nothing:
curl -s -X POST http://127.0.0.1:4000/mcp \
  -H "x-litellm-api-key: Bearer $(cat ~/.secrets/litellm/scripts.key)" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

claude mcp list          # litellm, connected
hermes mcp list          # litellm in the lab profile (`hermes mcp test litellm`)
```

## Rollback

Put the direct registration back by hand, or check out the commit before this
change and re-run the setup: the old one registered `content_curator` with
Claude Code and Hermes straight to `http://127.0.0.1:8090/mcp` with the
curator's API token (`~/.secrets/content-curator/api-token`). To turn the
gateway's MCP off alone, empty `LITELLM_MCP_SERVERS` and re-run; clients then
stop being registered, but remove `litellm` from them with `claude mcp remove
--scope user litellm` and `hermes config unset mcp_servers.litellm`.
