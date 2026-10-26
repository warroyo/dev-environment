#!/usr/bin/env python3
"""Generates grafana/dashboards/architecture.json, the Lab architecture dashboard.

A Canvas panel places every box by percentage, so the JSON is tedious to edit
by hand. Change the layout or queries here, then regenerate and push:

    python3 grafana/architecture.py > grafana/dashboards/architecture.json
    ./provision/grafana-dashboards.sh

Box and arrow colours are bound to query fields by display name (the legend),
so a renamed legend must be renamed in the layout too. A box whose field has no
data falls back to its fixed grey.
"""
import json
import sys

DS = {"type": "prometheus", "uid": "${datasource}"}
GREY = "#5a5f66"
HOST = "#2b2f36"
CLIENT = "#2f5d8a"
CLOUD = "#7a4fb0"
TEXT = "#e6e6e6"
DIM = "#a8adb5"

elements = []


def place(x, y, w, h):
    # Percent placement on both axes, so the diagram scales with the panel.
    return (
        {"left": x, "right": 100 - x - w, "top": y, "bottom": 100 - y - h},
        {"horizontal": "scale", "vertical": "scale"},
    )


def color(fixed, field=None):
    c = {"fixed": fixed}
    if field:
        c["field"] = field
    return c


def box(name, x, y, w, h, text="", bg=GREY, field=None, size=14, valign="middle",
        align="center", text_color=TEXT, radius=6, border=None, connections=None):
    p, c = place(x, y, w, h)
    el = {
        "type": "rectangle",
        "name": name,
        "config": {
            "text": {"mode": "fixed", "fixed": text},
            "color": {"fixed": text_color},
            "size": size,
            "align": align,
            "valign": valign,
        },
        "background": {"color": color(bg, field)},
        "border": {"color": {"fixed": border or "transparent"}, "width": 1 if border else 0,
                   "radius": radius},
        "placement": p,
        "constraint": c,
        "connections": connections or [],
    }
    elements.append(el)
    return el


def value(name, x, y, w, h, field, size=13, text_color=TEXT, align="center"):
    p, c = place(x, y, w, h)
    elements.append({
        "type": "metric-value",
        "name": name,
        "config": {
            "text": {"mode": "field", "field": field, "fixed": ""},
            "color": {"fixed": text_color},
            "size": size,
            "align": align,
            "valign": "middle",
        },
        "background": {"color": {"fixed": "transparent"}},
        "border": {"color": {"fixed": "transparent"}},
        "placement": p,
        "constraint": c,
        "connections": [],
    })


def link(target, sx, sy, tx, ty, field=None, fixed=DIM, size=2):
    return {
        "source": {"x": sx, "y": sy},
        "target": {"x": tx, "y": ty},
        "targetName": target,
        "path": "straight",
        "color": color(fixed, field),
        "size": {"fixed": size, "min": 1, "max": 10},
    }


UH = "ubuntu-home "
EV = "evo-x2 "

# --- Clients -----------------------------------------------------------------
# Each client sits above what it connects to, so the arrows run straight down.
# The work laptop is left out on purpose: it is outside the lab.
box("MacBook Air", 3, 2, 15, 9, "MacBook Air · tailnet", bg=CLIENT,
    connections=[link("ubuntu-home", 0, -1, -0.72, 1)])
box("Phone", 35.1, 2, 14.5, 9, "Phone · Telegram", bg=CLIENT,
    connections=[link("telegram-bot", 0, -1, 0, 1, field=UH + "claude-telegram-bot.service")])

# --- Off-box -----------------------------------------------------------------
box("Grafana Cloud", 74, 2, 23, 9, "Grafana Cloud", bg=CLOUD)
box("Client lab", 74, 32, 23, 12, "Client lab (tun0)", bg=GREY, field="tun0")
box("homeNAS", 74, 66, 23, 12, "homeNAS · no metrics yet", bg=GREY, size=13)

# --- ubuntu-home ---------------------------------------------------------------
box("ubuntu-home", 2, 17, 64, 38, "", bg=HOST, border=GREY)
box("ubuntu-home status", 3.5, 18.5, 22, 6, "ubuntu-home · agent host", bg=GREY,
    field="ubuntu-home", size=14)

# Grid of 4 columns. Placement is chosen so every arrow leaves the box on the
# side facing its target: Alloy top right toward Grafana Cloud, OpenVPN on the
# right edge toward the client lab, LiteLLM bottom left above llama-swap,
# tailscaled bottom row above evo-x2.
chips = {
    (0, 0): ("agents", "Claude Code · Codex", None),
    (1, 0): ("herdr", "herdr-server", UH + "herdr-server.service"),
    (2, 0): ("telegram-bot", "claude-telegram-bot", UH + "claude-telegram-bot.service"),
    (3, 0): ("alloy", "Alloy", UH + "alloy.service"),
    (0, 1): ("dnsmasq", "dnsmasq split DNS", UH + "dnsmasq.service"),
    (1, 1): ("docker", "docker", UH + "docker.service"),
    (2, 1): ("lab-routing", "lab-routing", UH + "lab-routing.service"),
    (3, 1): ("openvpn", "OpenVPN client-env", UH + "openvpn-client@client-env.service"),
    (0, 2): ("litellm", "LiteLLM :4000", UH + "litellm.service"),
    (1, 2): ("uh-tailscaled", "tailscaled", UH + "tailscaled.service"),
}
cx, cy, cw, ch, gap = 3.5, 27, 14.5, 7.5, 1.3
for (col, row), (name, label, field) in chips.items():
    conns = []
    if name == "litellm":
        conns = [link("llama-swap", 0, -1, -0.34, 1, field="llama-swap", size=3)]
    if name == "alloy":
        conns = [link("Grafana Cloud", 1, 0, -1, -1, field=UH + "alloy.service")]
    if name == "openvpn":
        conns = [link("Client lab", 1, 0, -1, 0, field=UH + "openvpn-client@client-env.service", size=3)]
    if name == "uh-tailscaled":
        conns = [link("evo-x2", 0, -1, -0.233, 1, field=EV + "tailscaled.service", size=3)]
    box(name, cx + col * (cw + gap), cy + row * (ch + gap), cw, ch, label,
        bg="#6b4fa0" if field is None else GREY, field=field, size=12, connections=conns)

row2 = cy + 2 * (ch + gap)
box("ubuntu-home cpu label", 34.1, row2, 7, ch, "CPU", bg="transparent", size=11,
    text_color=DIM, align="right")
value("ubuntu-home cpu", 41.1, row2, 7.5, ch, "ubuntu-home CPU", size=16)
box("ubuntu-home mem label", 49.6, row2, 8, ch, "memory free", bg="transparent", size=11,
    text_color=DIM, align="right")
value("ubuntu-home mem", 57.6, row2, 7.5, ch, "ubuntu-home memory free", size=16)

# --- evo-x2 --------------------------------------------------------------------
box("evo-x2", 2, 61, 64, 37, "", bg=HOST, border=GREY)
box("llama-swap", 3.5, 63, 22, 7, "llama-swap :8080", bg=GREY, field="llama-swap", size=13)
box("evo-x2 status", 28, 63, 17.5, 7, "evo-x2 · inference", bg=GREY, field="evo-x2", size=13)
for i, (name, label, field) in enumerate([
    ("node-exporter", "node_exporter", EV + "prometheus-node-exporter.service"),
    ("ev-tailscaled", "tailscaled", EV + "tailscaled.service"),
]):
    box(name, 47, 63 + i * 3.7, 17.5, 3.3, label, bg=GREY, field=field, size=10)


def stat(field, label, x, y, w=17.5, size=18):
    box(field + " label", x, y, w, 4, label, bg="transparent", size=11, text_color=DIM)
    value(field, x, y + 4, w, 6, field, size=size)


stat("model", "loaded model", 3.5, 72, w=22, size=14)
stat("generated tok/s", "generated tok/s (5m)", 3.5, 82.5, w=22, size=16)
stat("GPU temp", "GPU temp", 28, 72)
stat("GPU busy", "GPU busy", 47, 72)
stat("GTT used", "GTT used", 28, 84)
stat("evo-x2 memory free", "memory free", 47, 84)
box("evo-x2 caption", 3.5, 93, 22, 4, "model API over the tailnet · no internet",
    bg="transparent", size=10, text_color=DIM)


# --- Queries -------------------------------------------------------------------
def q(ref, expr, legend, fmt="time_series"):
    return {"refId": ref, "datasource": DS, "expr": expr, "legendFormat": legend,
            "instant": True, "range": False, "format": fmt}

targets = [
    q("A", 'max by (instance) (up{job="node",instance=~"ubuntu-home|evo-x2"})', "{{instance}}"),
    q("B", 'max(up{job="llama-swap"})', "llama-swap"),
    q("C", 'max by (instance, name) (node_systemd_unit_state{state="active",instance=~"ubuntu-home|evo-x2"})',
      "{{instance}} {{name}}"),
    q("D", 'max(node_network_carrier{instance="ubuntu-home",device="tun0"})', "tun0"),
    q("E", 'max by (model) (llama_engine_up{state="ready"} == 1)', "", fmt="table"),
    q("F", 'max(node_hwmon_temp_celsius{instance="evo-x2"} * on (instance, chip) group_left (chip_name) node_hwmon_chip_names{chip_name="amdgpu"})', "GPU temp"),
    q("G", 'max(node_drm_gpu_busy_percent{instance="evo-x2"})', "GPU busy"),
    q("H", 'sum(node_drm_memory_gtt_used_bytes{instance="evo-x2"}) / sum(node_drm_memory_gtt_size_bytes{instance="evo-x2"})', "GTT used"),
    q("I", 'node_memory_MemAvailable_bytes{instance="evo-x2"} / node_memory_MemTotal_bytes{instance="evo-x2"}', "evo-x2 memory free"),
    q("J", '1 - avg(rate(node_cpu_seconds_total{mode="idle",instance="ubuntu-home"}[5m]))', "ubuntu-home CPU"),
    q("K", 'node_memory_MemAvailable_bytes{instance="ubuntu-home"} / node_memory_MemTotal_bytes{instance="ubuntu-home"}', "ubuntu-home memory free"),
    q("L", 'sum(rate(llamacpp:tokens_predicted_total[5m]))', "generated tok/s"),
]

status_thresholds = {"mode": "absolute", "steps": [
    {"color": "#c4314b", "value": None}, {"color": "#2e8b57", "value": 1}]}

def override(name, props, regex=False):
    return {"matcher": {"id": "byRegexp" if regex else "byName", "options": name},
            "properties": [{"id": k, "value": v} for k, v in props]}

overrides = [
    override(r"^(ubuntu-home|evo-x2|llama-swap|tun0)$|\.service$|\.timer$|\.socket$",
             [("thresholds", status_thresholds), ("color", {"mode": "thresholds"})], regex=True),
    override("GPU temp", [("unit", "celsius"), ("decimals", 0)]),
    override("GPU busy", [("unit", "percent"), ("decimals", 0)]),
    override("GTT used", [("unit", "percentunit"), ("decimals", 0)]),
    override("evo-x2 memory free", [("unit", "percentunit"), ("decimals", 0)]),
    override("ubuntu-home CPU", [("unit", "percentunit"), ("decimals", 0)]),
    override("ubuntu-home memory free", [("unit", "percentunit"), ("decimals", 0)]),
    override("generated tok/s", [("unit", "none"), ("decimals", 1)]),
]

panel = {
    "id": 1,
    "type": "canvas",
    "title": "Lab architecture",
    "description": "Live status of the lab. Green: up, red: down, grey: no data or not measured yet. "
                   "Layout follows the lab-architecture note in the vault.",
    "datasource": DS,
    "gridPos": {"h": 28, "w": 24, "x": 0, "y": 0},
    "targets": targets,
    "fieldConfig": {
        "defaults": {"color": {"mode": "fixed", "fixedColor": TEXT},
                     "thresholds": {"mode": "absolute", "steps": [{"color": TEXT, "value": None}]}},
        "overrides": overrides,
    },
    "options": {
        "inlineEditing": False,
        "showAdvancedTypes": True,
        "panZoom": False,
        "infinitePan": False,
        "root": {
            "type": "frame",
            "name": "Element root",
            "elements": elements,
            "background": {"color": {"fixed": "transparent"}},
            "border": {"color": {"fixed": "dark-green"}},
            "constraint": {"horizontal": "left", "vertical": "top"},
            "placement": {"left": 0, "top": 0, "width": 100, "height": 100},
        },
    },
}

dash = {
    "title": "Lab architecture",
    "uid": "lab-architecture",
    "tags": ["lab", "dev-environment"],
    "timezone": "browser",
    "schemaVersion": 39,
    "refresh": "30s",
    "time": {"from": "now-15m", "to": "now"},
    "editable": True,
    "graphTooltip": 0,
    "templating": {"list": [{
        "name": "datasource", "type": "datasource", "query": "prometheus",
        "label": "Data source", "current": {}, "hide": 0, "refresh": 1, "regex": ".*-prom$",
    }]},
    "annotations": {"list": []},
    "links": [{"title": "Lab overview", "type": "link", "url": "/d/lab-overview", "icon": "dashboard"}],
    "panels": [panel],
}

json.dump(dash, sys.stdout, indent=2)
print()
