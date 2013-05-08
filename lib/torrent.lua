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

require('./constants')

local Object = require('core').Object
local Tracker = require('./tracker')
local Request = require('./request')
local Pipeline = require('./pipeline')

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
  
  self.uploadQueue = {}
  self.downloadQueue = {}
  self.unchokeQueue = {}
  self.interestedQueue = {}
  
  self.remoteLeech = 0
  self.remotePending = 0
  self.remoteSeed = 0
  
  self.content = nil
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
    self.infoHash = sha1.hash(bencode.encode(self.metainfo.info)):gsub('(%w%w)', function(x)
      return string.char(tonumber(x, 16))
    end)
    local pieces = math.ceil(self.metainfo.info.length / self.metainfo.info['piece length'])
    local blocks = math.ceil(self.metainfo.info['piece length'] / 16384)
    local i
    for i = 1, pieces do
      self.missing[i] = {}
      local j
      for j = 1, blocks do
        table.insert(self.missing[i], j - 1)
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
    -- We don't put them back in peer.want because we're going to ask someone else for them
    -- instead.
    while #peer.pending > 0 do
      local req = peer.pending[1]
      table.remove(peer.pending, 1)
      table.insert(self.missing[req.piece], req.block)
    end
    
    self.remoteSeed = self.remoteSeed - 1
    
    -- Have to look in download queue as well.
  end,
  
  [1] = function(self, peer)
  
    -- After someone unchokes us, start pipelining block requests.
    if peer.interestedTimer then timer.clearTimer(peer.interestedTimer) end
    self.remotePending = self.remotePending - 1
    self.remoteSeed = self.remoteSeed + 1
    
    local i
    local flag = false
    for i = 1, #peer.pieces do
      if peer.pieces[i] == 1 and self.missing[i] and #self.missing[i] > 0 then
        local j
        for j = 1, #self.missing[i] do
          local block = self.missing[i][j]
          --[[table.insert(self.downloadQueue, Request:new({
            piece = i,
            block = block,
            length = 16384,
            peer = peer.id
          }))]]--
        end
      end
    end
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
    -- self.rarity[piece] = self.rarity[piece] + 1
    
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
        if peer.pieces[i] == 1 and self.missing[piece] and #self.missing[piece] > 0 then
          self.interestedQueue[#self.interestedQueue + 1] = peer
          peer.interesting = true
          self:pipeInterested()
          break
        end
      end
    end
  end,
  
  [6] = function(self, peer, piece, offset, length)
    local block = math.floor(offset / 16384)
    if not self.missing[piece] then
      table.insert(self.uploadQueue, Request:new({
        piece = piece,
        block = block,
        length = length,
        peer = peer
      }))
    end
  end,
  
  [7] = function(self, peer, piece, offset, body)
    -- TODO Write body to content cache.
    -- TODO Check if it completes a piece.  Do a bunch of work if it does.
    print('Got piece ' .. piece .. ':' .. offset .. '!')
    
    local block = math.floor(offset / 16384)
    
    local i
    for i = 1, #peer.pending do
      if peer.pending[i].piece == piece and peer.pending[i].block == block then break end
    end
    
    table.remove(peer.pending, i)
    
    -- Tell them they're uninteresting if we don't have anything left to ask of them.
    if #peer.pending == 0 then
      for i = 1, #self.downloadQueue do
        if self.downloadQueue[i].peer == peer.id then
          peer.interesting = false
          peer:send(3)
        end
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
            if id ~= 4 then print('Received ' .. id) end
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

    peer:send(2)
    self.remotePending = self.remotePending + 1
    peer.interestedTimer = timer.setTimeout(5000, function()
      table.insert(self.interestedQueue, peer)
      peer:send(3)
      self.remotePending = self.remotePending + 1
      self:pipeInterested()
    end)
  end
end

return Torrent