local util = {}

local string = require('string')
local table = require('table')
local math = require('math')


-- orderedPairs
local function __genOrderedIndex(t)
  local orderedIndex = {}
  for key in pairs(t) do
    table.insert(orderedIndex, key)
  end
  table.sort(orderedIndex)
  return orderedIndex
end

local function orderedNext(t, state)
  -- Equivalent of the next function, but returns the keys in the alphabetic
  -- order. We use a temporary ordered key table that is stored in the
  -- table being iterated.

  --print("orderedNext: state = "..tostring(state) )
  if state == nil then
    -- the first time, generate the index
    t.__orderedIndex = __genOrderedIndex(t)
    key = t.__orderedIndex[1]
    return key, t[key]
  end
  -- fetch the next value
  key = nil
  for i = 1,table.getn(t.__orderedIndex) do
    if t.__orderedIndex[i] == state then
      key = t.__orderedIndex[i+1]
    end
  end

  if key then
    return key, t[key]
  end

  -- no more value to return, cleanup
  t.__orderedIndex = nil
  return
end

function util.orderedPairs(t) return orderedNext, t, nil end


-- Reading big-endian numbers.
-- See http://lua-users.org/wiki/ReadWriteFormat
function util.readInt(str)
  local function _b2n(num, digit, ...)
    if not digit then return num end
    return _b2n(num*256 + digit, ...)
  end
  return _b2n(0, string.byte(str, 1, -1))
end

function util.writeInt(num, width)
  local function _n2b(t, width, num, rem)
    if width == 0 then return table.concat(t) end
    table.insert(t, 1, string.char(rem * 256))
    return _n2b(t, width-1, math.modf(num/256))
  end
  return _n2b({}, width, math.modf(num/256))
end


-- Linked lists.
local Object = require('core').Object

local LinkedList = Object:extend()

function LinkedList:initialize()
  self.head = nil
  self.tail = nil
  self.length = 0
end

function LinkedList:insert(val)
  local node = {
    val = val,
    next = self.head,
    prev = nil
  }
  
  if self.head then self.head.prev = node end
  if self.tail == nil then self.tail = node end
  
  self.head = node
  self.length = self.length + 1
  return node
end

function LinkedList:append(val)
  local node = {
    val = val,
    next = nil,
    prev = self.tail
  }
  
  if self.tail then self.tail.next = node end
  if self.head == nil then self.head = node end
  
  self.tail = node
  self.length = self.length + 1
  return node
end

function LinkedList:remove(node)
  if node.prev then node.prev.next = node.next else self.head = node.next end
  if node.next then node.next.prev = node.prev else self.tail = node.prev end
  node = nil
  self.length = self.length - 1
end

util.LinkedList = LinkedList

return util