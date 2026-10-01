# cChat relay

Lets the phone reach its computer from anywhere, without a VPN and without opening ports on the computer.
A Cloudflare Worker with one Durable Object per mailbox.

- The computer keeps a WebSocket open to `/v1/m/<mailbox>/mac` (Bearer token).
- The phone POSTs to `/v1/m/<mailbox>/rpc?t=<seconds>`; the relay hands the body to the computer and returns its answer.
- Mailbox and token are HMAC-SHA256 of the pairing key (labels `cchat relay mailbox v1` / `cchat relay mac v1`),
  base64url. The relay stores only a hash of the token (first computer to connect claims the mailbox).
- Bodies are sealed with the pairing key (ChaCha20-Poly1305) before they get here; the relay can't read or forge them,
  and the computer refuses stale or replayed ones.
- Limits: 25 MB requests, 512 KB socket chunks, 64 requests in flight, a token bucket per mailbox.

    npm install
    npm run dev       # local, port 8787
    npm test          # against the local one
    npx wrangler login && npm run deploy
