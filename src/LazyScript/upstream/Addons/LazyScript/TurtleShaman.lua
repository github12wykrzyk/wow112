local baseLoadAddOnByClass = lazyScript.LoadAddOnByClass

function lazyScript.LoadAddOnByClass(class)
	local result1, result2 = baseLoadAddOnByClass(class)
	if class == "SHAMAN" and lazyScript.actions and not lazyScript.actions.lightningStrike then
		lazyScript.actions.lightningStrike = lazyScript.Action:New("lightningStrike", nil, false, true, false, "Lightning Strike")
	end
	return result1, result2
end
