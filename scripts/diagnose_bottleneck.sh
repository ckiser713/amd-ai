#!/usr/bin/env bash

echo "🔍 Diagnosing build bottlenecks..."
echo "CPU Threads: $(nproc)"
echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
echo "Memory Pressure: $(awk '/MemAvailable/ {print $2/1024/1024" GB free"}' /proc/meminfo)"

# Check what's limiting parallelism
echo -e "\nActive Build Processes:"
ps aux | grep -E "(make|ninja|cmake|gcc|g\+\+|clang)" | grep -v grep | head -20

echo -e "\nFile Descriptor Limits:"
ulimit -n

echo -e "\nI/O Wait (high = disk bottleneck):"
iostat -c | tail -2

echo -e "\nCPU Frequency:"
awk '/cpu MHz/ {sum+=$4; count++} END {print "Avg:", sum/count, "MHz"}' /proc/cpuinfo

# Check if memory is the bottleneck
echo -e "\nMemory Usage by Build:"
ps aux --sort=-%mem | head -5
