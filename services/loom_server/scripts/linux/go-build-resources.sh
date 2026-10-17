#!/bin/sh
# Bound source-build concurrency by CPU quota and available memory.
loom_go_effective_cpus() {
  loom_cpu=$1; loom_quota=${2:-max}; loom_period=${3:-100000}
  case "$loom_cpu" in ''|*[!0-9]*) loom_cpu=1 ;; esac
  [ "$loom_cpu" -gt 0 ] || loom_cpu=1
  case "$loom_quota:$loom_period" in *[!0-9:]*) ;; *)
    if [ "$loom_period" -gt 0 ] && [ "$loom_quota" -gt 0 ]; then
      loom_quota_cpu=$(( (loom_quota + loom_period - 1) / loom_period ))
      [ "$loom_quota_cpu" -ge "$loom_cpu" ] || loom_cpu=$loom_quota_cpu
    fi ;;
  esac
  printf '%s\n' "$loom_cpu"
}
loom_go_jobs_for() {
  loom_jobs=$1; loom_memory=$2
  case "$loom_memory" in ''|*[!0-9]*) loom_memory=1024 ;; esac
  loom_memory_jobs=$(( (loom_memory - 512) / 768 ))
  [ "$loom_memory_jobs" -gt 0 ] || loom_memory_jobs=1
  [ "$loom_jobs" -le "$loom_memory_jobs" ] || loom_jobs=$loom_memory_jobs
  [ "$loom_jobs" -le 8 ] || loom_jobs=8
  [ "$loom_jobs" -gt 0 ] || loom_jobs=1
  printf '%s\n' "$loom_jobs"
}
loom_go_build_resources() {
  loom_detected_cpu=$(nproc 2>/dev/null || printf 1)
  loom_quota=max; loom_period=100000
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r loom_quota loom_period < /sys/fs/cgroup/cpu.max || true
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    loom_quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    loom_period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  fi
  loom_cpu=$(loom_go_effective_cpus "$loom_detected_cpu" "$loom_quota" "$loom_period")
  loom_memory=$(awk '/MemAvailable:/ {print int($2 / 1024); found=1; exit} END {if (!found) print 1024}' /proc/meminfo)
  for loom_pair in '/sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current' '/sys/fs/cgroup/memory/memory.limit_in_bytes /sys/fs/cgroup/memory/memory.usage_in_bytes'; do
    set -- $loom_pair
    [ -r "$1" ] && [ -r "$2" ] || continue
    loom_limit=$(cat "$1"); loom_used=$(cat "$2")
    case "$loom_limit:$loom_used" in *[!0-9:]*) continue ;; esac
    loom_remaining=$(( (loom_limit - loom_used) / 1048576 ))
    [ "$loom_remaining" -gt 0 ] || loom_remaining=1
    [ "$loom_remaining" -ge "$loom_memory" ] || loom_memory=$loom_remaining
  done
  LOOM_GO_BUILD_JOBS=$(loom_go_jobs_for "$loom_cpu" "$loom_memory")
  GOMAXPROCS=$LOOM_GO_BUILD_JOBS
  export LOOM_GO_BUILD_JOBS GOMAXPROCS
  printf 'Build resources: %s CPU(s), %s MiB available; %s compiler worker(s)\n' "$loom_cpu" "$loom_memory" "$LOOM_GO_BUILD_JOBS"
}
