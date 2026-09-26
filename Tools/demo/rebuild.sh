set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p /tmp/cchat-demo/src /tmp/cchat-demo/bin && cd /tmp/cchat-demo/src
for f in "$REPO"/cMessage/Sources/*.swift "$REPO"/Shared/*.swift; do cp "$f" .; done
python3 - <<'PY'
p='ClaudeRunner.swift'; s=open(p).read()
s=s.replace('return ["\\(home)/.local/bin/claude"','return ["/tmp/cchat-demo/bin/claude", "\\(home)/.local/bin/claude"'); open(p,'w').write(s)
p='UsageWatch.swift'; s=open(p).read()
s=s.replace('static func codex() -> PlanUsage? {','static func codex() -> PlanUsage? {\n        if true { return PlanUsage(session: UsageWindow(used: 0.12, resetsAt: Date().addingTimeInterval(9000)), week: UsageWindow(used: 0.41, resetsAt: Date().addingTimeInterval(300000)), asOf: Date()) }',1); open(p,'w').write(s)
p='App.swift'; s=open(p).read()
s=s.replace('@main\n','')
s=s.replace('@StateObject private var store = Store()','init() { Demo.prepare() }\n    @StateObject private var store = Store()',1)
s=s.replace('DispatchQueue.main.async { WindowRescue.run(atLaunch: true) }','DispatchQueue.main.async { WindowRescue.run(atLaunch: true) }\n                    Demo.start(store)',1)
open(p,'w').write(s)
PY
P=${P:-/tmp/dd-personal/Build/Products/Release}
swiftc -swift-version 5 -O -parse-as-library -I $P $P/SwiftTerm.o *.swift -o ../cchat-demo 2>&1 | grep -E "error:" || true
