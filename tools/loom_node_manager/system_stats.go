package main

import (
	"bufio"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type systemStats struct {
	CPUs        int
	CPUUsage    float64
	MemoryUsed  uint64
	MemoryTotal uint64
	DiskUsed    uint64
	DiskTotal   uint64
	LoadAverage string
}

func procCPU() (idle, total uint64, ok bool) {
	raw, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, false
	}
	line := strings.SplitN(string(raw), "\n", 2)[0]
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, false
	}
	values := make([]uint64, 0, len(fields)-1)
	for _, field := range fields[1:] {
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return 0, 0, false
		}
		values = append(values, value)
		total += value
	}
	idle = values[3]
	if len(values) > 4 {
		idle += values[4]
	}
	return idle, total, true
}

func readSystemStats() systemStats {
	stats := systemStats{CPUs: runtime.NumCPU()}
	idle1, total1, cpuOK := procCPU()
	if cpuOK {
		// A slightly wider sample window avoids pinning the gauge at 100% because
		// of a very short Docker/Go build spike. The dashboard refreshes this live.
		time.Sleep(350 * time.Millisecond)
		idle2, total2, ok := procCPU()
		if ok && total2 > total1 {
			used := (total2 - total1) - (idle2 - idle1)
			stats.CPUUsage = float64(used) * 100 / float64(total2-total1)
		}
	}
	if file, err := os.Open("/proc/meminfo"); err == nil {
		defer file.Close()
		values := map[string]uint64{}
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) < 2 {
				continue
			}
			value, err := strconv.ParseUint(fields[1], 10, 64)
			if err == nil {
				values[strings.TrimSuffix(fields[0], ":")] = value * 1024
			}
		}
		stats.MemoryTotal = values["MemTotal"]
		available := values["MemAvailable"]
		if stats.MemoryTotal >= available {
			stats.MemoryUsed = stats.MemoryTotal - available
		}
	}
	if raw, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(raw))
		if len(fields) >= 3 {
			stats.LoadAverage = strings.Join(fields[:3], " ")
		}
	}
	if output, err := commandOutput("df", "-Pk", "/"); err == nil {
		lines := strings.Split(strings.TrimSpace(output), "\n")
		if len(lines) >= 2 {
			fields := strings.Fields(lines[len(lines)-1])
			if len(fields) >= 5 {
				total, _ := strconv.ParseUint(fields[1], 10, 64)
				used, _ := strconv.ParseUint(fields[2], 10, 64)
				stats.DiskTotal = total * 1024
				stats.DiskUsed = used * 1024
			}
		}
	}
	return stats
}
