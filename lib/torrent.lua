local math = require('math')
local os = require('os')
local bencode = require('./bencode')
local listen = require('./listen')
local fs = require('fs')
local http = require('http')

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
  print(self.peerId)
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
  
  if self.location.sub(1,4) == 'http' then
    http.get(url, function(res)
      local data = ''

      res.setEncoding('utf8')
      res.on('data', function(chunk) data = data .. chunk end)
      res.on('end', function()
        self.metainfo = bencode.decode(data)
        if callback then callback() end
      end)
    end)
  else
    fs.readFile(self.location, function(err, data)
      self.metainfo = bencode.decode(data)
      if callback then callback() end
    end)
  end
end


-- Creates tracker objects for each url in the announce/announceList
-- portions of the metainfo dictionary.
function Torrent:initTrackers()
  if self.trackers then return nil end
  self.trackers = {}
end


-- Starts or resumes the torrent.
function Torrent:start()
  -- This will have to be restructured for asynchronousness.
  if not self.metainfo then self:readMetainfo() end
  if not self.trackers then self:initTrackers() end
  
  announceHandler = function(peers) print('found ' .. #peers .. ' peers') end
  
  for _, tracker in pairs(self.trackers) do
    self:announce(tracker, 'started', announceHandler)
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
  local options = {
    infoHash = self.metainfo.info,
    peerId = self.peerId,
    port = listen:getPortSync(),
    uploaded = 0,
    downloaded = 0,
    left = self.metainfo.info.length,
    event = event
  }
  
  tracker:announce(options, callback)
end


return Torrent