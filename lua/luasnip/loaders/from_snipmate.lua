local ls = require("luasnip")
local cache = require("luasnip.loaders._caches").snipmate
local util = require("luasnip.util.util")
local loader_util = require("luasnip.loaders.util")
local Path = require("luasnip.util.path")
local session = require("luasnip.session")

local function parse_snipmate(buffer, filename)
	local snippets = {}
	local extends = {}

	---@type string[]
	local lines = loader_util.split_lines(buffer)
	local i = 1

	local function _parse()
		local line = lines[i]
		local prefix, description = line:match([[^snippet%s+(%S+)%s*(.*)]])
		local body = {}

		i = i + 1
		---@type number
		local indent

		while i <= #lines do
			line = lines[i]
			if line:find("^%s+") then
				if not indent then
					indent = #line:match("^%s+")
				end
				line = line:sub(indent + 1)
				line = line:gsub("${VISUAL}", "${TM_SELECTED_TEXT}")
			elseif line ~= "" then
				break
			end
			table.insert(body, line)
			i = i + 1
		end

		body = table.concat(body, "\n")
		local snippet = ls.parser.parse_snippet({
			trig = prefix,
			dscr = description,
			wordTrig = true,
		}, body)
		table.insert(snippets, snippet)
	end

	while i <= #lines do
		local line = lines[i]
		if vim.startswith(line, "snippet") then
			_parse()
		elseif vim.startswith(line, "extends") then
			extends = vim.split(vim.trim(line:sub(8)), "[,%s]+")
			i = i + 1
		elseif vim.startswith(line, "#") or line:find("^%s*$") then
			-- comment and blank line
			i = i + 1
		else
			error(("invalid line in %s: %s"):format(filename, i))
		end
	end

	return snippets, extends
end

local function load_snippet_file(path)
	if not Path.exists(path) then
		return
	end

	local snippet, extends

	if cache.path_snippets[path] then
		snippet = cache.path_snippets[path].snippet
		extends = cache.path_snippets[path].extends
	else
		local buffer = Path.read_file(path)
		snippet, extends = parse_snipmate(buffer)
		cache.path_snippets[path] = { snippet = snippet, extends = extends }
	end

	return snippet, extends
end

local function _append(tbl, name, elem)
	if tbl[name] == nil then
		tbl[name] = {}
	end
	table.insert(tbl[name], elem)
end

---Get paths of .snippets files
---@param roots string[] @snippet directory paths
---@return table @keys are file types, values are paths
local function get_ft_paths(roots)
	local ft_path = {}
	for _, root in ipairs(roots) do
		local files, dirs = Path.scandir(root)
		for _, file in ipairs(files) do
			local ft, ext = Path.basename(file, true)
			if ext == "snippets" then
				_append(ft_path, ft, Path.join(root, file))
			end
		end
		for _, dir in ipairs(dirs) do
			local ft = dir
			files, _ = Path.scandir(Path.join(root, dir))
			for _, file in ipairs(files) do
				if vim.endswith(file, ".snippets") then
					_append(ft_path, ft, Path.join(root, dir, file))
				end
			end
		end
	end
	return ft_path
end

local function filter(exclude, include)
	exclude = loader_util.filetypelist_to_set(exclude)
	include = loader_util.filetypelist_to_set(include)

	return function(lang)
		if exclude and exclude[lang] then
			return false
		end
		if include == nil or include[lang] then
			return true
		end
	end
end

local M = {}

local function normarize_paths(paths)
	if not paths then
		paths = vim.api.nvim_get_runtime_file("snippets", true)
	elseif type(paths) == "string" then
		paths = vim.split(paths, ",")
	end

	paths = vim.tbl_map(Path.expand, paths)
	paths = util.deduplicate(paths)

	cache.ft_paths = get_ft_paths(paths)
end

function M._load(ft)
	local snippets = {}
	for _, path in ipairs(cache.ft_paths[ft]) do
		local snippet, extends = load_snippet_file(path)
		vim.list_extend(snippets, snippet)
		for _, extend in ipairs(extends) do
			vim.list_extend(snippets, M._load(extend))
		end
	end
	return snippets
end

function M.load(opts)
	opts = opts or {}

	if not opts.is_lazy then
		normarize_paths(opts.paths)
	end

	local ft_filter = filter(opts.exclude, opts.include)

	for ft, _ in pairs(cache.ft_paths) do
		if ft_filter(ft) then
			local snippets = M._load(ft)
			local lang_snips = ls.snippets[ft] or {}
			ls.snippets[ft] = vim.list_extend(lang_snips, snippets)
			session.latest_load_ft = ft
			vim.cmd("do User LuasnipSnippetsAdded")
		end
	end
end

function M._lazyload()
	local fts = util.get_snippet_filetypes()
	for _, ft in ipairs(fts) do
		if not cache.lazy_loaded_ft[ft] then
			cache.lazy_loaded_ft[ft] = true
			M.load({ include = { ft }, is_lazy = true })
		end
	end
end

function M.lazy_load(opts)
	opts = opts or {}

	normarize_paths(opts.paths)

	vim.cmd([[
    augroup _luasnip_snipmate_lazy_load
        au!
        au BufWinEnter,FileType * lua require("luasnip.loaders.from_snipmate")._lazyload()
        au User LuasnipCleanup lua require("luasnip.loaders._caches").snipmate:clean()
    augroup END
    ]])
end

return M
