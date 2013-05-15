local LinkedList = require('./util').LinkedList

local Object = require('core').Object

local Cache = Object:extend()

function Cache:initialize(max, fetch, free)
  
  -- List of keys ordered by recency..
  self.chronList = LinkedList:new()
  
  self.cache = {}
  self.max = max
  
  -- Functions for retrieving elements not in the cache and writing out elements which
  -- drop out of the cache, respectively.
  self.fetch = fetch
  self.free = free
end


-- Returns whether the cache contains the key, without updating its recency or fetching it.
function Cache:has(key)
  return self.cache[key] ~= nil
end


-- Returns the value for the specified key, fetching the value if it is not cached.
function Cache:get(key, callback)
  if self.cache[key] ~= nil then
    
    self.chronList:remove(self.cache[key].chron)
    self.chronList:insert(key)
    
    return callback(self.cache[key].val)
  else
    if self.chronList.length >= self.max then self:evict() end
    self.fetch(key, function(val)
      self.cache[key] = {
        val = val,
        chron = self.chronList:insert(key)
      }
      callback(val)
    end)
  end
end


-- Sets the value for the specified key, updating its recency.
function Cache:set(key, val)
  if self.cache[key] ~= nil then
    self.cache[key].val = val
    
    self.chronList:remove(self.cache[key].chron)
    self.chronList:insert(key)
  else
    if self.chronList.length >= self.max then self:evict() end
    
    self.cache[key] = {
      val = val,
      chron = self.chronList:insert(key)
    }
  end
end


-- Frees the least-recently-used element.
function Cache:evict()
  local key = self.chronList.tail.val
  if self.free then self.free(key, self.cache[key].val, function()
      self.cache[key] = nil
      self.chronList:remove(self.chronList.tail)
    end)
  end
end


return Cache