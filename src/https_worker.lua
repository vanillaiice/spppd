-- The thread src/net_http.lua starts: lua-https waits for the whole reply, so it
-- runs here, where waiting doesn't stop the game. Takes { id, url, agent } off
-- requests and puts { id, code, body } or { id, err } on replies.
require("love.thread")

local requests, replies = ...
local ok, https = pcall(require, "https")

while true do
  local job = requests:demand()
  if job == "stop" then break end
  if not ok then
    replies:push({ id = job.id, err = "no https" })
  else
    local fine, code, body = pcall(https.request, job.url, { headers = { ["User-Agent"] = job.agent } })
    if not fine then
      replies:push({ id = job.id, err = tostring(code) })
    elseif not code or code == 0 then
      replies:push({ id = job.id, err = tostring(body or "no reply") })
    else
      replies:push({ id = job.id, code = code, body = body or "" })
    end
  end
end
