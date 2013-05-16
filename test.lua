local Torrent = require('./torrent')

-- Place a torrent named sample.torrent in the same directory
-- as this file.
local t = Torrent:new('sample.torrent')
t:start()