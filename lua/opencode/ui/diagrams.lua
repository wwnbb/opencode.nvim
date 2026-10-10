-- Render native Mermaid/math fences in a local browser document. No source is
-- sent to a rendering service; only version-pinned browser libraries are loaded.
local M = {}
local previews = {}
local kinds = { mermaid = "mermaid", latex = "math", math = "math", tex = "math" }

function M.items(session_id)
	local sync, items = require("opencode.sync"), {}
	if not session_id then return items end
	for _, message in ipairs(sync.get_messages(session_id)) do
		for _, part in ipairs(sync.get_parts(message.id)) do
			local texts = {}
			if part.type == "text" and type(part.text) == "string" then texts[1] = part.text end
			if part.type == "tool" then
				for _, content in ipairs((part.state or {}).content or {}) do
					if content.type == "text" and type(content.text) == "string" then texts[#texts + 1] = content.text end
				end
			end
			for _, text in ipairs(texts) do
				for _, block in ipairs(require("opencode.ui.code_blocks").parse(require("opencode.ui.code_blocks").normalize_text(text))) do
					local lang = block.info:match("^(%S+)")
					local kind = lang and kinds[lang:lower()]
					if kind and block.closed then
						items[#items + 1] = { label = (kind == "mermaid" and "Mermaid" or "LaTeX / Math") .. " " .. (#items + 1),
							description = vim.fn.strcharpart(table.concat(block.lines, " "):gsub("[%c]", " "), 0, 90),
							kind = kind, source = table.concat(block.lines, "\n"), message_id = message.id, part_id = part.id,
							revision = sync.get_part_revision(message.id, part.id) }
					end
				end
			end
		end
	end
	return items
end

function M.html(item)
	if type(item) ~= "table" or (item.kind ~= "mermaid" and item.kind ~= "math") or type(item.source) ~= "string" then
		return nil, "Diagram source is unavailable"
	end
	if vim.trim(item.source) == "" or #item.source > 50000 then return nil, "Preview requires 1–50,000 bytes of source" end
	-- JSON is embedded as data, never interpolated into executable JavaScript.
	local data = vim.json.encode({ kind = item.kind, source = item.source }):gsub("<", "\\u003c"):gsub("&", "\\u0026")
		:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
	local nonce = vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.tempname()):sub(1, 32)
	-- Primary references: mermaid.js.org/config/usage.html; katex.org/docs/browser.
	-- Pin both versions; KaTeX hashes are published by its browser documentation.
	local html = [=[<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; img-src data:; script-src 'nonce-NONCE' https://cdn.jsdelivr.net/npm/mermaid@12.1.0/ https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.js; style-src 'unsafe-inline' https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css; font-src https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/fonts/;">
<title>OpenCode Diagram Preview</title><style>body{font:16px system-ui;margin:2rem;color:#20242b;background:#fff}#preview{overflow:auto;padding:1rem}#preview svg{max-width:100%;height:auto}#status{color:#555}#status.error{color:#b02020}pre{white-space:pre-wrap;overflow-wrap:anywhere}summary{cursor:pointer}</style>
</head><body><h1>Diagram Preview</h1><p id="status" role="status">Loading renderer… Internet access to the pinned library CDN is required.</p><div id="preview"></div><details><summary>Source</summary><pre id="source"></pre></details>
<script id="data" type="application/json">PAYLOAD</script><script nonce="NONCE" type="module">
const data = JSON.parse(document.getElementById('data').textContent);
const status = document.getElementById('status'), target = document.getElementById('preview');
document.getElementById('source').textContent = data.source;
let loading = true;
const timer = setTimeout(() => { if (loading) { status.className = 'error'; status.textContent = 'Renderer unavailable: library loading timed out. Check CDN access and reload.'; } }, 20000);
function loadScript(url, integrity) { return new Promise((resolve, reject) => {
  const script = document.createElement('script'); script.src = url; script.nonce = 'NONCE';
  script.integrity = integrity; script.crossOrigin = 'anonymous';
  script.onload = resolve; script.onerror = () => reject(new Error('Library unavailable; check CDN access.'));
  document.head.append(script);
}); }
try {
  if (data.kind === 'mermaid') {
    const {default: mermaid} = await import('https://cdn.jsdelivr.net/npm/mermaid@12.1.0/dist/mermaid.esm.min.mjs');
    mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,maxTextSize:50000,maxEdges:1000,htmlLabels:false,layout:'dagre',fontFamily:'Arial',
      flowchart:{htmlLabels:false},secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering','htmlLabels','flowchart','themeCSS','fontFamily','layout']});
    const {svg} = await mermaid.render('opencode-diagram', data.source);
    target.innerHTML = svg;
    target.querySelectorAll('a').forEach(a => { a.removeAttribute('href'); a.removeAttribute('xlink:href'); });
    status.textContent = 'Mermaid rendered. Use browser zoom or scrolling to inspect.';
  } else {
    const css = document.createElement('link'); css.rel = 'stylesheet';
    css.href = 'https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.css';
    css.integrity = 'sha384-3rdsX6e5mueWyoweR9NIVmtEsUkokpBT/0ALqKKIBMr9j4qhHkaIkAcGgsE6uVlp'; css.crossOrigin = 'anonymous';
    const styled = new Promise((resolve,reject) => { css.onload = resolve; css.onerror = () => reject(new Error('Math stylesheet unavailable; check CDN access.')); document.head.append(css); });
    await Promise.all([styled,loadScript('https://cdn.jsdelivr.net/npm/katex@0.19.0/dist/katex.min.js','sha384-QFFtAGzvvj+bfgCGxXJlNZZR1nXEZgvG8tDLCCY1F19xl20WlfTYgguB4VcNdxYk')]);
    katex.render(data.source,target,{displayMode:true,throwOnError:true,trust:false,maxExpand:1000,strict:'error'});
    status.textContent = 'LaTeX math rendered. Full TeX documents and unsupported commands require a TeX toolchain.';
  }
  status.className = '';
} catch (error) { target.replaceChildren(); status.className = 'error'; status.textContent = 'Preview unavailable: ' + String(error.message || error); }
finally { loading = false; clearTimeout(timer); }
</script></body></html>]=]
	return (html:gsub("NONCE", nonce):gsub("PAYLOAD", function() return data end))
end

function M.open(item)
	local html, err = M.html(item)
	if not html then return nil, err end
	local path = vim.fn.tempname() .. ".html"
	local fd = vim.uv.fs_open(path, "wx", 384)
	if not fd then return nil, "Could not create diagram preview" end
	local written = vim.uv.fs_write(fd, html, 0)
	local closed = vim.uv.fs_close(fd)
	if written ~= #html or not closed then vim.uv.fs_unlink(path); return nil, "Could not write diagram preview" end
	local ok, result, open_error = pcall(vim.ui.open, path)
	if not ok or not result then vim.uv.fs_unlink(path); return nil, tostring(open_error or result or "Browser preview unavailable") end
	previews[#previews + 1] = path
	return path
end

function M.show()
	local state, pending = require("opencode.state"), require("opencode.session.pending")
	local sid = state.get_session().id
	local items = M.items(sid)
	if #items == 0 then vim.notify("No completed Mermaid or LaTeX/math fences in this session", vim.log.levels.INFO); return end
	local token = pending.token(sid)
	require("opencode.ui.menu").open({ title = " Render Diagrams / Math ", items = items, width = 80,
		on_select = function(item)
			if not pending.is_current(token) or state.get_session().id ~= sid then return end
			if require("opencode.sync").get_part_revision(item.message_id, item.part_id) ~= item.revision then
				vim.notify("Diagram changed; reopen the preview picker", vim.log.levels.WARN); return
			end
			local path, err = M.open(item)
			if not path then vim.notify(err, vim.log.levels.WARN) end
		end })
end

function M.register(palette)
	palette.register({ id = "action.diagrams", title = "Render Diagrams / Math", category = "actions",
		slash = { name = "diagrams", aliases = { "mermaid", "math" } }, run = M.show,
		on_select = function(ctx) return ctx.run() end,
		enabled = function() return require("opencode.state").get_session().id ~= nil end })
end

vim.api.nvim_create_autocmd("VimLeavePre", { group = vim.api.nvim_create_augroup("OpenCodeDiagramPreviews", { clear = true }),
	callback = function() for _, path in ipairs(previews) do vim.uv.fs_unlink(path) end end })
return M
