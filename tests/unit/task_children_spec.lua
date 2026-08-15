-- Unit checks for the pure child-session assignment algorithm extracted
-- from opencode.ui.chat.tasks into opencode.ui.chat.task_children.
-- Run with: ./tests/run.sh tests/unit/task_children_spec.lua

describe("opencode task children", function()
	local function resolve(children, items, excluded)
		vim.opt.runtimepath:append(vim.fn.getcwd())
		local task_children = require("opencode.ui.chat.task_children")
		return task_children.resolve_child_assignments(children, items, excluded or {})
	end

	local function make_item(part_id, description, subagent_type, start_time)
		return {
			part_id = part_id,
			message_id = "m_" .. part_id,
			parent_session_id = "ps",
			input = { description = description, subagent_type = subagent_type },
			start_time = start_time,
		}
	end

	it("assigns on description substring match with score 4", function()
		local item = make_item("p1", "Find the config", nil, nil)
		local children = {
			{ id = "c1", title = "@explore subagent - Find the config", time = { created = 0 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 1, "description match should assign")
		assert(assignments[1].child.id == "c1", "wrong child assigned")
		assert(assignments[1].score == 4, "description-only match should score 4, got " .. tostring(assignments[1].score))
	end)

	it("assigns on @subagent title marker with score 3", function()
		local item = make_item("p1", "", "explore", nil)
		local children = {
			{ id = "c1", title = "Some @explore subagent run", time = { created = 0 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 1, "marker match should assign")
		assert(assignments[1].score == 3, "marker-only match should score 3, got " .. tostring(assignments[1].score))
	end)

	it("falls back to agent/mode field equality with score 2", function()
		local item = make_item("p1", "", "explore", nil)
		local children = {
			{ id = "c1", title = "Unrelated title", agent = "explore", time = { created = 0 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 1, "agent equality fallback should assign")
		assert(assignments[1].score == 2, "agent fallback should score 2, got " .. tostring(assignments[1].score))

		local mode_children = {
			{ id = "c2", title = "Unrelated title", mode = "explore", time = { created = 0 } },
		}
		local mode_assignments = resolve(mode_children, { make_item("p2", "", "explore", nil) }, {})
		assert(#mode_assignments == 1, "mode equality fallback should assign")
		assert(mode_assignments[1].score == 2, "mode fallback should score 2")
	end)

	it("scores the time window as +2 / +1 / +0", function()
		local function time_score(delta)
			local item = make_item("p1", "", "probe", 1000000)
			local children = {
				{ id = "c1", title = "plain", agent = "probe", time = { created = 1000000 + delta } },
			}
			local assignments = resolve(children, { item }, {})
			assert(#assignments == 1, "agent baseline should always assign")
			return assignments[1].score
		end

		assert(time_score(5000) == 4, "delta <= 10000 should add 2")
		assert(time_score(10000) == 4, "delta == 10000 boundary should add 2")
		assert(time_score(60000) == 3, "10000 < delta <= 120000 should add 1")
		assert(time_score(120000) == 3, "delta == 120000 boundary should add 1")
		assert(time_score(200000) == 2, "delta > 120000 should add 0")
	end)

	it("uses time proximity as the deciding factor between equal matches", function()
		local item = make_item("p1", "", "probe", 1000000)
		local children = {
			{ id = "far", title = "plain", agent = "probe", time = { created = 1060000 } },
			{ id = "near", title = "plain", agent = "probe", time = { created = 1003000 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 1, "exactly one child should win")
		assert(assignments[1].child.id == "near", "closer child should win, got " .. tostring(assignments[1].child.id))
		assert(assignments[1].score == 4, "near child should score 2+2")
	end)

	it("rejects item-level ties between equally scored children", function()
		local item = make_item("p1", "Same task", nil, nil)
		local children = {
			{ id = "c1", title = "Same task", time = { created = 1000 } },
			{ id = "c2", title = "Also Same task", time = { created = 1000 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 0, "tied top scores must produce no assignment, got " .. #assignments)
	end)

	it("assigns parallel items without reusing children", function()
		local descriptions = { "inventory commands", "check helpers", "audit keymaps" }
		local items = {}
		for i, desc in ipairs(descriptions) do
			items[i] = make_item("p" .. i, desc, "probe", 1000 + i * 1000)
		end
		local children = {
			{ id = "c3", title = "run: audit keymaps", time = { created = 5000 } },
			{ id = "c1", title = "run: inventory commands", time = { created = 3000 } },
			{ id = "c2", title = "run: check helpers", time = { created = 4000 } },
		}
		local assignments = resolve(children, items, {})
		assert(#assignments == 3, "all three items should assign, got " .. #assignments)
		local used = {}
		for _, assignment in ipairs(assignments) do
			assert(not used[assignment.child.id], "child reused: " .. assignment.child.id)
			used[assignment.child.id] = true
			local expected_child = "c" .. assignment.item.part_id:sub(2)
			assert(assignment.child.id == expected_child, "item " .. assignment.item.part_id .. " mapped to " .. assignment.child.id)
		end
	end)

	it("skips excluded children", function()
		local item = make_item("p1", "", "probe", nil)
		local children = {
			{ id = "c1", title = "plain", agent = "probe", time = { created = 0 } },
			{ id = "c2", title = "@probe subagent", time = { created = 0 } },
		}
		local assignments = resolve(children, { item }, { c1 = true })
		assert(#assignments == 1, "only the non-excluded child can assign")
		assert(assignments[1].child.id == "c2", "excluded child must never be assigned")
	end)

	it("returns empty for empty children or empty items", function()
		local item = make_item("p1", "desc", nil, nil)
		assert(#resolve({}, { item }, {}) == 0, "empty children yields no assignments")
		assert(#resolve({ { id = "c1", title = "x" } }, {}, {}) == 0, "empty items yield no assignments")
	end)

	it("assigns leftover items in a second round after child removal", function()
		local items = {
			make_item("p1", "alpha beta", nil, nil),
			make_item("p2", "beta", nil, nil),
		}
		local children = {
			{ id = "c1", title = "alpha beta", time = { created = 0 } },
			{ id = "c2", title = "beta", time = { created = 0 } },
		}
		local assignments = resolve(children, items, {})
		assert(#assignments == 2, "both items should eventually assign, got " .. #assignments)
		local by_part = {}
		for _, assignment in ipairs(assignments) do
			by_part[assignment.item.part_id] = assignment.child.id
		end
		assert(by_part.p1 == "c1", "p1 should take the shared child first")
		assert(by_part.p2 == "c2", "p2 should assign to the leftover child in round two")
	end)

	it("ignores children with non-string or empty ids", function()
		local item = make_item("p1", "Find me", nil, nil)
		local children = {
			{ id = 123, title = "Find me", time = { created = 0 } },
			{ id = "", title = "Find me", time = { created = 0 } },
		}
		local assignments = resolve(children, { item }, {})
		assert(#assignments == 0, "invalid-id children must be ignored, got " .. #assignments)
	end)
end)
