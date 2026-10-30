describe("HTTP request framing", function()
	local transport = require("opencode.client.transport")
	local tcp = require("opencode.client.tcp_connection")
	local original_open, opened
	before_each(function()
		original_open, opened = tcp.open, {}
		tcp.open = function(opts)
			opened[#opened + 1] = opts.data
			return nil, { message = "Connection stub" }
		end
	end)
	after_each(function() tcp.open = original_open end)

	it("delivers REST responses and failures after exactly one scheduler hop", function()
		local http = require("opencode.client.http")
		local saved_opts, original_schedule, queued = http.opts, vim.schedule, {}
		http.opts = vim.tbl_extend("force", http.opts, { host = "127.0.0.1", port = 4096, url = false, tls = nil })
		vim.schedule = function(fn) queued[#queued + 1] = fn end
		local ok, err = pcall(function()
			for _, reply in ipairs({
				"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}",
				"HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n",
				false,
			}) do
				tcp.open = function(opts)
					if not reply then return nil, { message = "refused" } end
					opts.on_read(nil, reply)
					return { close = function() end }
				end
				local results = {}
				http.get("/api/info", function(e, body) results[#results + 1] = { e, body } end)
				assert.equals(1, #queued)
				table.remove(queued, 1)()
				assert.equals(0, #queued)
				assert.equals(1, #results)
				if reply and reply:find("200") then assert.same({ ok = true }, results[1][2]) else assert.is_table(results[1][1]) end
			end
		end)
		vim.schedule, http.opts = original_schedule, saved_opts
		assert(ok, err)
	end)

	local invalid = {
		{ method = "GET\r\nInjected: yes" }, { path = "/test\r\nInjected: yes" }, { path = "/bad path" },
		{ body = {} }, { headers = { ["X:Other"] = "value" } }, { headers = { X = "value\r\nInjected: yes" } },
		{ host = "localhost\r\nInjected: yes" }, { headers = { Host = "one", HOST = "two" } },
	}
	for _, kind in ipairs({ "request", "stream" }) do
		it("rejects invalid " .. kind .. " fields before connecting", function()
			for _, fields in ipairs(invalid) do
				local opts = vim.tbl_extend("force", { host = "localhost", port = 1234 }, fields)
				local received, completions = nil, 0
				if kind == "request" then
					local handle = transport.request(opts, function(err, response)
						received, completions = err, completions + 1
						assert.is_nil(response)
					end)
					assert.is_nil(handle)
					assert.is_true(vim.wait(100, function() return completions == 1 end, 5))
				else
					local stream, err = transport.open_stream(opts)
					assert.is_nil(stream)
					received = err
				end
				assert.is_table(received)
				assert.is_string(received.message)
				assert.same({}, opened)
			end
		end)
	end

	it("uses mixed-case overrides exactly once in requests and streams", function()
		local opts = { host = "localhost", port = 1234, body = "body",
			headers = { hOsT = "override:1234", cOnNeCtIoN = "close", ["CONTENT-LENGTH"] = 4 } }
		local completions = 0
		transport.request(opts, function() completions = completions + 1 end)
		transport.open_stream(opts)
		assert.equals(2, #opened)
		for _, data in ipairs(opened) do
			local headers = {}
			for name, value in data:gmatch("\r\n([^:\r\n]+): ([^\r\n]*)") do
				local key = name:lower()
				assert.is_nil(headers[key], "duplicate header " .. key)
				headers[key] = value
			end
			assert.equals("override:1234", headers.host)
			assert.equals("close", headers.connection)
			assert.equals("4", headers["content-length"])
		end
		assert.is_true(vim.wait(100, function() return completions == 1 end, 5))
	end)

	it("keeps valid tokens, IPv6, numeric headers and arbitrary body bytes", function()
		local body = "body\r\n\0tail"
		local opts = { host = "::1", port = 1234, method = "post", path = "/api?name=a%20b",
			headers = { ["X-HTTP_Test!"] = 42 }, body = body }
		local completions = 0
		for _, host in ipairs({ "::1", "[::1]" }) do
			opts.host = host
			transport.request(opts, function() completions = completions + 1 end)
			transport.open_stream(opts)
		end
		assert.equals(4, #opened)
		for _, request in ipairs(opened) do
			assert.is_truthy(request:find("POST /api?name=a%20b HTTP/1.1\r\n", 1, true))
			assert.is_truthy(request:find("Host: [::1]:1234\r\n", 1, true))
			assert.is_truthy(request:find("X-HTTP_Test!: 42\r\n", 1, true))
			assert.is_truthy(request:find("Content-Length: " .. #body .. "\r\n", 1, true))
			assert.equals(body, request:sub(-#body))
		end
		assert.is_true(vim.wait(100, function() return completions == 2 end, 5))
	end)
end)
