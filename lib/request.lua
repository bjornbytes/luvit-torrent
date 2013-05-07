local Object = require('core').Object

local Request = Object:extend()

function Request:new(options)
  self.piece = options.piece
  self.block = options.block
  self.length = options.length
  self.peer = options.peer
end

return Request