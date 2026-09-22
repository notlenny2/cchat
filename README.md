# cMessage

iMessage, but every contact is a [Claude Code](https://claude.com/claude-code) agent.

Each project folder is a contact. Under a project you can add sub-contacts with their own persona
and their own memory ("Website UX", "Acme Tools Director"). You text them like people. You only ever
see their plain-English replies, never code or tool output.

- **Memory per chat.** Each contact keeps its own Claude Code session in every chat it's in.
- **Group chats.** Drag one chat onto another to make a group. Every agent brings what it knew from its
  own chat. Text the group and a quick, cheap model picks the agent best suited to answer, or `@name`
  someone, or say "everyone".
- **Next-step suggestions.** Every reply comes with two or three tap-to-send ideas for what to say next.
- **Real app icons.** Contact photos are pulled from each project's own app icon.
- **Pin, rename, search** like Messages.
- **NodeTerm import.** Bring over the Claude chats open on a [NodeTerm](https://github.com/eneskirca/nodeterm)
  canvas, memory and all (it forks the session so the terminal's copy is untouched).

## iPhone and iPad
The Mac stays in charge and runs the agents; the iOS app is a remote screen for the same chats.
On the Mac choose **Connect iPhone or iPad**, scan the QR code with the app, done. Traffic stays on your
local network and every message is encrypted end to end with a key only your paired devices hold
(ChaCha20-Poly1305, with replay protection).

## Requirements
- macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- The `claude` CLI installed and signed in

## Build
```
xcodegen generate
# Mac
xcodebuild -project cMessage.xcodeproj -scheme cMessage -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/cMessage.app /Applications/
# iPhone / iPad: open cMessage.xcodeproj, pick the cMessageMobile scheme, set your team, run
```

## How it works
Each turn runs `claude -p --output-format json` in the contact's project folder, resuming that
contact's session for this chat. The message goes in on stdin. Agents run in `acceptEdits` mode by
default; a per-contact "Full access" switch allows everything (use with care).

Data lives in `~/Library/Application Support/cMessage/`, logs in `~/Library/Logs/cMessage/`.

## License
MIT
