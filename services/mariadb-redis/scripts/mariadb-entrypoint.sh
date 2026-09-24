#!/bin/sh
set -eu

# OpenShip MariaDB Dynamic Entrypoint
# Detects memory and CPU limits (cgroups v1/v2, host, or ENV) and tunes InnoDB parameters.

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

# Buffer Pool calculation (default 40% of RAM, minimum 128M)
CALC_BP=$(( TOTAL_RAM * 40 / 100 ))
if [ "$CALC_BP" -lt 128 ]; then
  CALC_BP=128
fi

if [ -n "${MARIADB_BUFFER_POOL_SIZE:-}" ]; then
  BP_SIZE="$MARIADB_BUFFER_POOL_SIZE"
else
  BP_SIZE="${CALC_BP}M"
fi

# Buffer Pool Instances calculation
# If CALC_BP >= 1024MB and CORES > 1 -> set to CORES (max 8), else 1
if [ -n "${MARIADB_BUFFER_POOL_INSTANCES:-}" ]; then
  BP_INSTANCES="$MARIADB_BUFFER_POOL_INSTANCES"
elif [ "$CALC_BP" -ge 1024 ] && [ "$CORES" -gt 1 ]; then
  BP_INSTANCES="$CORES"
  if [ "$BP_INSTANCES" -gt 8 ]; then
    BP_INSTANCES=8
  fi
else
  BP_INSTANCES=1
fi

# Connections calculation: 30 + (TOTAL_RAM / 50), bounded between 50 and 250
if [ -n "${MARIADB_MAX_CONNECTIONS:-}" ]; then
  MAX_CONN="$MARIADB_MAX_CONNECTIONS"
else
  CALC_CONN=$(( 30 + (TOTAL_RAM / 50) ))
  if [ "$CALC_CONN" -lt 50 ]; then
    CALC_CONN=50
  fi
  if [ "$CALC_CONN" -gt 250 ]; then
    CALC_CONN=250
  fi
  MAX_CONN="$CALC_CONN"
fi

echo "[openship-mariadb] Server RAM: ${TOTAL_RAM}MB, Cores: $CORES | Buffer Pool: $BP_SIZE (Instances: $BP_INSTANCES) | Max Connections: $MAX_CONN"

exec docker-entrypoint.sh mariadbd \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci \
  --innodb-buffer-pool-size="$BP_SIZE" \
  --innodb-buffer-pool-instances="$BP_INSTANCES" \
  --max-connections="$MAX_CONN" \
  "$@"
