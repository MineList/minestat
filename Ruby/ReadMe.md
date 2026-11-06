MineStat
========

### About

MineStat is a Minecraft server status checker.

You can use these classes/modules in a monitoring script to poll multiple Minecraft servers, include similar functionality in a Discord bot, or to let
visitors see the status of your server from their browser. MineStat has been ported to multiple languages for use with ASP.NET, FastCGI, mod_perl,
mod_php, mod_python, Node.js, Rails, Tomcat, and more.

### Installation

To install the gem: `gem install minestat`

### Example

```ruby
require 'minestat'

ms = MineStat.new("frag.land")
puts "Minecraft server status of #{ms.address} on port #{ms.port}:"
if ms.online
  puts "Server is online running version #{ms.version} with #{ms.current_players} out of #{ms.max_players} players."
  puts "Game mode: #{ms.mode}" if ms.mode
  puts "Message of the day: #{ms.motd}"
  puts "Message of the day without formatting: #{ms.stripped_motd}"
  puts "Latency: #{ms.latency}ms"
  puts "Connected using protocol: #{ms.request_type}"
else
  puts "Server is offline!"
end
```

### Constructor Arguments

To simply connect to an address:
```ruby
ms = MineStat.new("frag.land")
```
Connect to an address on a certain TCP or UDP port:
```ruby
ms = MineStat.new("frag.land", 25565)
```
Same as above example and additionally includes a timeout in seconds:
```ruby
ms = MineStat.new("frag.land", 25565, 3)
```
Same as above example and additionally includes an explicit protocol to use:
```ruby
ms = MineStat.new("frag.land", 25565, 3, MineStat::Request::QUERY)
```
Connect to a Bedrock server and enable debug mode:
```ruby
ms = MineStat.new("minecraft.frag.land", 19132, 3, MineStat::Request::BEDROCK, true)
```
Attempt all SLP protocols, disable debug mode, and disable DNS SRV resolution:
```ruby
ms = MineStat.new("minecraft.frag.land", 25565, 3, MineStat::Request::SLP, false, false)
```
Connect the socket to a previously resolved literal IP while keeping the hostname in the protocol handshake:
```ruby
ms = MineStat.new("minecraft.frag.land", 25565,
  resolved_ip: "203.0.113.10", srv_enabled: false,
  request_type: MineStat::Request::JSON, timeout: 5)
```

`resolved_ip` must be an IPv4 or IPv6 literal. MineStat does not apply a public/private address policy; callers that accept untrusted destinations should validate the literal before passing it.

When `resolved_ip` is provided, MineStat skips its A-record lookup and connects TCP/UDP sockets to that IP. Set `srv_enabled: false` when the caller has already resolved the host and port to avoid all constructor DNS lookups. With SRV resolution enabled, MineStat still looks up the SRV hostname and port; the socket remains pinned to `resolved_ip`.

### Support
* Discord: https://discord.frag.land
* GitHub: https://github.com/FragLand/minestat

### Bedrock NetherNet status (Ruby 2.7+)

`Request::NETHERNET` explicitly selects a single `GET /v1/join` request, as defined
in Mojang's [NetherNet onboarding guide](https://mojang.github.io/bedrock-protocol-docs/guides/nether-net-onboarding-guide/#capability-check-and-server-info)
(reviewed 2026-11-06). It does not implement player authentication, SDP/WebRTC,
identity assertions, `cpk`, or any Warden API. A successful status response means
that the status endpoint is available; it does not verify that a player can join.
`BEDROCK` continues to use RakNet/UDP. The automatic protocol sequence does not
include NetherNet.

```ruby
# address is a bare hostname, not a URL; nil selects port 443 for HTTPS.
ms = MineStat.new("bedrock.example.com", nil,
  request_type: MineStat::Request::NETHERNET, timeout: 5)

# Connect only to the IP previously checked by the caller while preserving
# bedrock.example.com in HTTP Host, TLS SNI and certificate hostname checks.
ms = MineStat.new("bedrock.example.com", 443,
  request_type: MineStat::Request::NETHERNET,
  resolved_ip: "203.0.113.10", timeout: 5)

# Plaintext is explicit. With nil port, HTTP uses port 80.
ms = MineStat.new("bedrock.example.com", 8080,
  request_type: MineStat::Request::NETHERNET,
  nethernet_scheme: "http", timeout: 5)
```

`nethernet_scheme` accepts only `"https"` (default) or `"http"`; an explicit port
does not change the scheme. HTTPS uses system trust roots and verifies the
original hostname. There is no TLS-to-HTTP downgrade, retry, or redirect following.
Ruby 2.7+ is required only for NetherNet because it uses the public
`Net::HTTP#ipaddr=` connection-target API. Older runtimes raise `ArgumentError`
when NetherNet is selected; existing request types retain their runtime behavior.

NetherNet also requires **net-http 0.10.0 or later** for bounded HTTP header and
response-line parsing. Install it with `gem install net-http -v '>= 0.10.0'`, or
add `gem 'net-http', '>= 0.10.0'` to the application's Gemfile and update its lockfile.
The library checks the actually loaded version before any NetherNet DNS lookup
or connection, including when used directly from `lib/minestat.rb`. An older
loaded version raises `ArgumentError`; restart the process after updating it.
This is a NetherNet-only requirement, not a new runtime dependency for existing
RakNet/SLP users. The development dependency ensures the full test suite uses a
supported parser.

NetherNet always skips Minecraft Java SRV resolution (`srv_enabled` reports
`false`). With `resolved_ip`, it performs no DNS lookup, and the supplied literal
IPv4/IPv6 address is the only socket destination. Without it, the original host
is resolved once and that result is pinned for the request. Environment HTTP
proxies are disabled to preserve this guarantee. The caller remains responsible
for checking whether an address is permitted by its network policy. Pass IPv6
addresses without brackets; HTTP Host formatting adds them where needed.

#### Result fields

The official status schema lists the seven fields below without marking any as
optional. MineStat requires all seven; missing/null/wrongly typed values fail
validation. Numeric fields must be nonnegative whole numbers (JSON `2.0` is also
accepted). Additional fields are allowed and retained in `json_data`. Unknown
nonnegative `gameType` values are displayed as `"Unknown (N)"`.

| Response | MineStat result |
| --- | --- |
| `name` | `motd`; `stripped_motd` removes Minecraft formatting codes |
| `protocol` | `protocol` (integer Bedrock protocol version) |
| `version` | `version` (unmodified game version string) |
| `level` | `level` (new read-only world-name field) |
| `players` | `current_players` (integer) |
| `maxPlayers` | `max_players` (integer) |
| `gameType` | `mode`: 0 Survival, 1 Creative, 2 Adventure |

The full parsed object is available as `json_data`. The world name is kept
separate from `version` rather than reproducing the legacy RakNet display string.
`request_type` reports `"Bedrock NetherNet"`. `latency` is the total successful
status-query duration in milliseconds, including any DNS lookup, TCP/TLS setup,
body transfer and parsing; it is not game-transport ping latency.

#### Limits and failure results

`timeout` defaults to 5 seconds and must be finite and positive. It bounds the
whole lookup/request/parse operation, including DNS and a slowly streamed body,
and is also applied to connection, read and write operations. The JSON response
body is limited to 65,536 bytes, both with Content-Length and streamed/chunked
responses. Responses must be UTF-8 JSON with `Content-Type: application/json`
(parameters such as `charset=utf-8` are allowed). Compression is not requested;
encoded responses are rejected.
The HTTP parser separately bounds response headers and individual framing lines
(1 MiB in net-http 0.10.0), including status lines, chunk-size/extension lines and
trailer lines. Oversized framing is rejected as `Unknown`. The 64 KiB limit is
specifically the JSON body limit, not a total HTTP wire-size limit.

| Result | `connection_status` | `online` |
| --- | --- | --- |
| 2xx and valid complete metadata | `Success` | `true` |
| DNS/TCP/network or TLS certificate/handshake failure | `Fail` | `false` |
| Overall, connection, read or write timeout | `Timeout` | `false` |
| Non-2xx (including redirects), malformed HTTP/JSON/schema, empty/truncated/oversized or encoded body | `Unknown` | `false` |

Bad constructor arguments raise `ArgumentError` before network access.

### Ruby tests

Install Minitest 5 (`gem install minitest -v '~> 5.0'`) and net-http 0.10.0+
(`gem install net-http -v '>= 0.10.0'`), then run from the repository
root. Disabling automatic Minitest plugins keeps unrelated globally installed
plugins out of the test run:

```sh
MT_NO_PLUGINS=1 ruby -I Ruby/test -e 'Dir["Ruby/test/test_*.rb"].sort.each { |file| require_relative file }'
```

NetherNet tests use local IPv4/IPv6 HTTP and TLS listeners, an ephemeral test
certificate and an isolated trust store. They require loopback socket access,
but no external server or DNS access. On Ruby older than 2.7 these tests skip;
use Ruby 2.7+ to validate NetherNet as well as the existing connection tests.
