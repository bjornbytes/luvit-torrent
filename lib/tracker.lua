local bencode = require('./bencode')

local Object = require('core').Object

local Tracker = Object:extend()

function Tracker:initialize()
  
end

function Tracker:announce(options, callback)
  if not options.infoHash or not options.peerId or not options.port
      or not options.uploaded or not options.downloaded or not options.left then
    return nil
  end
  
  -- Make a URL, send it, call callback.
end

return Tracker