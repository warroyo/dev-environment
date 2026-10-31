# Lab metrics

One Grafana Cloud dashboard for the whole lab. The server collects every
metric and is the only machine that talks to Grafana Cloud; lab targets are
scraped over the tailnet and never reach the internet for this.

```
 EVO-X2 (tag:inference, no internet)            server (ubuntu-home)                 Grafana Cloud Free
 ┌──────────────────────────────────┐          ┌──────────────────────────┐          ┌──────────────────┐
 │ node_exporter     tailnet:9100   │◀─scrape──│ Grafana Alloy            │─remote──▶│ Prometheus       │
 │   + textfile: llama-engines.prom │          │   built-in node exporter │  write   │ dashboards       │
 │ llama-swap /metrics tailnet:8080 │◀─scrape──│   keep-list              │          │ alerts           │
 └──────────────────────────────────┘          └──────────────────────────┘          └──────────────────┘
```

Why hosted rather than Grafana on the server: an outside alert when the server
itself stops sending, and the dashboard on a phone without the tailnet. The
costs are 14 days of retention and lab metrics leaving the house. Long token
history stays local, in LiteLLM's spend logs.

## Pieces

| Where | What | Code |
|---|---|---|
| Server | Grafana Alloy, pinned and held, from Grafana's apt repo. Scrapes itself and the targets every 60s, filters, remote_writes | `provision/lib/alloy.sh`, `provision/metrics-setup.sh` |
| Server | LiteLLM's Prometheus callback on `127.0.0.1:4000/metrics`: tokens and requests per client key and model, no auth on loopback | `provision/lib/litellm.sh` |
| Every lab target | node_exporter from the Ubuntu archive, on the tailnet address only, with the `drm` (amdgpu) and `systemd` collectors | role `node_metrics` |
| Inference host | `llama-engine-metrics.timer` (30s) copies each loaded model's engine `/metrics` into node_exporter's textfile directory, labelled `model=` | role `inference_host`, `--tags metrics` |
| Inference host | `--metrics` on the llama.cpp fallback, so it exports the same `llamacpp:*` counters as Gufo | `llama-swap.yaml.j2` |

Why the engine copier: each engine listens on 127.0.0.1 on a port llama-swap
picks, so nothing off the box reaches it. llama-swap's
`/upstream/<model>/metrics` passthrough is not used either, because asking for a
model that is not loaded makes llama-swap load it, and a scrape could swap out
the working model. The copier asks `/running` first and reads only models
that are up.

## Setting it up

1. In Grafana Cloud, under **Connections > Hosted Prometheus metrics**, note
   the remote_write URL and the numeric username. Create an access policy with
   `metrics:write` only and a token for it.
2. On the server, write `~/.secrets/grafana-cloud` (mode 600):

   ```sh
   export GCLOUD_PROM_URL=https://prometheus-prod-NN-....grafana.net/api/prom/push
   export GCLOUD_PROM_USER=1234567
   export GCLOUD_RW_TOKEN=glc_...
   ```

   Alloy runs as the `alloy` user and cannot read `~/.secrets`, so
   `install_alloy` copies these into `/etc/default/alloy` (root:alloy, 0640).
   The config itself reads them with `sys.env()` and holds no secret.
3. Targets first, so the server has something to scrape:

   ```sh
   ansible/play inference --tags metrics --check --diff
   ansible/play inference --tags metrics
   ```

   The first full `--tags serve` run after this branch also restarts
   llama-swap (the llama.cpp `--metrics` flag), which unloads the running
   model until it preloads again.
4. Then the server: `./provision/metrics-setup.sh`.
5. Check: `curl -s http://127.0.0.1:12345/-/ready`, Alloy's UI at
   `http://127.0.0.1:12345` (component health, targets), and in Grafana Cloud
   Explore, `up{job=~"node|llama-swap"}`, one series per host and job.
6. The dashboard. In Grafana Cloud, under **Administration > Users and access >
   Service accounts**, add one with the **Editor** role and a token for it.
   On the server, write `~/.secrets/grafana/dashboards.env` (mode 600, no
   `export`, in a subdirectory so shells do not pick it up):

   ```sh
   GRAFANA_URL=https://<stack>.grafana.net
   GRAFANA_SA_TOKEN=glsa_...
   ```

   Then `./provision/grafana-dashboards.sh` (no sudo).

## Dashboard

`grafana/dashboards/lab.json` is **Lab overview** (uid `lab-overview`) in the
**Lab** folder. `provision/grafana-dashboards.sh` pushes every file in
`grafana/dashboards/` with overwrite on, so the JSON is the source of truth: an
edit made in the UI is lost on the next push. To keep one, export the
dashboard JSON over the file and commit it.

| Row | Shows |
|---|---|
| Overview | each host reporting, llama-swap scraped, the loaded model, the client-lab tunnel and `tun0` carrier |
| Models | tokens/s out and in (cached vs processed), engine tok/s, requests in flight and queued, KV cache, speculative acceptance, llama-swap's memory view, engine faults |
| GPU | busy %, GTT used vs size, APU/NVMe temperatures and package power |
| Hosts | CPU, memory available, load per core, PSI pressure, disk free and I/O, network split into physical and tailnet/tunnel |
| Services | a state timeline of every exported systemd unit |

Variables: **Data source** (any `*-prom` source; Grafana Cloud names its own
`grafanacloud-<stack>-prom`) and **Host** (from `up{job="node"}`). The Models
and GPU rows ignore the host filter; they are about the EVO-X2.

`grafana/dashboards/architecture.json` is **Lab architecture** (uid
`lab-architecture`): one Canvas panel that draws the lab as boxes and arrows,
each coloured by a live query. Green is up, red is down, grey is no data or not
measured yet (homeNAS until it has metrics). Unit tiles follow
`node_systemd_unit_state`, the hosts and llama-swap follow `up`, and the arrow
to the client lab follows the OpenVPN unit. The work laptop is left out on
purpose. This file is generated: edit `grafana/architecture.py`, then

```sh
python3 grafana/architecture.py > grafana/dashboards/architecture.json
./provision/grafana-dashboards.sh
```

`grafana/dashboards/local-model-usage.json` is **Local model usage** (uid
`local-model-usage`): a usage page for the local model in the style of
Claude's and Codex's. It reads LiteLLM's own `/metrics` (`job="litellm"`),
so it counts what each client asked for, by its LiteLLM key, where the Lab
overview's Models row counts what the engines did.

| Row | Shows |
|---|---|
| At a glance | input, output and requests for the last 5 hours, today and the last 7 days; what the week would have cost on a paid API |
| Tokens | tokens per day by client and by kind (input, cached input, output), tokens per minute, share by client and by model |
| Requests | a per-client table (requests, tokens, output per request, failures), requests per hour |
| Speed and errors | time to first token and request duration (p50, p95) per model, failed requests by status |

Variables: **Client** (`api_key_alias`) and the comparison prices in dollars
per million tokens (**$/M input**, **$/M cached input**, **$/M output**). The
defaults are placeholders: set them to the API model the local one stands in
for. Changing them in the UI lasts until the next push; change the defaults
in the generator to keep them. Daily bars are UTC days, and nothing looks
back past Grafana Cloud's 14 days.

What LiteLLM exports is set in `prometheus_metrics_config` in
`lib/litellm.sh`: seven metrics, each with only the client, model and status
labels the dashboard uses. The key hash, user and IP labels are left off.
The dashboard is generated too:

```sh
python3 grafana/local_model_usage.py > grafana/dashboards/local-model-usage.json
./provision/grafana-dashboards.sh
```

## The keep-list

`prometheus.relabel "keep"` in `lib/alloy.sh` names every metric that may
leave. A new collector or exporter adds nothing until its metrics are added
there, which is what keeps the lab under the free tier's 10k active series.
After a change, check **Administration > Usage insights** (or the billing
dashboard) a day later.

It also drops container interfaces (`veth*`, `br-*`, `docker0`, `podman*`),
non-disk filesystems, and the transient `activating`/`deactivating` unit
states.

From the client lab only two signals leave: the state of
`openvpn-client@client-env.service` and `tun0`'s carrier. Use those for "is
the tunnel up"; `node_network_up` is always 0 for a tun device, whose
operstate is `unknown`.

## Labels

Every host is `job="node"`, `instance="<short host name>"` (the server's own
target is relabelled to match), so one dashboard variable and one `absent()`
alert cover all of them. llama-swap is `job="llama-swap"`. Engine counters
carry `model="<llama-swap model name>"`. LiteLLM is `job="litellm"`,
`instance="ubuntu-home"`; its counters carry `api_key_alias` (the client),
`requested_model` and `model` (what answered, after any fallback).

## Useful queries

```promql
# server silent: the alert that is the reason for hosting
absent_over_time(up{job="node", instance="ubuntu-home"}[10m])

# tokens generated per second, per model
sum by (model) (rate(llamacpp:tokens_predicted_total[5m]))

# GPU busy and GTT in use on the EVO-X2
node_drm_gpu_busy_percent{instance="evo-x2"}
node_drm_memory_gtt_used_bytes{instance="evo-x2"} / node_drm_memory_gtt_size_bytes{instance="evo-x2"}

# APU temperature
node_hwmon_temp_celsius{instance="evo-x2"} * on (chip, sensor) group_left(label) node_hwmon_sensor_label

# speculative decoding acceptance
rate(llamacpp:spec_decode_num_accepted_tokens_total[15m]) / rate(llamacpp:spec_decode_num_draft_tokens_total[15m])

# local-model tokens per client over the last day
sum by (api_key_alias) (increase(litellm_output_tokens_metric_total[1d]))

# tunnel to the client lab
node_systemd_unit_state{instance="ubuntu-home", name="openvpn-client@client-env.service", state="active"}
```

## Not yet

homeNAS over SNMP, tailnet peer status, herdr agent states, and the alert
rules themselves (set in the Grafana Cloud UI
for now). Tracked on the backlog under the Grafana dashboard item.
