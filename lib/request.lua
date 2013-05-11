local Object = require('core').Object

local Request = Object:extend()

function Request:initialize(piece, block, length, peer)
  self.piece = piece
  self.block = block
  self.length = length
  self.peer = peer
end

return Request