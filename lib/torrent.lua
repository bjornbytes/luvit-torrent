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

local Object = require('core').Object
local Tracker = require('./tracker')
local Request = require('./request')

local Torrent = Object:extend()


-- Creates a new Torrent from the .torrent file located at location.
-- Most operations are lazy -- that is it won't attempt to read/download the file
-- until you call start.
function Torrent:initialize(location)
  math.randomseed(os.time())
  self.location = location
  self.peerId = '-Lv0010-' .. math.random(1e11, 9e11)
  self.peers = nil
  
  self.missing = nil
  self.rarity = nil
  
  self.uploadQueue = nil
  self.downloadQueue = nil
  self.unchokeQueue = nil
  self.interestedQueue = nil
  
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


-- High-level message.  Lower level logic is in peer.lua.
-- A poor man's switch statement.
local messageHandler = {
  [0] = function(peer)
  
    -- If they choke us and we've requested pieces, put these requests back in the pool.
    while #peer.pending do
      local req = peer.pending[1]
      table.remove(peer.pending, 1)
      table.insert(self.missing[req.piece], req.block)
    end
  end,
  
  [1] = function(peer)
  
    -- After someone unchokes us, start pipelining block requests.
    for i = 1, #self.interestedQueue[peer].pieces do
      local piece = self.interestedQueue[peer].piece[i]
      if self.missing[piece] and #self.missing[piece] then
        local j
        for j = 1, #self.missing[piece] do
          table.insert(self.downloadQueue, Request:new({
            piece = piece,
            block = self.missing[piece][j],
            length = 16384,
            peer = peer.id,
          }))
        end
      end
    end
  end,
  
  [2] = function(peer)
    local i
    for i = 1, #self.unchokeQueue do
      if self.unchokeQueue[i].peerId == peer.id then return end
    end
    
    table.insert(self.unchokeQueue[i], peer.id)
  end,
  
  [3] = function(peer)
    local i
    for i = 1, #self.uploadQueue do
      local req = self.uploadQueue[i]
      if req.peer == peer.id then
        table.remove(self.uploadQueue, i)
        i = i - 1
      end
    end
  end,
  
  [4] = function(peer, piece)
    self.rarity[piece] = self.rarity[piece] + 1
    
    if (not peer.interesting) and self.missing[piece] and #self.missing[piece] > 0 then
      peer.interesting = true
      peer:send(2)
    end
  end,
  
  [5] = function(peer, bitfield)
    -- Update rarity.
  end,
  
  [6] = function(peer, piece, offset, length)
    local block = math.floor(offset / 16384)
    if not self.missing[piece] then
      table.insert(self.uploadQueue, Request:new({
        piece = piece,
        block = block,
        length = length,
        peer = peer,
        time = os.time()
      }))
    end
  end,
  
  [7] = function(peer, piece, offset, body)
    -- TODO Write body to content cache.
    -- TODO Check if it completes a piece.  Do a bunch of work if it does.
    
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
        for _, peer in ipairs(peers) do
          table.insert(self.peers, peer)
          
          peer:connect('BitTorrent protocol', self.infoHash, self.peerId)
          
          peer:on('message', function(id, ...)
            messageHandler[id](peer, ...)
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


return Torrent