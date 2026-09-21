-- PARALLEL: bounded, read-only LazyScript / MovementCore diagnostic bridge.
-- No cast authorization, spell cancellation or movement mutation.
lazyScript.rearTrace = {
 rows={}, max=72, enabled=true, native=nil, nativeAt=nil,
 lastKey=nil, lastKeyAt=0
}
-- Bounded diagnostic snapshot; WoW saves this on logout, without chat spam.
lsRearDiag = "W112-REAR-V1|empty"
local function saveRearTrace()
 local d=lazyScript.rearTrace
 if not d then return end
 local n=d.native
 local snap="native:none"
 if n then
  snap="native:status="..tostring(n.status).." attempts="..tostring(n.attempts)..
   " sends="..tostring(n.sends).." positional="..tostring(n.positional)..
   " retries="..tostring(n.retries).." reason="..tostring(n.failReason)..
   " spellgo="..tostring(n.spellGo).." aborted="..tostring(n.aborted)..
   " queue="..tostring(n.sendPending).."/"..tostring(n.resultPending)..
   " hooks="..tostring(n.castHook).."/"..tostring(n.moveHook)..
   " prearm="..tostring(n.prearm).."/"..tostring(n.prearmPulses)..
   " starts="..tostring(n.prearmStarts)
 end
 lsRearDiag="W112-REAR-V1|"..table.concat(d.rows,"|").."|"..snap
end
function lazyScript.RearTrace(kind, detail)
 local d=lazyScript.rearTrace
 if not d or not d.enabled then return end
 local now=GetTime()
 local key=tostring(kind)..":"..tostring(detail or "")
 if key==d.lastKey and now-d.lastKeyAt<0.3 then return end
 d.lastKey=key;d.lastKeyAt=now
 table.insert(d.rows,string.format("%.2f",now).." "..key)
 if table.getn(d.rows)>d.max then table.remove(d.rows,1) end
 saveRearTrace()
end
function lazyScript.OnRearNativeTelemetry(status,attempts,sends,busy,positional,
 retries,failReason,spellGo,aborted,sendPending,resultPending,castHook,moveHook,
 prearm,prearmPulses,prearmStarts)
 local d=lazyScript.rearTrace
 if not d then return end
 local now=GetTime()
 local snap={status=status,attempts=attempts,sends=sends,busy=busy,
  positional=positional,retries=retries,failReason=failReason,
  spellGo=spellGo,aborted=aborted,sendPending=sendPending,
  resultPending=resultPending,castHook=castHook,moveHook=moveHook,
  prearm=prearm,prearmPulses=prearmPulses,prearmStarts=prearmStarts}
 local old=d.native
 d.native=snap;d.nativeAt=now
 saveRearTrace()
 if not d.enabled then return end
 if not old then
  lazyScript.RearTrace("native_attach","status="..tostring(status)..
   " hooks="..tostring(castHook).."/"..tostring(moveHook))
  return
 end
 local keys={"attempts","sends","busy","positional","retries","spellGo","aborted","prearmStarts"}
 for _,key in ipairs(keys) do
  if snap[key]~=old[key] then
   lazyScript.RearTrace("native_"..key,tostring(old[key]).."->"..tostring(snap[key])..
    " status="..tostring(status).." reason="..tostring(failReason))
  end
 end
 if status~=old.status or prearm~=old.prearm or sendPending~=old.sendPending or
  resultPending~=old.resultPending or castHook~=old.castHook or
  moveHook~=old.moveHook then
  lazyScript.RearTrace("native_state","status="..tostring(status)..
   " prearm="..tostring(prearm).." pulses="..tostring(prearmPulses)..
   " queue="..tostring(sendPending).."/"..tostring(resultPending)..
   " hooks="..tostring(castHook).."/"..tostring(moveHook))
 end
end
function lazyScript.PrintRearTrace(option)
 local d=lazyScript.rearTrace
 if not d then return end
 if option=="clear" then
  d.rows={};d.native=nil;d.nativeAt=nil;d.lastKey=nil
  saveRearTrace()
  lazyScript.chat("[RearTrace] cleared.")
  return
 end
 if option=="off" or option=="on" then
  d.enabled=(option=="on")
  lazyScript.chat("[RearTrace] logging "..(d.enabled and "ON" or "OFF")..".")
  return
 end
 local n=tonumber(option) or 12
 if n<1 then n=1 elseif n>25 then n=25 end
 local age=d.nativeAt and (GetTime()-d.nativeAt) or nil
 if age and age<=3 then
  local s=d.native
  lazyScript.chat("[RearTrace] native LIVE age="..string.format("%.1f",age)..
   "s status="..tostring(s.status).." hooks="..tostring(s.castHook).."/"..tostring(s.moveHook)..
   " attempts="..tostring(s.attempts).." sends="..tostring(s.sends)..
   " busy="..tostring(s.busy).." behind/range="..tostring(s.positional)..
   " spell_go="..tostring(s.spellGo).." aborted="..tostring(s.aborted)..
   " prearm="..tostring(s.prearm).." pulses="..tostring(s.prearmPulses))
 else
  lazyScript.chat("[RearTrace] native ABSENT/STALE; bridge not confirmed.")
 end
 lazyScript.chat("[RearTrace] last "..tostring(n).." events (client clock; counters cumulative, not per-attempt results):")
 local first=table.getn(d.rows)-n+1
 if first<1 then first=1 end
 for i=first,table.getn(d.rows) do lazyScript.chat("[RearTrace] "..d.rows[i]) end
end
