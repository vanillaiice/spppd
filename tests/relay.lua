-- The relay the online tests use, from SPPPD_RELAY. They make rooms and races, so a
-- relay on this machine or the LAN only: on the official server they'd fill its
-- analytics and the dashboard's activity. `make check-relay` checks that one.
local relay = {}

local function isLocal(host)
  if host == "localhost" then return true end
  local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
  a, b = tonumber(a), tonumber(b)
  if not a then return false end
  return a == 127 or a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
end

-- host, port, or nil and why not.
function relay.address()
  local given = os.getenv("SPPPD_RELAY")
  if not given then return nil, "set SPPPD_RELAY=host:port to run against a local relay" end
  local host, port = given:match("^(.+):(%d+)$")
  if not host then return nil, "SPPPD_RELAY should be host:port" end
  if not isLocal(host) then
    return nil, given .. " isn't a local relay; the tests would show in its stats. Use make check-relay"
  end
  return host, tonumber(port)
end

return relay
