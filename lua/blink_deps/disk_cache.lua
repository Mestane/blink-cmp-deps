local M = {}

M.SCHEMA_VERSION = 1
M.DEFAULT_TTL = 24 * 60 * 60

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function enabled(opts)
	return not opts or opts.enabled ~= false
end

local function ttl(opts)
	if opts and tonumber(opts.ttl) then
		return tonumber(opts.ttl)
	end

	return M.DEFAULT_TTL
end

local function root_dir(opts)
	if opts and type(opts.dir) == "string" and opts.dir ~= "" then
		return opts.dir
	end

	return vim.fn.stdpath("cache") .. "/blink-cmp-deps"
end

local function cache_path(opts, namespace, key)
	return table.concat({
		root_dir(opts),
		namespace,
		key .. ".json",
	}, "/")
end

--------------------------------------------------------------------------------
-- FILE HELPERS
--------------------------------------------------------------------------------

local function remove_file(path)
	pcall(vim.uv.fs_unlink, path)
end

local function decode_file(path)
	local ok, lines = pcall(vim.fn.readfile, path)

	if not ok or type(lines) ~= "table" then
		return nil
	end

	local text = table.concat(lines, "\n")

	if text == "" then
		return nil
	end

	local decoded_ok, decoded = pcall(vim.json.decode, text)

	if not decoded_ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

--------------------------------------------------------------------------------
-- READ
--------------------------------------------------------------------------------

function M.get(opts, namespace, key)
	if not enabled(opts) then
		return nil, "disabled"
	end

	local path = cache_path(opts, namespace, key)

	if vim.fn.filereadable(path) ~= 1 then
		return nil, "miss"
	end

	local entry = decode_file(path)

	if not entry
		or entry.schema ~= M.SCHEMA_VERSION
		or type(entry.created_at) ~= "number"
		or type(entry.data) ~= "table"
	then
		remove_file(path)
		return nil, "invalid"
	end

	local max_age = ttl(opts)

	if max_age > 0 and os.time() - entry.created_at >= max_age then
		remove_file(path)
		return nil, "stale"
	end

	return entry.data, "hit"
end

--------------------------------------------------------------------------------
-- WRITE
--------------------------------------------------------------------------------

function M.set(opts, namespace, key, data)
	if not enabled(opts) then
		return false, "disabled"
	end

	if type(data) ~= "table" then
		return false, "invalid data"
	end

	local dir = root_dir(opts) .. "/" .. namespace
	local path = cache_path(opts, namespace, key)

    local mkdir_ok = pcall(vim.fn.mkdir, dir, "p")

    if not mkdir_ok or vim.fn.isdirectory(dir) ~= 1 then
    	return false, "mkdir failed"
    end

	local entry = {
		schema = M.SCHEMA_VERSION,
		created_at = os.time(),
		data = data,
	}

	local encode_ok, encoded = pcall(vim.json.encode, entry)

	if not encode_ok then
		return false, "encode failed"
	end

	local tmp = table.concat({
		path,
		".tmp.",
		tostring(vim.uv.os_getpid()),
		".",
		tostring(vim.uv.hrtime()),
	})

    local write_ok, write_result = pcall(vim.fn.writefile, { encoded }, tmp)

    if not write_ok or write_result ~= 0 then
    	remove_file(tmp)
    	return false, "write failed"
    end

	local rename_ok, rename_err = vim.uv.fs_rename(tmp, path)

	if not rename_ok then
		-- Some platforms do not replace an existing destination on rename.
		remove_file(path)

		rename_ok, rename_err = vim.uv.fs_rename(tmp, path)
	end

	if not rename_ok then
		remove_file(tmp)
		return false, tostring(rename_err or "rename failed")
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function M.debug_path(opts, namespace, key)
	return cache_path(opts, namespace, key)
end

return M
