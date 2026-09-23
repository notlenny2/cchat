cd /tmp/cchat-demo && rm -rf data && CMESSAGE_DATA_DIR=/tmp/cchat-demo/data DEMO_MODE=$1 ./cchat-demo > run.log 2>&1 & PID=$!
for i in $(seq 1 ${2:-60}); do kill -0 $PID 2>/dev/null || break; sleep 1; done; kill $PID 2>/dev/null
grep -vE "^\s*$" /tmp/cchat-demo/run.log | grep -E "saved|failed|recorded|rror|no window" | head -20
