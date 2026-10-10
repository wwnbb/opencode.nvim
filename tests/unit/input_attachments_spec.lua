local attachments = require("opencode.ui.input.attachments")

describe("pasted image path normalization", function()
	local directory, state, path
	before_each(function()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory, "p")
		path = directory .. "/image with spaces.PNG"
		local file = assert(io.open(path, "wb"))
		assert(file:write("image\0bytes")); assert(file:close())
		state = { visible = true, parts = {}, bufnr = vim.api.nvim_create_buf(false, true) }
	end)
	after_each(function()
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		vim.fn.delete(directory, "rf")
	end)

	local function normalize(lines, resize)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
		attachments.normalize_pasted_image_paths(state, resize)
		return vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	end

	it("allocates distinct file and image markers from retained marker numbers", function()
		state.parts = {
			{ type = "file", mime = "text/plain", _marker = "[File 2]" },
		}
		assert.equals("[File 3]", attachments.add_file_part(state, { mime = "text/plain", data = "YQ==" }, { insert = false }))
		table.insert(state.parts, { type = "file", mime = "image/png", source = { text = { value = "[Image 4]" } } })
		assert.equals("[Image 5]", attachments.add_file_part(state, { mime = "image/jpeg", data = "Yg==" }, { insert = false }))
	end)

	it("filters restored file markers from either source shape without a private UI marker", function()
		for _, source in ipairs({ { value = "[Image 2]" }, { text = { value = "[Image 2]" } } }) do
			local part = { type = "file", url = "data:image/png;base64,Yg==", source = source }
			state.parts = { part }
			assert.same({ part }, attachments.active_parts_for_text(state, "Keep [Image 2]"))
			assert.same({}, attachments.active_parts_for_text(state, "Image removed"))
			assert.is_nil(part._marker)
		end
	end)

	it("does not attach a shorter existing image named by a non-image suffix", function()
		local backup = assert(io.open(path .. ".bak", "wb"))
		assert(backup:write("backup")); assert(backup:close())
		local lines = {}
		for _, suffix in ipairs({ ".bak", "-old", "_backup", "2", "é", "/child" }) do
			lines[#lines + 1] = "Inspect " .. path .. suffix .. " please"
			lines[#lines + 1] = "'" .. path .. suffix .. "'"
		end
		assert.same(lines, normalize(lines))
		assert.same({}, state.parts)
	end)

	it("does not truncate encoded file URLs at an image extension", function()
		local uri = "file://" .. path:gsub(" ", "%%20")
		local lines = { uri .. ".bak", uri .. "%20backup", "Inspect " .. uri .. "-old please" }
		assert.same(lines, normalize(lines))
		assert.same({}, state.parts)
	end)

	it("keeps exact paths, quotes, escaped spaces and inline file URLs working", function()
		local uri = "file://" .. path:gsub(" ", "%%20")
		local escaped = path:gsub(" ", "\\ ")
		local resizes = 0
		assert.same({ "[Image 1]", "  [Image 2]  ", "Inspect '[Image 3]' please", "Inspect [Image 4] please", "Inspect [Image 5] please" },
			normalize({ path, "  '" .. path .. "'  ", "Inspect '" .. path .. "' please", "Inspect " .. escaped .. " please", "Inspect " .. uri .. " please" },
				function() resizes = resizes + 1 end))
		assert.equals(5, #state.parts)
		for _, part in ipairs(state.parts) do
			assert.equals(path, part.source.path)
			assert.equals("data:image/png;base64," .. vim.base64.encode("image\0bytes"), part.url)
		end
		attachments.normalize_pasted_image_paths(state, function() resizes = resizes + 1 end)
		assert.equals(5, #state.parts)
		assert.equals(1, resizes)
		assert.is_false(state.normalizing_paste)
	end)

	it("does not recover local paths by removing a remote URL scheme", function()
		local encoded = path:gsub(" ", "%%20")
		local remote = "file://" .. encoded:sub(2)
		local lines = { remote, "Inspect " .. remote .. " please", "https://" .. path:sub(2), "Inspect https://" .. path:sub(2) .. " please" }
		assert.same(lines, normalize(lines))
		assert.same({}, state.parts)
	end)

	it("recognizes inline local file URLs with a single slash", function()
		local uri = "file:" .. path:gsub(" ", "%%20")
		assert.same({ "Inspect [Image 1] please" }, normalize({ "Inspect " .. uri .. " please" }))
		assert.equals(path, state.parts[1].source.path)
	end)

	it("attaches multiple quoted paths, PDF and SVG on one line in order", function()
		local pdf, svg = directory .. "/report with spaces.pdf", directory .. "/plot.svg"
		vim.fn.writefile({ "%PDF-test" }, pdf); vim.fn.writefile({ "<svg/>" }, svg)
		local lines = normalize({ "Inspect '" .. path .. "' \"" .. pdf .. "\" " .. svg .. " please" })
		assert.same({ "Inspect '[Image 1]' \"[File 1]\" [Image 2] please" }, lines)
		assert.equals(3, #state.parts)
		assert.equals(path, state.parts[1].source.path)
		assert.equals("application/pdf", state.parts[2].mime)
		assert.equals("image/svg+xml", state.parts[3].mime)
		assert.equals("%PDF-test\n", vim.base64.decode(state.parts[2].url:match("base64,(.*)$")))
	end)
end)
