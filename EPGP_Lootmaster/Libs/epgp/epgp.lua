GetCustomSlotInfo = function(itemLink)
  local GP = LibStub("LibGearPoints-1.0", true)
  if not itemLink or not GP then return end
  local _, _, level, rarity, equipLoc = GP:GetValue(itemLink, true)
  return equipLoc, rarity, level
end

GetGPValue = function(itemLink, noRecent)
  local GP = LibStub("LibGearPoints-1.0", true)
  if not itemLink or not GP then return end
  return GP:GetValue(itemLink, noRecent)
end
