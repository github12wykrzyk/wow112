-- AUX Post defaults for WoW 1.12.1.
-- Keep upstream aux-addon pinned; only change the initial stack-size selection.

local post_tab = require 'aux.tabs.post'

if post_tab and post_tab.update_item and not post_tab._avmStackOneDefaultInstalled then
	local oldUpdateItem = post_tab.update_item
	post_tab.update_item = function(item)
		local result = oldUpdateItem(item)
		local slider = post_tab.stack_size_slider
		if post_tab.selected_item and slider then
			slider:SetValue(1)
			if slider.editbox then slider.editbox:SetNumber(1) end
			post_tab.refresh = true
		end
		return result
	end
	post_tab._avmStackOneDefaultInstalled = true
end
