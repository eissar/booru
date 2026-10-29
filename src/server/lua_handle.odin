package server

import "core:log"
import "core:os"
import "core:strings"

import lua "vendor:lua/5.4"

import "../http"

// Lua script reloaded on every request; a missing file disables the hook.
LUA_HANDLER_PATH :: "handlers.lua"

// lua_handle lets handlers.lua answer a request before the built-in routes.
// The script defines a global `handle(req)`, where req = {method, path,
// query, body}, and returns nil to fall through, or `body[, status]` to
// respond with HTML. Script errors are logged and fall through.
lua_handle :: proc(res: ^http.Response, req: http.Req, body: []u8) -> bool {
	if !os.exists(LUA_HANDLER_PATH) {return false}

	// A fresh state per request keeps reloads trivial and avoids stale globals.
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	if lua.L_dofile(L, LUA_HANDLER_PATH) != 0 {
		log.errorf("lua: load %s: %s", LUA_HANDLER_PATH, lua.tostring(L, -1))
		return false
	}
	lua.getglobal(L, "handle")
	if !lua.isfunction(L, -1) {return false}

	lua.createtable(L, 0, 4)
	push_field(L, "method", req.header.method)
	push_field(L, "path", req.header.path)
	push_field(L, "query", req.header.query)
	push_field(L, "body", string(body))

	if lua.pcall(L, 1, 2, 0) != 0 {
		log.errorf("lua: handle %s: %s", req.header.path, lua.tostring(L, -1))
		return false
	}
	if lua.isnil(L, -2) {return false}

	status := http.STATUS.OK
	if lua.isinteger(L, -1) {status = http.STATUS(lua.tointeger(L, -1))}
	html := strings.clone(string(lua.tostring(L, -2)), req.alloc)
	http.res_html(html, res, status)
	return true
}

@(private = "file")
push_field :: proc(L: ^lua.State, key: cstring, value: string) {
	lua.pushlstring(L, cstring(raw_data(value)), uint(len(value)))
	lua.setfield(L, -2, key)
}
