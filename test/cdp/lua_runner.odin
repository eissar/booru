package cdp_test

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"
import lua "vendor:lua/5.4"

Host :: struct {
	arena: vmem.Arena,
	alloc: mem.Allocator,
}

push_json :: proc(L: ^lua.State, v: json.Value) {
	switch val in v {
	case json.Null:
		lua.pushnil(L)
	case json.Boolean:
		lua.pushboolean(L, b32(val))
	case json.Integer:
		lua.pushinteger(L, lua.Integer(val))
	case json.Float:
		lua.pushnumber(L, lua.Number(val))
	case json.String:
		lua.pushlstring(L, cstring(raw_data(val)), len(val))
	case json.Array:
		lua.createtable(L, c.int(len(val)), 0)
		for elem, i in val {
			push_json(L, elem)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.createtable(L, 0, c.int(len(val)))
		for k, elem in val {
			lua.pushlstring(L, cstring(raw_data(k)), len(k))
			push_json(L, elem)
			lua.settable(L, -3)
		}
	}
}

lua_str :: proc(L: ^lua.State, idx: c.int) -> string {
	return string(lua.L_checkstring(L, idx))
}

get_host :: proc(L: ^lua.State) -> ^Host {
	lua.getfield(L, lua.REGISTRYINDEX, "cdp.Host")
	h := cast(^Host)lua.touserdata(L, -1)
	lua.pop(L, 1)
	return h
}

l_server_start :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	h := get_host(L)
	lua.L_checktype(L, 1, c.int(lua.TTABLE))
	routes := make([dynamic]Route, h.alloc)

	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		lua.L_checktype(L, -1, c.int(lua.TTABLE))
		path := strings.clone(lua_str(L, -2), h.alloc)

		lua.getfield(L, -1, "content_type")
		ct := strings.clone(lua_str(L, -1), h.alloc)
		lua.pop(L, 1)

		lua.getfield(L, -1, "body")
		body := strings.clone(lua_str(L, -1), h.alloc)
		lua.pop(L, 1)

		lua.getfield(L, -1, "prefix")
		prefix := bool(lua.toboolean(L, -1))
		lua.pop(L, 1)

		append(&routes, Route{path = path, content_type = ct, body = body, prefix = prefix})
		lua.pop(L, 1)
	}

	s, ok := start_server(routes[:], h.alloc)
	if !ok {
		lua.pushstring(L, "failed to start HTTP fixture server")
		lua.error(L)
	}
	ud := cast(^^Server)lua.newuserdata(L, size_of(^Server))
	ud^ = s
	lua.L_getmetatable(L, "cdp.Server")
	lua.setmetatable(L, -2)
	return 1
}

l_server_url :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := (cast(^^Server)lua.L_checkudata(L, 1, "cdp.Server"))^
	u := fmt.tprintf("http://127.0.0.1:%d", s.port)
	lua.pushlstring(L, cstring(raw_data(u)), len(u))
	return 1
}

l_server_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sp := cast(^^Server)lua.L_checkudata(L, 1, "cdp.Server")
	if sp^ != nil {
		stop_server(sp^)
		sp^ = nil
	}
	return 0
}

l_browser_open :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	h := get_host(L)
	base_url := lua_str(L, 1)
	b, err := browser_open(base_url, h.alloc)
	if len(err) > 0 {
		lua.pushlstring(L, cstring(raw_data(err)), len(err))
		lua.error(L)
	}
	ud := cast(^^Browser)lua.newuserdata(L, size_of(^Browser))
	ud^ = b
	lua.L_getmetatable(L, "cdp.Browser")
	lua.setmetatable(L, -2)
	return 1
}

l_browser_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	bp := cast(^^Browser)lua.L_checkudata(L, 1, "cdp.Browser")
	if bp^ != nil {
		browser_close(bp^)
		bp^ = nil
	}
	return 0
}

l_browser_navigate :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	b := (cast(^^Browser)lua.L_checkudata(L, 1, "cdp.Browser"))^
	url := fmt.tprintf("%s%s", b.base_url, lua_str(L, 2))
	url_bytes, _ := json.marshal(url, {}, context.temp_allocator)
	b.load_fired = false
	_, err := cdp_call(
		b,
		"Page.navigate",
		strings.concatenate({`{"url":`, string(url_bytes), `}`}, context.temp_allocator),
	)
	if len(err) > 0 {
		lua.pushlstring(L, cstring(raw_data(err)), len(err))
		lua.error(L)
	}
	if !b.load_fired && !cdp_wait_event(b, "Page.loadEventFired") {
		lua.pushstring(L, "CDP recv failed waiting for Page.loadEventFired")
		lua.error(L)
	}
	return 0
}

l_browser_eval :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	b := (cast(^^Browser)lua.L_checkudata(L, 1, "cdp.Browser"))^
	val, err := cdp_eval(b, lua_str(L, 2))
	if len(err) > 0 {
		lua.pushlstring(L, cstring(raw_data(err)), len(err))
		lua.error(L)
	}
	push_json(L, val)
	return 1
}

register_cdp :: proc(L: ^lua.State, h: ^Host) {
	lua.pushlightuserdata(L, h)
	lua.setfield(L, lua.REGISTRYINDEX, "cdp.Host")

	server_funcs := []lua.L_Reg {
		{name = "url", func = l_server_url},
		{name = "close", func = l_server_close},
		{name = "__gc", func = l_server_close},
		{},
	}
	lua.L_newmetatable(L, "cdp.Server")
	lua.pushvalue(L, -1)
	lua.setfield(L, -2, "__index")
	lua.L_setfuncs(L, raw_data(server_funcs), 0)
	lua.pop(L, 1)

	browser_funcs := []lua.L_Reg {
		{name = "navigate", func = l_browser_navigate},
		{name = "eval", func = l_browser_eval},
		{name = "close", func = l_browser_close},
		{name = "__gc", func = l_browser_close},
		{},
	}
	lua.L_newmetatable(L, "cdp.Browser")
	lua.pushvalue(L, -1)
	lua.setfield(L, -2, "__index")
	lua.L_setfuncs(L, raw_data(browser_funcs), 0)
	lua.pop(L, 1)

	mod_funcs := []lua.L_Reg {
		{name = "server", func = l_server_start},
		{name = "open", func = l_browser_open},
		{},
	}
	lua.L_newlib(L, mod_funcs)
	lua.setglobal(L, "cdp")
}

LUA_PRELUDE :: `
local suites, cur = {}, nil
function describe(name, fn)
  cur = { name = name, before = nil, after = nil, tests = {} }
  suites[#suites + 1] = cur
  fn()
  cur = nil
end
function before_all(fn) cur.before = fn end
function after_all(fn)  cur.after = fn end
function it(name, fn)   cur.tests[#cur.tests + 1] = { name = name, fn = fn } end

function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function assert_match(pat, actual, msg)
  if type(actual) ~= "string" or not string.match(actual, pat) then
    error((msg or "assert_match") .. ": " .. tostring(actual) .. " did not match " .. pat, 2)
  end
end

local raw_open = cdp.open
function cdp.open(base_url)
  local b = raw_open(base_url)
  local mt = getmetatable(b)
  if not mt.sleep then
    function mt:sleep(ms)
      return self:eval(string.format("new Promise(r => setTimeout(r, %d))", ms))
    end
    function mt:wait_for(expr, ms)
      return self:eval(string.format([[new Promise((resolve, reject) => {
        const deadline = Date.now() + %d;
        const tick = () => {
          try { const v = (%s); if (v) return resolve(v); } catch (e) { return reject(e); }
          if (Date.now() >= deadline) return reject(new Error("wait_for timed out"));
          requestAnimationFrame(tick);
        };
        tick();
      })]], ms or 5000, expr))
    end
    function mt:wait_for_selector(sel, ms)
      return self:eval(string.format([[new Promise((resolve, reject) => {
        const sel = %q;
        if (document.querySelector(sel)) return resolve(true);
        let timer;
        const obs = new MutationObserver(() => {
          if (document.querySelector(sel)) { clearTimeout(timer); obs.disconnect(); resolve(true); }
        });
        timer = setTimeout(() => { obs.disconnect(); reject(new Error("wait_for_selector timed out: " + sel)); }, %d);
        obs.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      })]], sel, ms or 5000))
    end
  end
  return b
end

function run_specs()
  for _, s in ipairs(suites) do
    if s.before then s.before() end
    local ok, err = pcall(function()
      for _, t in ipairs(s.tests) do
        t.fn()
        print("PASS: " .. s.name .. " :: " .. t.name)
      end
    end)
    if s.after then pcall(s.after) end
    if not ok then error(err, 0) end
  end
end
`

run_lua_spec :: proc(t: ^testing.T, path: string) {
	h: Host
	if err := vmem.arena_init_growing(&h.arena); err != nil {
		testing.fail_now(t, "failed to init arena")
	}
	defer vmem.arena_destroy(&h.arena)
	h.alloc = vmem.arena_allocator(&h.arena)

	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)
	register_cdp(L, &h)

	if lua.L_dostring(L, LUA_PRELUDE) != c.int(lua.OK) {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if lua.L_dofile(L, cpath) != c.int(lua.OK) {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
	if lua.L_dostring(L, "run_specs()") != c.int(lua.OK) {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
}

@(test)
test_gallery_strip :: proc(t: ^testing.T) {
	run_lua_spec(t, "test/cdp/gallery_strip.lua")
}

@(test)
test_gallery_virtual :: proc(t: ^testing.T) {
	run_lua_spec(t, "test/cdp/gallery_virtual.lua")
}

@(test)
test_benchmark_counters :: proc(t: ^testing.T) {
	run_lua_spec(t, "test/cdp/benchmark_counters.lua")
}
