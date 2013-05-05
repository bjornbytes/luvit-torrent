local bencode = require('./bencode')
local querystring = require('querystring')

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
  
  local url = self.url
  url = url .. '?info_hash=' .. querystring.urlencode(options.infoHash)
  url = url .. '&peer_id=' .. querystring.urlencode(options.peerId)
  url = url .. '&port=' .. options.port
  url = url .. '&uploaded=' .. options.uploaded
  url = url .. '&downloaded=' .. options.downloaded
  url = url .. '&left=' .. options.left
  if options.event then
    url = url .. '&event=' .. options.event
  end
  
  http.get(url, function(res)
    local data = ''
    
    res.setEncoding('utf8')
    res.on('data', function(chunk) data = data .. chunk end)
    res.on('end', function()
      peers = {}
      
      local response = bencode.decode(data)
      self.error = response['failure reason']
      self.interval = response['interval']
      self.minInterval = response['min interval']
      self.trackerId = response['tracker id']
      self.complete = response['complete']
      self.incomplete = response['incomplete']
      
      local rawPeers = response['peers']
      
      if type(rawPeers) == 'string' then
        while rawPeers do
          local str = rawPeers:sub(1, 6)
          
          local ip = str:sub(1, 4):gsub('(.)', function(x)
            return x:byte(1) .. '.'
          end):sub(0, -2)
          
          local x, y = str:byte(5,6)
          local port = (y * 256) + x
          
          table.insert(peers, Peer:new(ip, port))
          
          rawPeers = rawPeers:sub(7)
        end
      else
        for k, v in rawPeers do
          --
        end
      end
      
      if callback then callback(peers) end
    end)
  end)
end

return Tracker