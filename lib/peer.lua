local Object = require('core').Object

local Peer = Object:extend()

function Peer:initialize(ip, port)
  self.ip = ip
  self.port = port
end

return Peer