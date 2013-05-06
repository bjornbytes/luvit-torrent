local math = require('math')
local os = require('os')
local table = require('table')
local string = require('string')

local bencode = require('./bencode')
local listen = require('./listen')
local fs = require('fs')
local http = require('http')
local sha1 = require('./sha1')

local Object = require('core').Object
local Tracker = require('./tracker')

local Torrent = Object:extend()


-- Creates a new Torrent from the .torrent file located at location.
-- Most operations are lazy -- that is it won't attempt to read/download the file
-- until you call start.
function Torrent:initialize(location)
  math.randomseed(os.time())
  self.location = location
  self.peerId = '-Lv0010-' .. math.random(1e11, 9e11)
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


-- Starts or resumes the torrent.
function Torrent:start()
  -- This will have to be restructured for asynchronousness.
  if not self.metainfo then
    self:readMetainfo(function()
      if not self.trackers then self:initTrackers() end
      
      announceHandler = function(peers)
        print('found ' .. #peers .. ' peers')
        for _, peer in ipairs(peers) do
          peer:connect('BitTorrent protocol', self.infoHash, self.peerId)
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
      event = event
    }
    
    tracker:announce(options, callback)
  end)
end


return Torrent