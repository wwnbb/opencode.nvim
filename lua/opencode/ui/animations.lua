-- opencode.nvim - Animation frames module
-- Collection of terminal-friendly loading animations

local M = {}

-- Animation definitions with frames
M.animations = {
	{
		name = "Spinning Bar",
		frames = { "|", "/", "-", "\\", "|", "/", "-", "\\" }, -- 8 frames
	},

	{
		name = "Chasing Dots",
		frames = {
			"o . . .",
			". o . .",
			". . o .",
			". . . o",
			". . o .",
			". o . .",
			"o . . .",
			". o . .",
		}, -- 8 frames
	},

	{
		name = "KITT Scanner",
		frames = {
			"[>        ]",
			"[ >       ]",
			"[  >      ]",
			"[   >     ]",
			"[    >    ]",
			"[     >   ]",
			"[      >  ]",
			"[       > ]",
			"[        >]",
			"[       < ]",
			"[      <  ]",
			"[     <   ]",
			"[    <    ]",
			"[   <     ]",
			"[  <      ]",
			"[ <       ]",
		},
	},

	{
		name = "Growing Bar",
		frames = {
			"[          ]",
			"[#         ]",
			"[##        ]",
			"[###       ]",
			"[####      ]",
			"[#####     ]",
			"[######    ]",
			"[#######   ]",
			"[########  ]",
			"[######### ]",
		}, -- 10 frames
	},

	{
		name = "Bounce",
		frames = {
			"( o       )",
			"(  o      )",
			"(   o     )",
			"(    o    )",
			"(     o   )",
			"(      o  )",
			"(       o )",
			"(        o)",
			"(       o )",
			"(      o  )",
			"(    o    )",
			"(   o     )",
			"(  o      )",
			"( o       )",
			"(o        )",
		}, -- 8 frames
	},

	{
		name = "Flame Flicker",
		frames = { ".", "'", "*", "'", ".", ",", "`", "." }, -- 8 frames
	},

	{
		name = "Orbit",
		frames = {
			"· o ·",
			"·  . o .",
			"· o ·",
			"·  . o .",
			"· o ·",
			"·  . o .",
			"· o ·",
			"·  . o .",
		}, -- 8 frames
	},

	{
		name = "Typing",
		frames = { "[.]", "[..]", "[...]", "[....]", "[.....]", "[....]", "[...]", "[..]" }, -- 8 frames
	},

	{
		name = "Ping-Pong Arrow",
		frames = {
			"<--->",
			"<- -- >",
			"<-  -->",
			"<-   ->",
			"<-  -->",
			"<- -- >",
			"<--->",
			">--<",
		}, -- 8 frames
	},
}

-- Get a random animation
---@return table Animation definition with name and frames
function M.get_random()
	math.randomseed(os.time() + os.clock() * 1000)
	local idx = math.random(1, #M.animations)
	return M.animations[idx]
end

-- Get animation by name
---@param name string Animation name
---@return table|nil Animation definition or nil if not found
function M.get_by_name(name)
	for _, anim in ipairs(M.animations) do
		if anim.name == name then
			return anim
		end
	end
	return nil
end

-- Get all animation names
---@return table List of animation names
function M.get_names()
	local names = {}
	for _, anim in ipairs(M.animations) do
		table.insert(names, anim.name)
	end
	return names
end

-- Get animation count
---@return number Number of available animations
function M.count()
	return #M.animations
end

return M
