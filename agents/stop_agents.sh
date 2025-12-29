#!/usr/bin/env bash
# Stop agent servers
echo "Stopping agent servers..."

if [[ -f .planner_pid ]]; then
    kill $(cat .planner_pid) 2>/dev/null && echo "Stopped planner"
    rm .planner_pid
fi

if [[ -f .executor_pid ]]; then
    kill $(cat .executor_pid) 2>/dev/null && echo "Stopped executor"
    rm .executor_pid
fi

echo "✅ Agents stopped"
