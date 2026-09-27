describe("clipboard image files", function()
	local path
	after_each(function() if path then vim.fn.delete(path) end end)

	it("encodes file bytes as base64 and preserves the explicit MIME type", function()
		path = vim.fn.tempname() .. ".png"
		vim.fn.writefile({ "abc" }, path)
		local content, err = require("opencode.clipboard").read_image_file(path, "image/png")
		assert.is_nil(err)
		assert.equals("YWJjCg==", content.data)
		assert.equals("image/png", content.mime)
	end)
end)
