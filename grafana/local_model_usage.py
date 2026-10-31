#!/usr/bin/env python3
"""Generates grafana/dashboards/local-model-usage.json, the Local model usage dashboard.

A usage page for the local model, in the spirit of Claude's and Codex's: tokens
in the last 5 hours, today and this week, per day and per client, and what the
same tokens would have cost on a paid API. The data is LiteLLM's /metrics
(provision/lib/litellm.sh), scraped by Alloy as job="litellm". Every client has
its own LiteLLM key, and api_key_alias is that key's name.

    python3 grafana/local_model_usage.py > grafana/dashboards/local-model-usage.json
    ./provision/grafana-dashboards.sh

Embedding models (mode: embedding in ansible/group_vars/inference.yml, and
their aliases such as local-embed) have their own row: their tokens are
input-only and priced far below chat tokens, so every other panel leaves
them out.

Grafana Cloud keeps 14 days, so nothing here looks further back. LiteLLM's
spend logs in Postgres hold the full history.
"""
import json
import pathlib

import yaml

DS = {"type": "prometheus", "uid": "${datasource}"}

IN = "litellm_input_tokens_metric_total"
OUT = "litellm_output_tokens_metric_total"
CACHED = "litellm_input_cached_tokens_metric_total"
REQS = "litellm_proxy_total_requests_metric_total"
FAILS = "litellm_proxy_failed_requests_metric_total"
LATENCY = "litellm_request_total_latency_metric"
TTFT = "litellm_llm_api_time_to_first_token_metric"

# Embedding model names as clients request them, from the file that also drives
# llama-swap and LiteLLM.
_vars = yaml.safe_load((pathlib.Path(__file__).resolve().parent.parent
                        / "ansible/group_vars/inference.yml").read_text())
EMBED_NAMES = sorted(
    name
    for n, m in (_vars.get("llama_swap_models") or {}).items() if m.get("mode") == "embedding"
    for name in (n, m.get("alias")) if name
)
EMBED_RE = "|".join(EMBED_NAMES) or "^$"
# Chat traffic only; every panel outside the Embeddings row uses this.
SEL = f'{{api_key_alias=~"$client",requested_model!~"{EMBED_RE}"}}'
SEL_EMBED = f'{{api_key_alias=~"$client",requested_model=~"{EMBED_RE}"}}'

# One fixed colour per client, so a client keeps its colour when the client
# filter hides others. Add a client here when it is added to LITELLM_CLIENTS.
CLIENT_COLORS = {
    "hermes-lab": "blue",
    "hermes-restricted": "purple",
    "scripts": "orange",
    "content-curator": "green",
}

panels = []
_next_id = [1]


def pid():
    _next_id[0] += 1
    return _next_id[0]


def q(expr, legend="", ref="A", instant=False, fmt=None):
    t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": ref}
    if instant:
        t.update(instant=True, range=False)
    if fmt:
        t["format"] = fmt
    return t


def inc(metric, rng, by="", sel=None, ahead=False):
    # increase() that also counts a series' first value. LiteLLM creates a
    # counter on its first request, already holding that request's tokens, and
    # increase() only counts growth between samples, so a new client or model
    # would lose its first request (often the only one). A series that did not
    # exist at the start of the window gets its first value (min_over_time;
    # counters only grow) added.
    #
    # ahead=True looks forward from the evaluation time instead of back, for
    # bar panels. Grafana aligns a step to multiples of itself, so a 1d step
    # evaluates at UTC midnight: looking back, each bar holds the day before
    # its timestamp and the current day has no point until it is over.
    m = f"{metric}{sel or SEL}"
    grp = f"sum by ({by}) " if by else "sum "
    if ahead:
        w = f"[{rng}] offset -{rng}"
        return (f"{grp}(increase({m}{w})"
                f" + (min_over_time({m}{w}) unless {m})"
                f" or increase({m}{w}))")
    return (f"{grp}(increase({m}[{rng}])"
            f" + (min_over_time({m}[{rng}]) unless {m} offset {rng})"
            f" or increase({m}[{rng}]))")


def tokens(metric, rng, sel=None, ahead=False):
    # "or vector(0)": the cached counter only exists once a request reported
    # cached tokens, and an empty side would blank the whole expression.
    return f"({inc(metric, rng, sel=sel, ahead=ahead)} or vector(0))"


def client_overrides():
    return [
        {"matcher": {"id": "byName", "options": name},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
        for name, c in CLIENT_COLORS.items()
    ]


def row(title, y):
    panels.append({"type": "row", "title": title, "id": pid(), "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})


def stat(title, targets, x, y, w=6, h=5, unit="short", time_from=None, desc="",
         decimals=None):
    p = {
        "type": "stat", "title": title, "id": pid(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "fixed", "fixedColor": "text"}},
                        "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "none", "graphMode": "none", "textMode": "value_and_name",
            "justifyMode": "center", "orientation": "vertical",
        },
        "description": desc,
    }
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    if time_from:
        p["timeFrom"] = time_from
        p["hideTimeOverride"] = False
    panels.append(p)


def bars(title, targets, x, y, w, h, interval, desc="", unit="short", overrides=None,
         time_from=None):
    # Queries here use inc(..., ahead=True): a point holds the bucket that
    # starts at its timestamp, so the bar is drawn after it.
    p = {
        "type": "timeseries", "title": title, "id": pid(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "interval": interval,
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "unit": unit, "min": 0,
                "custom": {"drawStyle": "bars", "barAlignment": 1, "lineWidth": 1,
                           "fillOpacity": 80, "showPoints": "never",
                           "stacking": {"mode": "normal", "group": "A"}},
            },
            "overrides": overrides or [],
        },
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "description": desc,
    }
    if time_from:
        # A range shorter than a bucket would hold no bucket start.
        p["timeFrom"] = time_from
        p["hideTimeOverride"] = False
    panels.append(p)


def lines(title, targets, x, y, w, h, unit="short", desc="", overrides=None, stack=False):
    panels.append({
        "type": "timeseries", "title": title, "id": pid(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "unit": unit, "min": 0,
                "custom": {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never",
                           "stacking": {"mode": "normal" if stack else "none", "group": "A"}},
            },
            "overrides": overrides or [],
        },
        "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "description": desc,
    })


def share(title, expr, legend, x, y, w, h, desc="", overrides=None):
    panels.append({
        "type": "bargauge", "title": title, "id": pid(), "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [q(expr, legend, instant=True)],
        "fieldConfig": {"defaults": {"unit": "short", "min": 0,
                                     "color": {"mode": "palette-classic"}},
                        "overrides": overrides or []},
        "options": {"orientation": "horizontal", "displayMode": "basic",
                    "showUnfilled": True, "valueMode": "text",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        "description": desc,
    })


# ---- At a glance -------------------------------------------------------------

y = 0
row("At a glance", y)
y += 1


def window_tiles(title, rng_from, x, desc):
    stat(title, [
        q(tokens(IN, "$__range"), "Input", "A", instant=True),
        q(tokens(OUT, "$__range"), "Output", "B", instant=True),
        q(f"{tokens(REQS, '$__range')}", "Requests", "C", instant=True),
    ], x, y, time_from=rng_from, desc=desc)


window_tiles("Last 5 hours", "5h", 0,
             "Tokens and requests in the last 5 hours, the length of a Claude usage window.")
window_tiles("Today", "now/d", 6, "Since midnight, browser time.")
window_tiles("Last 7 days", "7d", 12, "The rolling week.")
stat("Cloud-equivalent, last 7 days", [
    q(f"({tokens(IN, '$__range')} - {tokens(CACHED, '$__range')}) * $price_in / 1e6"
      f" + {tokens(CACHED, '$__range')} * $price_cached / 1e6"
      f" + {tokens(OUT, '$__range')} * $price_out / 1e6",
      "At your comparison prices", instant=True),
], 18, y, unit="currencyUSD", time_from="7d", decimals=2,
    desc="What this week's local tokens would cost at the per-million prices in the "
         "dashboard variables (input, cached input, output). Set them to the API "
         "model you would otherwise use. The electricity is not counted.")
y += 5

# ---- Tokens ------------------------------------------------------------------

row("Tokens", y)
y += 1
bars("Tokens per day, by client", [
    q(f"{inc(IN, '$__interval', 'api_key_alias', ahead=True)}"
      f" + {inc(OUT, '$__interval', 'api_key_alias', ahead=True)}",
      "{{api_key_alias}}"),
], 0, y, 12, 9, "1d", overrides=client_overrides(), time_from="7d",
    desc="Input plus output tokens per day, stacked by LiteLLM key. Days are UTC.")
bars("Tokens per day, by kind", [
    q(f"{tokens(IN, '$__interval', ahead=True)} - {tokens(CACHED, '$__interval', ahead=True)}",
      "Input", "A"),
    q(tokens(CACHED, "$__interval", ahead=True), "Cached input", "B"),
    q(tokens(OUT, "$__interval", ahead=True), "Output", "C"),
], 12, y, 12, 9, "1d", time_from="7d",
    desc="Input the model had to process, input served from the prompt cache, and "
         "output. Days are UTC.")
y += 9
lines("Activity, tokens per minute", [
    q(f"sum by (api_key_alias) (rate({IN}{SEL}[$__rate_interval])) * 60",
      "{{api_key_alias}} in", "A"),
    q(f"sum by (api_key_alias) (rate({OUT}{SEL}[$__rate_interval])) * 60",
      "{{api_key_alias}} out", "B"),
], 0, y, 12, 8,
    desc="Input and output tokens per minute by client, to see when the model was busy.")
share("By client", f"{inc(IN, '$__range', 'api_key_alias')}"
      f" + {inc(OUT, '$__range', 'api_key_alias')}",
      "{{api_key_alias}}", 12, y, 6, 8, overrides=client_overrides(),
      desc="Input plus output tokens over the dashboard's time range.")
share("By model", f"{inc(IN, '$__range', 'model')}"
      f" + {inc(OUT, '$__range', 'model')}",
      "{{model}}", 18, y, 6, 8,
      desc="The model that answered (after any fallback), over the dashboard's time range.")
y += 8

# ---- Requests ----------------------------------------------------------------

row("Requests", y)
y += 1


def tq(expr, ref):
    return q(expr, "", ref, instant=True, fmt="table")


panels.append({
    "type": "table", "title": "Per client", "id": pid(), "datasource": DS,
    "gridPos": {"h": 8, "w": 12, "x": 0, "y": y},
    "targets": [
        tq(f"{inc(REQS, '$__range', 'api_key_alias')}", "A"),
        tq(f"{inc(IN, '$__range', 'api_key_alias')}", "B"),
        tq(f"{inc(CACHED, '$__range', 'api_key_alias')}", "C"),
        tq(f"{inc(OUT, '$__range', 'api_key_alias')}", "D"),
        tq(f"{inc(OUT, '$__range', 'api_key_alias')}"
           f" / {inc(REQS, '$__range', 'api_key_alias')}", "E"),
        tq(f"{inc(FAILS, '$__range', 'api_key_alias')}", "F"),
    ],
    "transformations": [
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True},
            "renameByName": {"api_key_alias": "Client", "Value #A": "Requests",
                             "Value #B": "Input", "Value #C": "Cached input",
                             "Value #D": "Output", "Value #E": "Output / request",
                             "Value #F": "Failed"}}},
        {"id": "sortBy", "options": {"sort": [{"field": "Output", "desc": True}]}},
    ],
    "fieldConfig": {"defaults": {"unit": "short", "decimals": 0}, "overrides": []},
    "options": {"showHeader": True, "cellHeight": "sm"},
    "description": "Over the dashboard's time range.",
})
bars("Requests per hour, by client", [
    q(f"{inc(REQS, '$__interval', 'api_key_alias', ahead=True)}", "{{api_key_alias}}"),
], 12, y, 12, 8, "1h", overrides=client_overrides())
y += 8

# ---- Speed -------------------------------------------------------------------

row("Speed and errors", y)
y += 1


def quantile(metric, qv, sel=None):
    return (f"histogram_quantile({qv}, sum by (le, requested_model) "
            f"(rate({metric}_bucket{sel or SEL}[$__rate_interval])))")


lines("Time to first token", [
    q(quantile(TTFT, 0.5), "p50 {{requested_model}}", "A"),
    q(quantile(TTFT, 0.95), "p95 {{requested_model}}", "B"),
], 0, y, 8, 8, unit="s",
    desc="Streaming requests only. A long spike is usually llama-swap loading a model.")
lines("Request duration", [
    q(quantile(LATENCY, 0.5), "p50 {{requested_model}}", "A"),
    q(quantile(LATENCY, 0.95), "p95 {{requested_model}}", "B"),
], 8, y, 8, 8, unit="s", desc="Whole request through LiteLLM, as the client sees it.")
lines("Failed requests", [
    q(f"{inc(FAILS, '$__rate_interval', 'exception_status')}",
      "{{exception_status}}"),
], 16, y, 8, 8, stack=True,
    desc="Failures per scrape interval by HTTP status. Engine-side faults are on Lab overview.")
y += 8

# ---- Embeddings --------------------------------------------------------------

row("Embeddings", y)
y += 1
E = SEL_EMBED
stat("Embedding tokens", [
    q(tokens(IN, "$__range", E), "Today", "A", instant=True),
], 0, y, w=4, time_from="now/d", desc="Tokens embedded since midnight, browser time.")
stat("Embedding tokens, 7 days", [
    q(tokens(IN, "$__range", E), "Tokens", "A", instant=True),
    q(tokens(REQS, "$__range", E), "Requests", "B", instant=True),
], 4, y, w=4, time_from="7d")
stat("Cloud-equivalent embeddings, 7 days", [
    q(f"{tokens(IN, '$__range', E)} * $price_embed / 1e6", "At $/M embed", instant=True),
], 8, y, w=4, unit="currencyUSD", time_from="7d", decimals=4,
    desc="This week's embedding tokens at the $/M embed variable, an embedding API's "
         "price. Embeddings are cheap: this is mostly for scale.")
lines("Embedding request duration", [
    q(quantile(LATENCY, 0.5, E), "p50 {{requested_model}}", "A"),
    q(quantile(LATENCY, 0.95, E), "p95 {{requested_model}}", "B"),
], 12, y, 12, 5, unit="s",
    desc="Whole request through LiteLLM. One request can carry a batch of texts.")
y += 5
bars("Embedding tokens per day, by client", [
    q(f"{inc(IN, '$__interval', 'api_key_alias', sel=E, ahead=True)}", "{{api_key_alias}}"),
], 0, y, 12, 8, "1d", overrides=client_overrides(), time_from="7d",
    desc="Input tokens sent to embedding models per day, by LiteLLM key. Days are UTC.")
lines("Failed embedding requests", [
    q(f"{inc(FAILS, '$__rate_interval', 'exception_status', sel=E)}", "{{exception_status}}"),
], 12, y, 12, 8, stack=True,
    desc="Failures per scrape interval by HTTP status.")
y += 8

dashboard = {
    "uid": "local-model-usage",
    "title": "Local model usage",
    "description": "Token usage on the local models through LiteLLM, per client and model, "
                   "chat and embeddings apart. "
                   "Generated by dev-environment grafana/local_model_usage.py; edits in the UI "
                   "are overwritten by the next push.",
    "tags": ["lab", "dev-environment", "local-ai"],
    "timezone": "browser",
    "editable": True,
    "graphTooltip": 1,
    "refresh": "5m",
    "time": {"from": "now-7d", "to": "now"},
    "schemaVersion": 39,
    "templating": {"list": [
        {"name": "datasource", "label": "Data source", "type": "datasource",
         "query": "prometheus", "regex": ".*-prom$", "current": {}, "hide": 0},
        {"name": "client", "label": "Client", "type": "query", "datasource": DS,
         "query": {"query": f"label_values({REQS}, api_key_alias)", "refId": "client"},
         "definition": f"label_values({REQS}, api_key_alias)",
         "includeAll": True, "multi": True, "allValue": ".*",
         "current": {"text": "All", "value": "$__all"}, "refresh": 2, "sort": 1, "hide": 0},
        {"name": "price_in", "label": "$/M input", "type": "textbox",
         "query": "3", "current": {"text": "3", "value": "3"}, "hide": 0},
        {"name": "price_cached", "label": "$/M cached input", "type": "textbox",
         "query": "0.3", "current": {"text": "0.3", "value": "0.3"}, "hide": 0},
        {"name": "price_out", "label": "$/M output", "type": "textbox",
         "query": "15", "current": {"text": "15", "value": "15"}, "hide": 0},
        {"name": "price_embed", "label": "$/M embed", "type": "textbox",
         "query": "0.02", "current": {"text": "0.02", "value": "0.02"}, "hide": 0},
    ]},
    "annotations": {"list": []},
    "links": [{"title": "Lab overview", "type": "dashboards", "tags": [],
               "url": "/d/lab-overview", "targetBlank": False, "asDropdown": False,
               "includeVars": False, "keepTime": True, "icon": "dashboard"}],
    "panels": panels,
}

print(json.dumps(dashboard, indent=2))
