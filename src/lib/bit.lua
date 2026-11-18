-- LuaJIT's `bit` where there is one. The browser build runs plain Lua 5.1, which has
-- none, so this falls back to arithmetic. The fallback only holds for what the game
-- asks of it: whole numbers from 0 to 2^32 - 1, and shifts that stay in that range.
local ok, bit = pcall(require, "bit")
if ok and bit then return bit end
if bit32 then return bit32 end

local floor = math.floor

local function each(a, b, keep)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local ra, rb = a % 2, b % 2
    if keep(ra, rb) then r = r + p end
    a, b, p = (a - ra) / 2, (b - rb) / 2, p * 2
  end
  return r
end

return {
  band = function(a, b) return each(a, b, function(x, y) return x == 1 and y == 1 end) end,
  bor = function(a, b) return each(a, b, function(x, y) return x == 1 or y == 1 end) end,
  bxor = function(a, b) return each(a, b, function(x, y) return x ~= y end) end,
  lshift = function(a, n) return (a * 2 ^ n) % 2 ^ 32 end,
  rshift = function(a, n) return floor(a / 2 ^ n) end,
}
