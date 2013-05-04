local bencode = require('./bencode')
local listen = require('./listen')
local fs = require('fs')
local http = require('http')

local Object = require('core').Object
local Tracker = require('./tracker')

local Torrent = Object:extend()


-- Creates a new Torrent from the .torrent file located at location.
function Torrent:initialize(location)
  self.location = location
end


-- 
function Torrent:destroy()

end


-- 
function Torrent:readMetainfo(callback)
  if self.metainfo then return nil end
  
  if self.location.sub(1,4) == 'http' then
    http.get(url, function(res)

      local data = ''

      res.setEncoding('utf8')
      res.on('data', function(chunk)
        --
      end)
      
      res.on('end', function()
        --
        print(data)
      end)
    end)
  else
    fs.readFile(self.location, function(err, data)
      self.metainfo = bencode.decode(data)
      if callback then callback() end
    end)
  end
end


-- 
function Torrent:initTrackers()
  --if not self.metainfo then self:readMetainfo() end
  if self.trackers then return nil end
  self.trackers = {}
end


-- 
function Torrent:start()
  -- This will have to be restructured for asynchronousness.
  if not self.metainfo then self:readMetainfo() end
  if not self.trackers then self:initTrackers() end
  
  announceHandler = function() end
  
  for _, tracker in pairs(self.trackers) do
    self:announce(tracker, 'started', announceHandler)
  end
end


-- 
function Torrent:stop()

end


-- 
function Torrent:announce(tracker, event, callback)
  local options = {
    infoHash = self.metainfo.infoHash,
    peerId = self.peerId,
    port = listen:getPortSync(),
    uploaded = 0,
    downloaded = 0,
    left = 0,
    event = event
  }
  
  tracker:announce(options, callback)
end


return Torrent