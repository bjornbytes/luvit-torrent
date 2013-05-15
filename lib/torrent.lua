local math = require('math')
local os = require('os')
local table = require('table')
local string = require('string')

local bencode = require('./bencode')
local listen = require('./listen')
local fs = require('fs')
local http = require('http')
local sha1 = require('./sha1')
local util = require('./util')
local timer = require('timer')

local Object = require('core').Object
local Tracker = require('./tracker')
local Request = require('./request')
local Pipeline = require('./pipeline')
local Cache = require('./cache')

local Torrent = Object:extend()


-- Creates a new Torrent from the .torrent file located at location.
-- Most operations are lazy -- that is it won't attempt to read/download the file
-- until you call start.
function Torrent:initialize(location)
  math.randomseed(os.time())
  self.location = location
  self.peerId = '-Lv0010-' .. math.random(1e11, 9e11)
  self.peers = nil
  
  self.missing = {}
  self.rarity = {}
  
  self.uploadQueue = Pipeline:new(200000, function(req)
    req.peer:send(7, req.piece, req.block, content[req.piece][req.block])
  end)
  self.downloadQueue = Pipeline:new(100000, function(req)
    req.peer:send(6, req.piece, req.block, req.length)
    table.insert(req.peer.pending, req)
  end)
  self.unchokeQueue = {}
  self.interestedQueue = {}
  
  self.remoteLeech = 0
  self.remotePending = 0
  self.remoteSeed = 0
  
  -- Cache 4,000 blocks.
  self.content = Cache:new(4096, function(key, callback)
    local piece, block = key:sub(1, key:match(':') - 1), key:sub(key:match(':') + 1)
    local stream = fs.createReadStream(self.metainfo.info.name, {
      offset = (piece * self.metainfo.info['piece length']) + (block * 16384),
      length = 16384
    })
    local data = ''
    stream:on('data', function(chunk)
      data = data .. chunk
    end)
    stream:on('end', function()
      callback(data)
    end)
  end, function(key, done)
    local piece, block = key:sub(1, key:match(':') - 1), key:sub(key:match(':') + 1)
    
    -- Luvit doesn't have asynchronous write streams :[ TODO
    local stream = fs.createWriteStream(self.metainfo.info.name .. '.part', {
      flags = 'r+',
      offset = (piece * self.metainfo.info['piece length']) + (block * 16384)
    })
    self.content:get(key, function(val)
      stream:write(val)
      stream:close()
      done()
    end)
  end)
end


-- Destroys the torrent gracefully, closing any connections and writing out any
-- data.
function Torrent:destroy()
  --
end


-- Asynchronously reads the metainfo from the .torrent file.
-- If the first 4 characters of location are 'http', then
-- an http get request will be used to retrieve the file.
-- Otherwise, it is assumed to be on the local filesystem.
-- After reading the file, the bencoded dictionary is parsed.
-- The callback has no arguments.
function Torrent:readMetainfo(callback)
  if self.metainfo then return nil end
  
  local function parse(data)
    self.metainfo = bencode.decode(data)
    
    local stream = fs.createWriteStream(self.metainfo.info.name .. '.part', {
      flags = 'w',
      offset = 0
    })
    stream:write(string.rep('0', self.metainfo.info.length))
    stream:close()
    
    self.infoHash = sha1.hash(bencode.encode(self.metainfo.info)):gsub('(%w%w)', function(x)
      return string.char(tonumber(x, 16))
    end)
    local pieces = math.ceil(self.metainfo.info.length / self.metainfo.info['piece length'])
    local blocks = math.ceil(self.metainfo.info['piece length'] / 16384)
    --local i
    for i = 1, pieces do
      self.rarity[i] = 0
      self.missing[i] = {}
      local j
      for j = 1, blocks do
        table.insert(self.missing[i], j - 1)
        local key = tostring(i) .. ':' .. tostring(j)
        self.content[key] = nil
      end
    end
    if callback then callback() end
  end
  
  if self.location.sub(1,4) == 'http' then
    http.get(url, function(res)
      local data = ''

      res:on('data', function(chunk) data = data .. chunk end)
      res:on('end', function() parse(data) end)
    end)
  else
    fs.readFile(self.location, function(err, data) parse(data) end)
  end
end


-- Creates tracker objects for each url in the announce/announceList
-- portions of the metainfo dictionary.
function Torrent:initTrackers()
  if self.trackers then return nil end
  
  self.trackers = {}
  
  if self.metainfo.announce then
    table.insert(self.trackers, Tracker:new(self.metainfo.announce))
  end
  
  if self.metainfo.announceList then
    for _, v in ipairs(self.metainfo.announceList) do
      table.insert(self.trackers, Tracker:new(v))
    end
  end
end


-- High-level message logic.  Lower level logic is in peer.lua.
-- A poor man's switch statement.
local messageHandler = {
  [0] = function(self, peer)
  
    -- If they choke us and we've requested pieces, put these requests back in the pool.
    while #peer.pending > 0 do
      local req = peer.pending[1]
      table.remove(peer.pending, 1)
      table.insert(self.missing[req.piece], req.block)
    end
    
    -- If we were about to request pieces and they choke us, put them back in the pool.
    local i
    for i = 1, #self.downloadQueue.queue do
      if self.downloadQueue.queue[i].obj.peer == peer then
        local req = self.downloadQueue.queue[i]
        table.insert(self.missing[req.piece], req.block)
        table.remove(self.downloadQueue.queue, i)
        i = i - 1
      end
    end
    
    peer.numWant = 0
    self.remoteSeed = self.remoteSeed - 1
  end,
  
  [1] = function(self, peer)
  
    -- After someone unchokes us, start pipelining block requests.
    if peer.interestedTimer then timer.clearTimer(peer.interestedTimer) end
    self.remotePending = self.remotePending - 1
    self.remoteSeed = self.remoteSeed + 1
    
    self:requestPieces(peer)
  end,
  
  [2] = function(self, peer)
    if peer.interested then return end

    self.unchokeQueue[#self.unchokeQueue + 1] = peer
    
    self:fillUnchokeQueue()
  end,
  
  [3] = function(self, peer)
    local i
    for i = 1, #self.uploadQueue do
      local req = self.uploadQueue[i]
      if req.peer == peer.id then
        table.remove(self.uploadQueue, i)
        i = i - 1
      end
    end
    
    for i = 1, #self.unchokeQueue do
      if self.unchokeQueue[i] == peer.id then table.remove(self.unchokeQueue, i) return end
    end
  end,
  
  [4] = function(self, peer, piece)
    self.rarity[piece] = self.rarity[piece] + 1
    
    if self.missing[piece] and #self.missing[piece] > 0 and not peer.interesting then
      self.interestedQueue[#self.interestedQueue + 1] = peer
      peer.interesting = true
      self:pipeInterested()
    end
  end,
  
  [5] = function(self, peer)
    if not peer.interesting then
      local i
      for i = 1, #peer.pieces do
        if peer.pieces[i] == 1 then
          self.rarity[i] = self.rarity[i] + 1
          if self.missing[piece] and #self.missing[piece] > 0 then
            self.interestedQueue[#self.interestedQueue + 1] = peer
            peer.interesting = true
            self:pipeInterested()
            break
          end
        end
      end
    end
  end,
  
  [6] = function(self, peer, piece, offset, length)
    local block = math.floor(offset / 16384)
    if not self.missing[piece] then
      local req = Request:new(piece, block, length, peer)
      self.uploadQueue:add(req, req.length)
    end
  end,
  
  [7] = function(self, peer, piece, offset, body)
    -- TODO Write body to content cache.
    -- TODO Check if it completes a piece.  Do a bunch of work if it does.
    print('Got piece ' .. piece .. ':' .. offset .. '!')
    
    local block = offset
    
    local key = tostring(piece) .. ':' .. tostring(block)
    self.content:set(key, body)
    
    -- The below check can probably be optimized.
    local i
    local complete = true
    for i = 0, math.floor(self.metainfo.info['piece length'] / 16384) - 1 do
      local key = tostring(piece) .. ':' .. tostring(i)
      if not self.content:has(key) then complete = false break end
    end
    if complete == true then
      
      -- Write out piece data.
      -- Luvit doesn't have asynchronous write streams :[ TODO
      local stream = fs.createWriteStream(self.metainfo.info.name .. '.part', {
        flags = 'r+',
        offset = piece * self.metainfo.info['piece length']
      })
      local data = ''
      for i = 0, math.floor(self.metainfo.info['piece length'] / 16384) - 1 do
        local key = tostring(piece) .. ':' .. tostring(i)
        self.content:get(key, function(val)
          print('writing out block ' .. key .. ' (offset ' .. (piece * self.metainfo.info['piece length']) .. ')')
          stream:write(val)
          if i == math.floor(self.metainfo.info['piece length'] / 16384) - 1 then
            stream:close()
          end
        end)
      end
      
      -- Signal that we have the piece to all peers, and clear the missing entry for this piece.
      self.missing[piece] = nil
      for _, v in pairs(self.peers) do
        v:send(4, piece)
      end
    end
    
    for i = 1, #peer.pending do
      if peer.pending[i].piece == piece and peer.pending[i].block == block then break end
    end
    
    table.remove(peer.pending, i)
    
    -- Tell them they're uninteresting if we don't have anything left to ask of them.
    peer.numWant = peer.numWant - 1
    
    if peer.numWant == 0 then
      -- Try to find more pieces to ask them for.
      if self:requestPieces(peer) then return
      else
        peer:send(3)
        peer.interesting = false
      end
    end
  end
}


-- Starts or resumes the torrent.
function Torrent:start()
  -- This will have to be restructured for asynchronousness.
  if not self.metainfo then
    self:readMetainfo(function()
      if not self.trackers then self:initTrackers() end
      if not self.peers then self.peers = {} end
      
      announceHandler = function(peers)
        print('Announce returned ' .. #peers .. ' peers.')
        
        for _, peer in ipairs(peers) do
          peer:connect('BitTorrent protocol', self.infoHash, self.peerId)
          
          peer:on('handshake', function(id)
            self.peers[id] = peer
          end)
          peer:on('message', function(id, ...)
            if id ~= 4 then print('\t\t\t\tReceived ' .. id) end
            messageHandler[id](self, peer, ...)
          end)
        end
      end
      
      for _, tracker in pairs(self.trackers) do
        self:announce(tracker, 'started', announceHandler)
      end
    end)
  end
end


-- Stops the torrent.  It can be started again by calling start.
function Torrent:stop()

end


-- Announces this torrent to the given tracker.  An optional event
-- specifies any event that has taken place ("started", "stopped",
-- or "completed").  After the announce is complete, callback is
-- executed with the parsed response.
function Torrent:announce(tracker, event, callback)
  listen:getPort(function(port)
    local options = {
      infoHash = self.infoHash,
      peerId = self.peerId,
      port = port,
      uploaded = 0,
      downloaded = 0,
      left = self.metainfo.info.length,
      event = event,
      pieces = math.ceil(self.metainfo.info.length / self.metainfo.info['piece length'])
    }
    
    tracker:announce(options, callback)
  end)
end


-- Manages unchoking.
function Torrent:pipeUnchoke()
  
  -- If we aren't uploading to 6 people, pick people from the front of the line and
  -- unchoke them for 10 seconds.
  while self.remoteLeech < 6 and #self.unchokeQueue > 0 do
    local peer = self.unchokeQueue[1]
    table.remove(self.unchokeQueue, 1)
    
    peer:unchoke()
    self.remoteLeech = self.remoteLeech + 1
    timer.setTimeout(10000, function()
      peer:choke()
      self.remoteLeech = self.remoteLeech - 1
      self:pipeUnchoke()
    end)
  end
end


-- Manages sending MSG_INTERESTED
function Torrent:pipeInterested()
  
  -- If we aren't downloading from or waiting on 6 peers, then pick people from front of
  -- line and send them msg_interested.  Download from them as long as possible.
  while self.remotePending + self.remoteSeed < 6 and #self.interestedQueue > 0 do
    local peer = self.interestedQueue[1]
    table.remove(self.interestedQueue, 1)
    
    if peer.choking then
      peer:send(2)
      self.remotePending = self.remotePending + 1
      peer.interestedTimer = timer.setTimeout(5000, function()
        table.insert(self.interestedQueue, peer)
        peer:send(3)
        self.remotePending = self.remotePending - 1
        self:pipeInterested()
      end)
    end
  end
end


function Torrent:requestPieces(peer)
  -- Find the rarest piece they have.  Insert all missing blocks for this piece
  -- into the download queue.
  
  -- Make a copy of our rarity table and sort it by rarity so we can quickly iterate
  -- over the most rare pieces in order.
  -- This is disgusting and needs to be changed in the future. TODO
  local sortedRarity = {}
  for k, v in pairs(self.rarity) do
    table.insert(sortedRarity, {piece = k, rarity = v})
  end
  table.sort(sortedRarity, function(a, b) return a.rarity < b.rarity end)
  
  local i
  local requests = {}
  for i = 1, #sortedRarity do
    local piece = sortedRarity[i].piece
    if peer.pieces[piece] == 1 and self.missing[piece] and #self.missing[piece] > 0 then
      while #self.missing[piece] > 0 do
        local block = self.missing[piece][1]
        local req = Request:new(piece, block, 16384, peer)
        table.remove(self.missing[piece], 1)
        table.insert(requests, req)
      end
      
      break
    end
  end
  
  if #requests == 0 then return false end
  
  local i
  for i = 1, #requests do
    self.downloadQueue:add(requests[i], requests[i].length)
    requests[i].peer.numWant = requests[i].peer.numWant + 1
  end
  
  return true
end

return Torrent