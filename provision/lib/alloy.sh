#!/usr/bin/env bash
# Grafana Alloy: collects the lab's metrics on this box and ships them to
# Grafana Cloud with Prometheus remote_write (docs/lab-metrics.md).
#
#   install_alloy   adds Grafana's apt repo, installs the pinned Alloy, writes
#                   its config and credentials, and (re)starts it
#
# Expects the caller to have defined `log` and `$SUDO`, same as lib/litellm.sh.
#
# SHAPE
#
# Alloy is the only thing in the lab that talks to Grafana Cloud. It scrapes
# this box with its built-in node exporter, and the lab targets over the
# tailnet: node_exporter on :9100 and llama-swap's /metrics on :8080 (both
# from the Ansible roles node_metrics and inference_host), plus LiteLLM's
# /metrics on this box (lib/litellm.sh), and the content curator's on
# :8090 (lib/content-curator.sh). The EVO-X2 keeps its
# no-internet rule; if this box stops sending, Grafana Cloud's absent alert is
# the outside signal.
#
# Everything goes through one keep-list (prometheus.relabel "keep") before it
# leaves, so a new exporter or collector adds nothing until a metric is named
# here. The free tier is 10k active series.
#
# What never leaves: anything from the client lab beyond whether the tunnel is
# up (the openvpn-client@client-env unit and tun0's carrier). No hostnames or
# addresses from that side.
#
# SECRETS
#
# ~/.secrets/grafana-cloud, written by hand once from the Grafana Cloud stack
# page (Connections > Hosted Prometheus metrics):
#
#   export GCLOUD_PROM_URL=https://prometheus-prod-NN-....grafana.net/api/prom/push
#   export GCLOUD_PROM_USER=<numeric username>
#   export GCLOUD_RW_TOKEN=glc_...     # access policy with metrics:write only
#
# Alloy runs as the `alloy` system user, which cannot read ~/.secrets, so the
# three values are copied into /etc/default/alloy (root:alloy 0640), the
# package's EnvironmentFile. The config reads them with sys.env() and holds no
# secret, so it can be printed and diffed freely.

# Pinned: apt.grafana.com ships a new Alloy every few weeks, and a config
# component can change between minors. Bump deliberately, and the hold below
# keeps unattended-upgrades from doing it for you.
ALLOY_VERSION="${ALLOY_VERSION:-1.21.2-1}"
ALLOY_SECRETS="${ALLOY_SECRETS:-$HOME/.secrets/grafana-cloud}"
ALLOY_CONFIG=/etc/alloy/config.alloy
ALLOY_DEFAULTS=/etc/default/alloy
# Alloy's own UI and /metrics, on loopback only.
ALLOY_LISTEN="${ALLOY_LISTEN:-127.0.0.1:12345}"
# Lab targets running node_exporter (role node_metrics), by MagicDNS short
# name so the public repo holds no addresses.
ALLOY_NODE_TARGETS="${ALLOY_NODE_TARGETS:-evo-x2}"
# Hosts running llama-swap on :8080.
ALLOY_LLAMA_SWAP_TARGETS="${ALLOY_LLAMA_SWAP_TARGETS:-evo-x2}"
# LiteLLM's /metrics on this box (lib/litellm.sh): tokens per client and model.
ALLOY_LITELLM_ADDR="${ALLOY_LITELLM_ADDR:-127.0.0.1:4000}"
# The content curator's /metrics on this box (lib/content-curator.sh).
ALLOY_CURATOR_ADDR="${ALLOY_CURATOR_ADDR:-127.0.0.1:8090}"
# This box's services whose state is exported. Units that are not installed
# are simply absent.
ALLOY_UNITS="${ALLOY_UNITS:-tailscaled docker dnsmasq lab-routing openvpn-client@client-env litellm content-curator herdr-server claude-telegram-bot alloy}"

# install_alloy
#
# Idempotent. Rewrites the config and the defaults file every run, restarts
# Alloy only when one of them changed. Returns non-zero, leaving the running
# Alloy alone, if the secrets are missing or the new config fails
# `alloy validate`.
install_alloy() {
  local changed=0 tmp

  if [ ! -r "$ALLOY_SECRETS" ]; then
    log "  WARNING: ${ALLOY_SECRETS} is missing — skipping Alloy."
    log "           Create it from the Grafana Cloud stack page; see docs/lab-metrics.md."
    return 1
  fi
  local url user token
  # shellcheck disable=SC1090
  url="$(. "$ALLOY_SECRETS" && printf '%s' "${GCLOUD_PROM_URL:-}")"
  # shellcheck disable=SC1090
  user="$(. "$ALLOY_SECRETS" && printf '%s' "${GCLOUD_PROM_USER:-}")"
  # shellcheck disable=SC1090
  token="$(. "$ALLOY_SECRETS" && printf '%s' "${GCLOUD_RW_TOKEN:-}")"
  if [ -z "$url" ] || [ -z "$user" ] || [ -z "$token" ]; then
    log "  WARNING: ${ALLOY_SECRETS} needs GCLOUD_PROM_URL, GCLOUD_PROM_USER and GCLOUD_RW_TOKEN — skipping Alloy."
    return 1
  fi

  _alloy_install_package || return 1

  # Config first: if it does not validate, stop before touching anything live.
  tmp="$(mktemp)"
  _alloy_config >"$tmp"
  if ! alloy validate "$tmp"; then
    log "  WARNING: the generated Alloy config does not validate (above) — not installed."
    rm -f "$tmp"
    return 1
  fi
  if ! $SUDO cmp -s "$tmp" "$ALLOY_CONFIG" 2>/dev/null; then
    $SUDO install -o root -g root -m 0644 "$tmp" "$ALLOY_CONFIG"
    changed=1
  fi
  rm -f "$tmp"

  tmp="$(mktemp)"
  chmod 600 "$tmp"
  cat >"$tmp" <<EOF
# Managed by dev-environment/provision/lib/alloy.sh — do not edit by hand.
# Credentials are copied from ${ALLOY_SECRETS}; change them there and re-run.
CONFIG_FILE="${ALLOY_CONFIG}"
CUSTOM_ARGS="--server.http.listen-addr=${ALLOY_LISTEN} --disable-reporting"
RESTART_ON_UPGRADE=true
GCLOUD_PROM_URL="${url}"
GCLOUD_PROM_USER="${user}"
GCLOUD_RW_TOKEN="${token}"
EOF
  if ! $SUDO cmp -s "$tmp" "$ALLOY_DEFAULTS" 2>/dev/null; then
    $SUDO install -o root -g alloy -m 0640 "$tmp" "$ALLOY_DEFAULTS"
    changed=1
  fi
  rm -f "$tmp"

  $SUDO systemctl enable alloy.service >/dev/null 2>&1 || true
  if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet alloy.service; then
    log "  (re)starting alloy.service"
    if ! $SUDO systemctl restart alloy.service; then
      log "  WARNING: alloy.service failed — check 'journalctl -u alloy'."
      return 1
    fi
  else
    log "  Alloy config already current"
  fi

  if ! _alloy_wait_ready; then
    log "  WARNING: Alloy did not become ready on ${ALLOY_LISTEN} — check 'journalctl -u alloy'."
    return 1
  fi
  log "  Alloy ready; UI on http://${ALLOY_LISTEN} (component health, live targets)"
}

# _alloy_install_package
#
# Grafana's apt repo, signed-by its own keyring rather than trusted for every
# repo, then the pinned version, held.
_alloy_install_package() {
  local keyring=/etc/apt/keyrings/grafana.gpg list=/etc/apt/sources.list.d/grafana.list
  local apt_get="$SUDO apt-get -o DPkg::Lock::Timeout=600"

  if [ ! -s "$keyring" ]; then
    log "  adding Grafana's apt key"
    $SUDO install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor | $SUDO tee "$keyring" >/dev/null
    $SUDO chmod 644 "$keyring"
  fi
  local line="deb [signed-by=${keyring}] https://apt.grafana.com stable main"
  if [ "$(cat "$list" 2>/dev/null)" != "$line" ]; then
    echo "$line" | $SUDO tee "$list" >/dev/null
    $apt_get update -qq
  fi

  if [ "$(dpkg-query -W -f='${Version}' alloy 2>/dev/null)" = "$ALLOY_VERSION" ]; then
    log "  Alloy ${ALLOY_VERSION} already installed"
  else
    log "  installing Alloy ${ALLOY_VERSION}"
    $SUDO apt-mark unhold alloy >/dev/null 2>&1 || true
    if ! $apt_get install -y -qq --allow-downgrades "alloy=${ALLOY_VERSION}"; then
      $apt_get update -qq
      $apt_get install -y -qq --allow-downgrades "alloy=${ALLOY_VERSION}" || {
        log "  WARNING: could not install alloy=${ALLOY_VERSION}"
        return 1
      }
    fi
  fi
  $SUDO apt-mark hold alloy >/dev/null
}

# _alloy_targets <port> <hosts...>
#
# An Alloy array of static targets, instance set to the bare host name so it
# matches what this box reports for itself.
_alloy_targets() {
  local port="$1" h out=""
  shift
  for h in "$@"; do
    out+="${out:+, }{\"__address__\" = \"${h}:${port}\", \"instance\" = \"${h}\"}"
  done
  printf '[%s]' "$out"
}

# _alloy_config
#
# No secrets: credentials are read from the environment at run time. Regexes
# use [.] rather than \. so neither bash nor Alloy's string escapes get in the
# way; Alloy anchors every relabel regex on both ends.
_alloy_config() {
  local units u
  for u in $ALLOY_UNITS; do units+="${units:+|}${u}"; done
  cat <<EOF
// Managed by dev-environment/provision/lib/alloy.sh — do not edit by hand.
// Credentials come from ${ALLOY_DEFAULTS}, the EnvironmentFile of alloy.service.
// See docs/lab-metrics.md.

// ---- This box -----------------------------------------------------------

prometheus.exporter.unix "self" {
  enable_collectors = ["systemd"]

  systemd {
    unit_include = "(${units})[.]service"
  }
  netclass {
    ignored_devices = "^(veth.*|br-.*|docker0|lo)\$"
  }
  netdev {
    device_exclude = "^(veth.*|br-.*|docker0|lo)\$"
  }
}

// Same job and instance labels as the lab targets, so one dashboard and one
// absent() alert cover every host.
discovery.relabel "self" {
  targets = prometheus.exporter.unix.self.targets

  rule {
    target_label = "job"
    replacement  = "node"
  }
  rule {
    target_label = "instance"
    replacement  = "$(hostname -s)"
  }
}

prometheus.scrape "self" {
  targets         = discovery.relabel.self.output
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.keep.receiver]
}

// LiteLLM: token and request counters per client key (api_key_alias) and
// model, for the Local model usage dashboard. lib/litellm.sh limits what it
// exports; the keep-list below limits what leaves.
prometheus.scrape "litellm" {
  targets         = [{"__address__" = "${ALLOY_LITELLM_ADDR}", "instance" = "$(hostname -s)"}]
  job_name        = "litellm"
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.keep.receiver]
}

// Content curator: job runs, last success, items, picks and publishing. Its
// own `job` label (which curator job) arrives as `exported_job`.
prometheus.scrape "content_curator" {
  targets         = [{"__address__" = "${ALLOY_CURATOR_ADDR}", "instance" = "$(hostname -s)"}]
  job_name        = "content-curator"
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.keep.receiver]
}

// ---- Lab targets, over the tailnet ---------------------------------------

// node_exporter from the Ansible role node_metrics. Includes the model
// engines' counters (llamacpp:*, gufo_*) through its textfile collector.
prometheus.scrape "lab_nodes" {
  targets         = $(_alloy_targets 9100 $ALLOY_NODE_TARGETS)
  job_name        = "node"
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.keep.receiver]
}

// llama-swap's own /metrics: memory and swap as it sees them. Per-core CPU
// is dropped by the keep-list; node_exporter has it.
prometheus.scrape "llama_swap" {
  targets         = $(_alloy_targets 8080 $ALLOY_LLAMA_SWAP_TARGETS)
  job_name        = "llama-swap"
  scrape_interval = "60s"
  forward_to      = [prometheus.relabel.keep.receiver]
}

// ---- Keep-list ---------------------------------------------------------------

// Nothing reaches Grafana Cloud unless it is named here. Add a metric when a
// panel needs it, and check active series under Usage afterwards (10k free).
prometheus.relabel "keep" {
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]

  rule {
    source_labels = ["__name__"]
    action        = "keep"
    regex         = "up|scrape_duration_seconds|scrape_samples_scraped|node_(boot_time_seconds|time_seconds|uname_info|os_info|load1|load5|load15|cpu_seconds_total|pressure_.*|memory_(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|SwapTotal|SwapFree|Dirty|Writeback)_bytes|filesystem_(size|avail|free)_bytes|filesystem_readonly|disk_(read|written)_bytes_total|disk_io_time_seconds_total|disk_(reads|writes)_completed_total|network_(receive|transmit)_(bytes|errs|drop)_total|network_up|network_carrier|network_speed_bytes|hwmon_temp_celsius|hwmon_power_average_watt|hwmon_chip_names|hwmon_sensor_label|drm_.*|systemd_unit_state|textfile_scrape_error)|llama_swap_reachable|llama_engine_up|llamacpp:.*|gufo_.*|llamaswap_(memory|swap)_.*|llamaswap_load_average|litellm_(input|output|input_cached)_tokens_metric_total|litellm_proxy_(total|failed)_requests_metric_total|litellm_(request_total_latency|llm_api_time_to_first_token)_metric_(bucket|sum|count)|curator_.*"
  }

  // Container plumbing interfaces on any host.
  rule {
    source_labels = ["device"]
    action        = "drop"
    regex         = "veth.*|br-.*|docker0|podman.*|cni.*|lo"
  }

  // Filesystems that are not disks.
  rule {
    source_labels = ["fstype"]
    action        = "drop"
    regex         = "tmpfs|overlay|squashfs|efivarfs|nsfs|fuse[.].*"
  }

  // systemd_unit_state exports five states per unit; activating and
  // deactivating are transient and only double the series.
  rule {
    source_labels = ["__name__", "state"]
    action        = "drop"
    regex         = "node_systemd_unit_state;(activating|deactivating)"
  }
}

// ---- Grafana Cloud -------------------------------------------------------------

prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = sys.env("GCLOUD_PROM_URL")

    basic_auth {
      username = sys.env("GCLOUD_PROM_USER")
      password = sys.env("GCLOUD_RW_TOKEN")
    }
  }
}
EOF
}

_alloy_wait_ready() {
  local _
  for _ in $(seq 1 30); do
    if curl -fsS -m 3 "http://${ALLOY_LISTEN}/-/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
