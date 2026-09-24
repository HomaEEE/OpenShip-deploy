#!/bin/sh
set -eu

# OpenShip Redis Dynamic Entrypoint
# Detects memory and CPU limits (cgroups v1/v2, host, or ENV) and tunes maxmemory parameters.

detect_ram() {
  # 1. Manual override via SERVER_RAM_GB
  if [ -n "${SERVER_RAM_GB:-}" ]; then
    echo "$(( SERVER_RAM_GB * 1024 ))"
    return
  fi

  # 2. cgroups v2 memory limit
  if [ -r /sys/fs/cgroup/memory.max ]; then
    cg2_val=$(cat /sys/fs/cgroup/memory.max 2>/dev/null | tr -d '[:space:]')
    if [ -n "$cg2_val" ] && [ "$cg2_val" != "max" ]; then
      mem_mb=$(( cg2_val / 1048576 ))
      if [ "$mem_mb" -gt 0 ]; then
        echo "$mem_mb"
        return
      fi
    fi
  fi

  # 3. cgroups v1 memory limit
  if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    cg1_val=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null | tr -d '[:space:]')
    # 9223372036854771712 indicates unlimited in cgroups v1
    if [ -n "$cg1_val" ] && [ "$cg1_val" -lt 9223372036854771712 ] 2>/dev/null; then
      mem_mb=$(( cg1_val / 1048576 ))
      if [ "$mem_mb" -gt 0 ]; then
        echo "$mem_mb"
        return
      fi
    fi
  fi

  # 4. Host /proc/meminfo MemTotal
  if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$mem_kb" ]; then
      echo "$(( mem_kb / 1024 ))"
      return
    fi
  fi

  # 5. Default fallback
  echo "2048"
}

detect_cores() {
  if [ -n "${SERVER_CPU_CORES:-}" ]; then
    echo "$SERVER_CPU_CORES"
    return
  fi

  if command -v nproc >/dev/null 2>&1; then
    nproc
    return
  fi

  echo "1"
}

TOTAL_RAM="$(detect_ram)"
CORES="$(detect_cores)"

# Maxmemory calculation (default 15% of RAM, minimum 64MB)
if [ -n "${REDIS_MAXMEMORY:-}" ]; then
  MAX_MEM="$REDIS_MAXMEMORY"
else
  CALC_MEM=$(( TOTAL_RAM * 15 / 100 ))
  if [ "$CALC_MEM" -lt 64 ]; then
    CALC_MEM=64
  fi
  MAX_MEM="${CALC_MEM}mb"
fi

POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"

echo "[openship-redis] Server RAM: ${TOTAL_RAM}MB, Cores: $CORES | Maxmemory: $MAX_MEM | Policy: $POLICY"

EXTRA_ARGS=""
if [ -n "${REDIS_PASSWORD:-}" ]; then
  EXTRA_ARGS="--requirepass $REDIS_PASSWORD"
fi

exec redis-server --appendonly yes --maxmemory "$MAX_MEM" --maxmemory-policy "$POLICY" $EXTRA_ARGS "$@"
