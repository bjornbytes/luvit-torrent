local string = require('string')
local table = require('table')

local bencode = require('./bencode')
local http = require('http')

local Object = require('core').Object
local Peer = require('./peer')

local Tracker = Object:extend()

function Tracker:initialize(url)
  self.url = url
end

function Tracker:announce(options, callback)
  if not options.infoHash or not options.peerId or not options.port
      or not options.uploaded or not options.downloaded or not options.left then
    return nil
  end
  
  local function urlEncode(str)
    return str:gsub('(.)', function(x)
      local b = x:byte(1)
      if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
          or b == 45 or b == 95 or b == 46 or b == 126 then
        return x
      else
        return string.format('%%%02x', b)
      end
    end)
  end
  
  local url = self.url
  url = url .. '?info_hash=' .. urlEncode(options.infoHash)
  url = url .. '&peer_id=' .. urlEncode(options.peerId)
  url = url .. '&port=' .. options.port
  url = url .. '&uploaded=' .. options.uploaded
  url = url .. '&downloaded=' .. options.downloaded
  url = url .. '&left=' .. options.left
  if options.event then
    url = url .. '&event=' .. options.event
  end
  url = url .. '&compact=1'
  
  http.get(url, function(res)
    local data = ''
    
    res:on('data', function(chunk) data = data .. chunk end)
    res:on('end', function()
      peers = {}
      
      local response = bencode.decode(data)
      local err = response['failure reason']
      if err then print('Tracker error:', err) return end
      self.interval = response['interval']
      self.minInterval = response['min interval']
      self.trackerId = response['tracker id']
      self.complete = response['complete']
      self.incomplete = response['incomplete']
      
      local rawPeers = response['peers']
      
      if type(rawPeers) == 'string' then
        while #rawPeers > 0 do
          local str = rawPeers:sub(1, 6)
          
          local ip = str:sub(1, 4):gsub('(.)', function(x)
            return x:byte(1) .. '.'
          end):sub(0, -2)
          
          local x, y = str:byte(5,6)
          local port = (x * 256) + y
          
          table.insert(peers, Peer:new(ip, port, options.pieces))
          
          rawPeers = rawPeers:sub(7)
        end
      else
        for k, v in ipairs(rawPeers) do
          --
        end
      end
      
      if callback then callback(peers) end
    end)
  end)
end

return Tracker