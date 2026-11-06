-- Frame composition: scene, night lighting, glow and the final grade.
-- Only lamps, flames and sparks glow; daylight whites never bloom.
local post = {}

local BLUR = [[
  uniform vec2 dir;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv) * 0.2270270270;
    c += Texel(tex, uv + dir * 1.3846153846) * 0.3162162162;
    c += Texel(tex, uv - dir * 1.3846153846) * 0.3162162162;
    c += Texel(tex, uv + dir * 3.2307692308) * 0.0702702703;
    c += Texel(tex, uv - dir * 3.2307692308) * 0.0702702703;
    return c;
  }
]]

local COMPOSITE = [[
  uniform Image lightmap;
  uniform Image glow;
  uniform float useLight;
  uniform float glowAmount;
  uniform vec3 grade;
  uniform float saturation;
  uniform float vignette;
  uniform float punch;
  uniform float speedBlur;

  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec3 c = Texel(tex, uv).rgb;

    // Streak the sides of the frame only. The centre column holds your car
    // and the road ahead, and those must never be smeared.
    if (speedBlur > 0.0005) {
      vec2 toEdge = uv - vec2(0.5, 0.5);
      float mask = smoothstep(0.32, 0.5, abs(toEdge.x));
      // A per-pixel offset turns would-be ghost images into fine grain.
      float jitter = fract(sin(dot(sc, vec2(12.9898, 78.233))) * 43758.5453);
      for (int i = 0; i < 10; i++) {
        c += Texel(tex, uv - toEdge * speedBlur * mask * (float(i) + jitter) * 0.6).rgb;
      }
      c /= 11.0;
    }
    if (useLight > 0.5) {
      c *= Texel(lightmap, uv).rgb;
    }
    c += Texel(glow, uv).rgb * glowAmount;

    // Bright, saturated colour: nothing here should look filmed.
    c = c * grade;
    c = mix(vec3(dot(c, vec3(0.3, 0.59, 0.11))), c, saturation);

    vec2 p = uv - 0.5;
    float v = 1.0 - dot(p, p) * (vignette + punch);
    return vec4(c * clamp(v, 0.0, 1.0), 1.0);
  }
]]

local function createCanvases(w, h)
  post.w, post.h = w, h
  post.glowCleared = false
  post.scene = love.graphics.newCanvas(w, h)
  post.light = love.graphics.newCanvas(math.ceil(w / 2), math.ceil(h / 2))
  post.glow = love.graphics.newCanvas(math.ceil(w / 2), math.ceil(h / 2))
  post.blurA = love.graphics.newCanvas(math.ceil(w / 4), math.ceil(h / 4))
  post.blurB = love.graphics.newCanvas(math.ceil(w / 4), math.ceil(h / 4))
  post.light:setFilter("linear", "linear")
  post.glow:setFilter("linear", "linear")
  post.blurA:setFilter("linear", "linear")
  post.blurB:setFilter("linear", "linear")
end

function post.load()
  post.blur = love.graphics.newShader(BLUR)
  post.composite = love.graphics.newShader(COMPOSITE)
  post.quality = "high"
end

function post.begin(w, h)
  if post.w ~= w or post.h ~= h then createCanvases(w, h) end
  love.graphics.setCanvas(post.scene)
  love.graphics.clear(0, 0, 0, 1)
end

-- fn(scale): draw additive lights over `ambient` into the night lightmap.
function post.drawLights(ambient, fn)
  love.graphics.setCanvas(post.light)
  love.graphics.clear(ambient[1], ambient[2], ambient[3], 1)
  love.graphics.push()
  love.graphics.scale(0.5, 0.5)
  love.graphics.setBlendMode("add")
  fn()
  love.graphics.setBlendMode("alpha")
  love.graphics.pop()
end

function post.drawGlow(fn)
  if post.quality == "low" then
    if not post.glowCleared then
      love.graphics.setCanvas(post.blurA)
      love.graphics.clear(0, 0, 0, 1)
      post.glowCleared = true
    end
    return
  end
  post.glowCleared = false

  love.graphics.setCanvas(post.glow)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.push()
  love.graphics.scale(0.5, 0.5)
  love.graphics.setBlendMode("add")
  fn()
  love.graphics.setBlendMode("alpha")
  love.graphics.pop()

  local bw, bh = post.blurA:getDimensions()
  love.graphics.setCanvas(post.blurA)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(post.glow, 0, 0, 0, 0.5, 0.5)

  love.graphics.setShader(post.blur)
  for pass = 1, 2 do
    love.graphics.setCanvas(post.blurB)
    post.blur:send("dir", { pass / bw, 0 })
    love.graphics.draw(post.blurA)
    love.graphics.setCanvas(post.blurA)
    post.blur:send("dir", { 0, pass / bh })
    love.graphics.draw(post.blurB)
  end
  love.graphics.setShader()
end

function post.present(opts)
  love.graphics.setCanvas()
  love.graphics.origin()
  love.graphics.setColor(1, 1, 1, 1)
  local shader = post.composite
  love.graphics.setShader(shader)
  shader:send("useLight", opts.lights and 1 or 0)
  shader:send("lightmap", post.light)
  shader:send("glow", post.blurA)
  shader:send("glowAmount", opts.glow or 1)
  shader:send("grade", opts.grade or { 1, 1, 1 })
  shader:send("saturation", opts.saturation or 1)
  shader:send("vignette", opts.vignette or 0.45)
  shader:send("punch", opts.punch or 0)
  shader:send("speedBlur", opts.speedBlur or 0)
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.draw(post.scene, opts.x or 0, opts.y or 0)
  love.graphics.setBlendMode("alpha")
  love.graphics.setShader()
end

return post
