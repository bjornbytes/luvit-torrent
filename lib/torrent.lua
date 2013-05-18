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
  self.trackers = nil
  self.metainfo = nil
  
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

  -- Memory-store for all in-progress pieces (possibly introduce caching system).
  self.content = {}
  
  process:on('exit', function() self:destroy() end)
end


-- Destroys the torrent gracefully, closing any connections and writing out any
-- data.
function Torrent:destroy()
  
  -- Close connections with all peers.
  if peers then
    for _, v in pairs(self.peers) do
      peer.connection:destroy()
    end
  end
  
  -- Emit a stopped event to all trackers.
  for _, tracker in pairs(self.trackers) do
    self:announce(tracker, 'stopped')
  end
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
    
    -- Decode metainfo dictionary, initialize frequently-used values.
    self.metainfo = bencode.decode(data)
    self.infoHash = sha1.hash(bencode.encode(self.metainfo.info)):gsub('(%w%w)', function(x)
      return string.char(tonumber(x, 16))
    end)
    self.pieceCount = math.ceil(self.metainfo.info.length / self.metainfo.info['piece length'])
    self.blockCount = math.ceil(self.metainfo.info['piece length'] / 16384)

    -- Initialize datastructures used in representing information about pieces.
    for i = 0, self.pieceCount - 1 do
      self.rarity[i] = 0
      self.content[i] = {}
      self.missing[i] = {}
      local j
      for j = 0, self.blockCount - 1 do
        table.insert(self.missing[i], j)
      end
    end
    
    if callback then callback() end
  end
  
  -- Perform the actual request.
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
      local req = self.downloadQueue.queue[i].obj
      if req and req.peer == peer then
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
    local block = offset / 16384
    
    local key = tostring(piece) .. ':' .. tostring(block)
    print('Got piece ' .. key)
    self.content[piece][block] = body
    
    -- Check to see if this block completes the piece (can probably be optimized).
    local complete = true

    for i = 0, self.blockCount - 1 do
      if self.content[piece][i] == nil then complete = false break end
    end
    
    -- Hash check and write out the piece if we finished it.
    if complete == true then
      local pieceData = table.concat(self.content[piece], '', 0, self.blockCount - 1)
      
      if self:hashCheck(piece, pieceData) == false then
        debug('Hash check failed for piece ' .. piece)
        return
      else
        self:writePiece(piece, pieceData)
        
        self.missing[piece] = nil
        
        -- Send haves to everyone.
        for _, v in pairs(self.peers) do
          v:send(4, piece)
        end
        
        self.content[piece] = nil
      end
    end
    
    for i = 1, #peer.pending do
      if peer.pending[i].piece == piece and peer.pending[i].block == block then
        table.remove(peer.pending[i])
        break
      end
    end
    
    -- If this is the last block we asked them for, try to find more pieces to request.
    -- If we can't find any, then send them uninteresting.
    peer.numWant = peer.numWant - 1
    if peer.numWant == 0 then
      if self:requestPieces(peer) == false then
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
          peer:on('handshake', function(id) self.peers[id] = peer end)
          peer:on('message', function(id, ...) messageHandler[id](self, peer, ...) end)
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
      pieces = self.pieceCount
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
        local req = Request:new(piece, block * 16384, 16384, peer)
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


-- Checks if the piece matches the hash specified in the metainfo file.
function Torrent:hashCheck(piece, content)
  local hashed = sha1.hash(content):gsub('(%w%w)', function(x)
    return string.char(tonumber(x, 16))
  end)
  
  return hashed == self.metainfo.info.pieces:sub((piece * 20) + 1, (piece * 20) + 20)
end


-- Writes out the data for the piece.
function Torrent:writePiece(piece, content)
  -- Write out piece data.
  -- Luvit doesn't have asynchronous write streams :[ TODO
  local offset = piece * self.metainfo.info['piece length']
  
  if self.metainfo.info.length then
    local stream = fs.createWriteStream(self.metainfo.info.name, {
      flags = 'r+'
    })
    stream.offset = offset
    stream:write(content)
    stream:close()
  else
    local bytes = #content
    for _, file in ipairs(self.metainfo.info.files) do
      if offset > file.length then
        offset = offset - file.length
      else
        local path = self.metainfo.info.name .. '/' .. table.concat(file.path, '/')
        local stream = fs.createWriteStream(path, {
          flags = 'r+'
        })
        stream.offset = offset
        
        if bytes < file.length then  
          stream:write(content)
          stream:close()
          break
        else
          local chunkSize = file.length - offset
          stream:write(content:sub(1, chunkSize))
          stream:close()
          bytes = bytes - chunkSize
          content = content:sub(chunkSize + 1)
        end
      end
    end
  end
end

return Torrent