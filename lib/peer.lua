local table = require('table')
local math = require('math')

local net = require('net')

local readInt = require('./util').readInt
local writeInt = require('./util').writeInt

local Emitter = require('core').Emitter
local buffer = require('buffer')

local Peer = Emitter:extend()

function Peer:initialize(ip, port, pieceCount)
  self.ip = ip
  self.port = port
  self.authenticated = false
  self.buffer = ''
  
  -- In relation to the remote peer.
  self.choked = true
  self.choking = true
  self.interesting = false
  self.interested = false
  
  -- Bitfield representing which pieces this peer has.
  self.pieces = {}
  local i
  for i = 0, pieceCount - 1 do
    self.pieces[i] = 0
  end
  
  -- A list containing blocks which we have requested, but haven't received.
  self.pending = {}
  
  -- A counter containing the number of requests we have queued for the peer.
  self.numWant = 0
  
  -- If we send a MSG_INTERESTED to them and they don't respond in X seconds, then we
  -- drop them and ask someone else.
  self.interestedTimer = nil
end

function Peer:destroy()
  
end

function Peer:connect(protocol, infoHash, peerId)
  if self.authenticated then return end
  
  self.connection = net.createConnection(self.port, self.ip, function()

    local buf = buffer.Buffer:new(1 + #protocol + 8 + 20 + 20)
    
    -- Write the protocol length.
    buf[1] = #protocol
    
    local i
    
    -- Write the protocol string.
    for i = 1, #protocol do
      buf[i + 1] = protocol:byte(i)
    end
    
    -- Write the reserved bytes.
    for i = 21, 28 do
      buf[i] = 0
    end
    
    -- Write the info hash.
    i = 29
    for i = 29, 48 do
      buf[i] = infoHash:byte(i - 28)
    end
    
    -- Write the peer id.
    for i = 49, 68 do
      buf[i] = peerId:byte(i - 48)
    end
    
    self.connection:write(buf:toString())
  end)
  
  self.connection:once('data', function(data)
    
    -- Parse the protocol.
    local pLen = data:byte(1)
    local pProtocol = data:sub(2, 2 + pLen - 1)
    if pProtocol ~= protocol then
      debug('Unknown protocol "' .. pProtocol .. '".')
      self:emit('handshake', 'Unknown protocol "' .. pProtocol .. '".')
      return
    end
    data = data:sub(2 + pLen)
    
    -- Parse the reserved bytes.
    -- local pReserved = data:sub(1, 8)
    data = data:sub(9)
    
    -- Parse the info hash.
    local pInfoHash = data:sub(1, 20)
    if pInfoHash ~= infoHash then
      debug('Invalid info hash "' .. pInfoHash .. '" does not match "' .. infoHash .. '".')
      self:emit('handshake', 'Invalid info hash "' .. pInfoHash .. '".')
      return
    end
    data = data:sub(21)
    
    -- Parse the peer id.
    local pPeerId = data:sub(1, 20)
    self.id = pPeerId
    data = data:sub(21)
    
    self.authenticated = true
    self:emit('handshake', self.id)
    
    print('Handshake complete.')
    
    self.connection:emit('data', data, true) -- Let our main parse function parse the bitfield.
  end)
  
  self.connection:on('data', function(data)
    if self.authenticated then
      
      -- Keepalives.
      if #data == 0 then return end
      
      -- We work on a local copy of self.buffer .. data.
      -- Then we continually parse messages on this copy.
      -- If we successfully parse a message, we remove the relevant bytes
      -- from our buffer.  If we fail to parse something, we put it back into
      -- the buffer, assuming the rest of the message will arrive later.
      local str = self.buffer .. data
      
      while true do
        if #str < 5 then
          self.buffer = str
          break
        end
        
        local len = readInt(str:sub(1, 4))
        if #str < 4 + len then
          self.buffer = str
          break
        end
        
        local id = str:byte(5)
        
        -- Payload is a list of values which gets unpack'd.
        local payload = {}
        
        -- Peer housekeeping goes in here.  Higher level logic is in torrent.lua.
        if id == 0 then self.choking = true
        elseif id == 1 then self.choking = false
        elseif id == 2 then self.interested = true
        elseif id == 3 then self.interested = false
        elseif id == 4 then
          local piece = readInt(str:sub(6, 9))
          table.insert(payload, piece)
          self.pieces[piece] = 1
        elseif id == 5 then
          local bitfield = str:sub(6, 6 + len - 1)

          local j, i = 0
          for i = 1, #bitfield do
            local b = bitfield:byte(i)
            local k = 7
            while b > 0 and j < #self.pieces do
              local rem = b % 2
              self.pieces[j + k] = rem
              k = k - 1
              if k == -1 then
                j = j + 8
              end
              b = math.floor(b / 2)
            end
          end
        elseif id == 6 then
          table.insert(payload, readInt(str:sub(6, 9)))
          table.insert(payload, readInt(str:sub(10, 13)))
          table.insert(payload, readInt(str:sub(14, 17)))
        elseif id == 7 then
          table.insert(payload, readInt(str:sub(6, 9)))
          table.insert(payload, readInt(str:sub(10, 13)))
          table.insert(payload, str:sub(14, 14 + len - 10))
        elseif id == 8 then
            table.insert(payload, readInt(str:sub(6, 9)))
            table.insert(payload, readInt(str:sub(10, 13)))
            table.insert(payload, readInt(str:sub(14, 17)))
        elseif id == 9 then table.insert(payload, readInt(str:sub(6, 7))) end
        
        self:emit('message', id, unpack(payload))
        
        str = str:sub(4 + len + 1)
      end
    end
  end)
  
  self.connection:on('error', function(err)
    print('Socket error: ' .. err.message)
    self.connection:destroy()
  end)
end


--
function Peer:send(id, ...)
  local len, msg
  local args = {...}
  if id < 4 then len = 1
  elseif id == 4 then len = 5
  elseif id == 6 then len = 13 end
  
  msg = writeInt(len, 4) .. writeInt(id, 1)
  
  if id == 4 then msg = msg .. writeInt(args[1], 4)
  elseif id == 6 then msg = msg .. writeInt(args[1], 4) .. writeInt(args[2], 4) .. writeInt(args[3], 4) end
  
  -- print('Sent ' .. id)
  self.connection:write(msg)
end


function Peer:choke()
  self.choked = true
  self:send(0)
end


function Peer:unchoke()
  self.choked = false
  self:send(1)
end

return Peer