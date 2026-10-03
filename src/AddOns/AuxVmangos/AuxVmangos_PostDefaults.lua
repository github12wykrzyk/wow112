-- AUX Post defaults for WoW 1.12.1.
-- Keep upstream aux-addon pinned; force a deterministic initial stack size of 1
-- on every character without relying on upstream account/character settings.

local post_tab = require 'aux.tabs.post'

local function avm_force_stack_one()
	local slider = post_tab and post_tab.stack_size_slider
	if not post_tab or not post_tab.selected_item or not slider then return end

	slider:SetValue(1)
	-- Upstream calculated stack_count against its own random/max default before
	-- this overlay ran. Recalculate after forcing 1 so the count limit matches
	-- the new stack size rather than the stale previous/default value.
	if post_tab.quantity_update then post_tab.quantity_update(true) end
	if slider.editbox then slider.editbox:SetNumber(1) end
	post_tab.refresh = true
end

if post_tab and post_tab.update_item and not post_tab._avmStackOneDefaultInstalled then
	local oldUpdateItem = post_tab.update_item
	post_tab.update_item = function(item)
		local result = oldUpdateItem(item)
		avm_force_stack_one()
		return result
	end
	post_tab._avmStackOneDefaultInstalled = true
	post_tab.AVM_ForceStackOne = avm_force_stack_one
end
